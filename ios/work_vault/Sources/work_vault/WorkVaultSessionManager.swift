import BackgroundTasks
import Foundation
import os
import UIKit
import UserNotifications

/// Background download engine.
///
/// One `URLSessionConfiguration.background` session exists per network
/// constraint. Resume tokens are files next to the task store. Flutter is
/// notified only after `initialize()` completes; work continues without it.
final class WorkVaultSessionManager: NSObject {
  static let shared = WorkVaultSessionManager(
    directory: WorkVaultSessionManager.defaultDirectory(),
    createsBackgroundSessions: true
  )

  private let log = Logger(subsystem: "com.workvault.work_vault", category: "session")
  private let directory: URL
  private let createsBackgroundSessions: Bool
  private let lock = NSLock()
  private let delegateQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.workvault.work_vault.session"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private let timers = DispatchQueue(label: "com.workvault.work_vault.timers")

  private var records: [String: StoredTask] = [:]
  private var sessions: [String: URLSession] = [:]
  private var systemTasks: [String: URLSessionTask] = [:]
  private var pauseRequests: Set<String> = []
  private var retryItems: [String: DispatchWorkItem] = [:]
  private var lastProgressEmit: [String: TimeInterval] = [:]
  private var speedSamples: [String: SpeedSample] = [:]
  private var backgroundCompletions: [String: () -> Void] = [:]
  private var flutterApi: WorkVaultFlutterApi?
  private var eventsEnabled = false

  init(directory: URL, createsBackgroundSessions: Bool) {
    self.directory = directory
    self.createsBackgroundSessions = createsBackgroundSessions
    super.init()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    load()
  }

  func attach(flutterApi: WorkVaultFlutterApi?) {
    mutate {
      self.flutterApi = flutterApi
      if flutterApi == nil {
        self.eventsEnabled = false
      }
    }
  }

  func initialize() async throws {
    mutate {
      self.eventsEnabled = false
      self.load()
    }
    let power = await WorkVaultPower.current()
    if createsBackgroundSessions {
      for identifier in WorkVaultBackgroundEvents.sessionIdentifiers {
        await reconnect(identifier)
      }
    }
    mutate {
      self.sweepFilesLocked()
      self.eventsEnabled = true
      self.scheduleDueRetriesLocked(power: power)
    }
    scheduleMaintenance()
  }

  func enqueue(_ config: WorkTaskConfig) async throws -> TaskSnapshot {
    try WorkVaultRules.validate(config)
    let power = await WorkVaultPower.current()
    let taskId = config.taskId
    let action: StartAction? = try mutate {
      if self.records[taskId] != nil {
        throw WorkVaultErrors.duplicate(taskId)
      }
      var record = StoredTask(config: config)
      record.status = TaskStatus.enqueued.wire
      self.records[taskId] = record
      guard WorkVaultRules.allowsStart(record, power: power) else {
        self.saveLocked()
        return nil
      }
      let action = self.prepareStartLocked(&record)
      self.records[taskId] = record
      self.saveLocked()
      return action
    }
    if let action {
      try perform(action)
    }
    scheduleMaintenance()
    let snapshot = try snapshotRequired(taskId)
    publish(snapshot)
    return snapshot
  }

  func pause(taskId: String) async throws {
    let task: URLSessionDownloadTask? = try mutate {
      let record = try self.requireLocked(taskId)
      guard record.status == TaskStatus.running.wire else {
        throw WorkVaultErrors.illegal(taskId: taskId, from: record.status, action: "pause")
      }
      self.pauseRequests.insert(taskId)
      self.retryItems[taskId]?.cancel()
      self.retryItems[taskId] = nil
      return self.systemTasks[taskId] as? URLSessionDownloadTask
    }
    if let task {
      let resumeData: Data? = await withCheckedContinuation { continuation in
        task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
      }
      if let resumeData {
        try? resumeData.write(to: resumeURL(taskId), options: .atomic)
      }
    } else {
      mutate { self.pauseRequests.remove(taskId) }
    }
    let snapshot = mutate { () -> TaskSnapshot? in
      self.markPausedLocked(taskId)
      return self.records[taskId].map(self.snapshot(from:))
    }
    if let snapshot {
      publish(snapshot)
    }
  }

  func resume(taskId: String) async throws {
    let power = await WorkVaultPower.current()
    let action: StartAction? = try mutate {
      var record = try self.requireLocked(taskId)
      guard record.status == TaskStatus.paused.wire else {
        throw WorkVaultErrors.illegal(taskId: taskId, from: record.status, action: "resume")
      }
      guard WorkVaultRules.allowsStart(record, power: power) else {
        record.status = TaskStatus.enqueued.wire
        self.records[taskId] = record
        self.saveLocked()
        return nil
      }
      let action = self.prepareStartLocked(&record)
      self.records[taskId] = record
      self.saveLocked()
      return action
    }
    if let action {
      try perform(action)
    }
    publish(try snapshotRequired(taskId))
  }

  func cancel(taskId: String) async throws {
    let task: URLSessionTask? = try mutate {
      let record = try self.requireLocked(taskId)
      guard WorkVaultRules.canCancel(from: record.status) else {
        throw WorkVaultErrors.illegal(taskId: taskId, from: record.status, action: "cancel")
      }
      self.retryItems[taskId]?.cancel()
      self.retryItems[taskId] = nil
      self.pauseRequests.remove(taskId)
      var updated = record
      updated.status = TaskStatus.cancelled.wire
      updated.failureCode = nil
      updated.failureMessage = nil
      updated.failureRetryable = false
      updated.httpStatus = nil
      updated.nextAttemptAtMs = nil
      self.records[taskId] = updated
      let task = self.systemTasks.removeValue(forKey: taskId)
      self.saveLocked()
      return task
    }
    task?.cancel()
    try? FileManager.default.removeItem(at: resumeURL(taskId))
    try? FileManager.default.removeItem(at: stagingURL(taskId))
    publish(try snapshotRequired(taskId))
  }

  func task(taskId: String) -> TaskSnapshot? {
    read { records[taskId].map(snapshot(from:)) }
  }

  func tasks() -> [TaskSnapshot] {
    read { records.values.map(snapshot(from:)).sorted { $0.taskId < $1.taskId } }
  }

  func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
    mutate {
      self.backgroundCompletions[identifier] = completionHandler
    }
    guard createsBackgroundSessions else {
      return
    }
    _ = session(for: identifier)
  }

  func performMaintenance(_ task: BGProcessingTask) {
    let gate = CompletionGate()
    task.expirationHandler = { gate.expire() }
    Task {
      let power = await WorkVaultPower.current()
      if !gate.isExpired {
        await self.runMaintenance(power: power)
      }
      self.scheduleMaintenance()
      gate.complete(task)
    }
  }

  // MARK: - Test hooks

  func testing_markCompleted(taskId: String, bytes: Int64) {
    mutate {
      guard var record = self.records[taskId] else { return }
      record.status = TaskStatus.completed.wire
      record.bytesDownloaded = bytes
      record.totalBytes = bytes
      self.records[taskId] = record
      self.saveLocked()
    }
  }

  func testing_finishBackgroundEvents(identifier: String) {
    finishBackgroundEvents(identifier: identifier)
  }

  func testing_seed(_ record: StoredTask) {
    mutate {
      self.records[record.taskId] = record
      self.saveLocked()
    }
  }

  func testing_sweep() {
    mutate { self.sweepFilesLocked() }
  }

  func testing_recordFailure(taskId: String, retryable: Bool) {
    let snapshot = mutate { () -> TaskSnapshot? in
      self.failLocked(
        taskId: taskId,
        code: "network",
        message: "The connection dropped.",
        httpStatus: nil,
        retryable: retryable
      )
    }
    if let snapshot {
      publish(snapshot)
    }
  }
}

extension WorkVaultSessionManager: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let taskId = downloadTask.taskDescription else {
      return
    }
    let progress = mutate { () -> TaskProgress? in
      let etag = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
      return self.progressLocked(
        taskId: taskId,
        bytesWritten: totalBytesWritten,
        expected: totalBytesExpectedToWrite,
        etag: etag
      )
    }
    if let progress {
      publish(progress)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let taskId = downloadTask.taskDescription else {
      return
    }
    let staging = stagingURL(taskId)
    do {
      if FileManager.default.fileExists(atPath: staging.path) {
        try FileManager.default.removeItem(at: staging)
      }
      try FileManager.default.copyItem(at: location, to: staging)
    } catch {
      log.error("Unable to preserve download for \(taskId, privacy: .public)")
      let snapshot = mutate {
        self.failLocked(
          taskId: taskId,
          code: "io",
          message: "The download could not be saved.",
          httpStatus: nil,
          retryable: true
        )
      }
      if let snapshot { publish(snapshot) }
      return
    }

    let http = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
    if http >= 400 {
      try? FileManager.default.removeItem(at: staging)
      let retryable = WorkVaultRules.isRetryableHTTPStatus(http)
      let snapshot = mutate {
        self.failLocked(
          taskId: taskId,
          code: "http",
          message: "The server returned HTTP \(http).",
          httpStatus: http,
          retryable: retryable
        )
      }
      if let snapshot { publish(snapshot) }
      return
    }

    let destination = read { records[taskId]?.destinationPath }
    guard let destination else {
      try? FileManager.default.removeItem(at: staging)
      return
    }
    do {
      try replaceFile(at: staging, withDestination: destination)
    } catch {
      let snapshot = mutate {
        self.failLocked(
          taskId: taskId,
          code: "io",
          message: "The download could not be moved into place.",
          httpStatus: nil,
          retryable: true
        )
      }
      if let snapshot { publish(snapshot) }
      return
    }

    let size = fileSize(atPath: destination) ?? 0
    let snapshot = mutate { () -> TaskSnapshot? in
      guard var record = self.records[taskId] else { return nil }
      record.status = TaskStatus.completed.wire
      record.bytesDownloaded = size
      record.totalBytes = size
      record.bytesPerSecond = 0
      record.failureCode = nil
      record.failureMessage = nil
      record.failureRetryable = false
      record.httpStatus = nil
      record.nextAttemptAtMs = nil
      if let header = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
        !header.isEmpty
      {
        record.etag = header
      }
      if let started = record.startedAtMs {
        record.elapsedMs = max(record.elapsedMs, WorkVaultRules.nowMs() - started)
      }
      self.records[taskId] = record
      self.systemTasks[taskId] = nil
      self.retryItems[taskId]?.cancel()
      self.retryItems[taskId] = nil
      self.saveLocked()
      try? FileManager.default.removeItem(at: self.resumeURL(taskId))
      return self.snapshot(from: record)
    }
    if let snapshot {
      publish(snapshot)
      postCompletionNotification(taskId: taskId)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let taskId = task.taskDescription else {
      return
    }
    if let error {
      let nsError = error as NSError
      let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
      if let resumeData {
        try? resumeData.write(to: resumeURL(taskId), options: .atomic)
      }
      let pausing = read { pauseRequests.contains(taskId) || records[taskId]?.status == TaskStatus.paused.wire }
      if nsError.code == NSURLErrorCancelled && pausing {
        let snapshot = mutate { () -> TaskSnapshot? in
          self.pauseRequests.remove(taskId)
          self.markPausedLocked(taskId)
          return self.records[taskId].map(self.snapshot(from:))
        }
        if let snapshot { publish(snapshot) }
        return
      }
      if nsError.code == NSURLErrorCancelled {
        return
      }
      let snapshot = mutate {
        self.failLocked(
          taskId: taskId,
          code: "network",
          message: nsError.localizedDescription,
          httpStatus: nil,
          retryable: WorkVaultRules.isRetryableURLError(nsError.code)
        )
      }
      if let snapshot { publish(snapshot) }
      return
    }
    mutate { self.systemTasks[taskId] = nil }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else {
      return
    }
    finishBackgroundEvents(identifier: identifier)
  }
}

extension WorkVaultSessionManager {
  fileprivate func runMaintenance(power: WorkVaultPower.State) async {
    let ids = mutate { () -> [String] in
      self.sweepFilesLocked()
      return self.records.values
        .filter { $0.status == TaskStatus.enqueued.wire }
        .map(\.taskId)
    }
    for taskId in ids {
      await startIfAllowed(taskId: taskId, power: power)
    }
  }

  fileprivate func reconnect(_ identifier: String) async {
    let session = session(for: identifier)
    let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
    mutate {
      for task in tasks {
        guard let taskId = task.taskDescription, self.records[taskId] != nil else {
          continue
        }
        self.systemTasks[taskId] = task
        if self.records[taskId]?.status == TaskStatus.enqueued.wire
          || self.records[taskId]?.status == TaskStatus.running.wire
        {
          self.records[taskId]?.status = TaskStatus.running.wire
        }
      }
      self.saveLocked()
    }
  }

  fileprivate func startIfAllowed(taskId: String, power: WorkVaultPower.State) async {
    let action: StartAction? = mutate {
      guard var record = self.records[taskId] else { return nil }
      guard record.status == TaskStatus.enqueued.wire else { return nil }
      if let due = record.nextAttemptAtMs, due > WorkVaultRules.nowMs() {
        return nil
      }
      guard WorkVaultRules.allowsStart(record, power: power) else { return nil }
      let action = self.prepareStartLocked(&record)
      self.records[taskId] = record
      self.saveLocked()
      return action
    }
    guard let action else {
      return
    }
    do {
      try perform(action)
      publish(try snapshotRequired(taskId))
    } catch {
      let snapshot = mutate {
        self.failLocked(
          taskId: taskId,
          code: "io",
          message: "The download could not be started.",
          httpStatus: nil,
          retryable: true
        )
      }
      if let snapshot { publish(snapshot) }
    }
  }

  fileprivate func perform(_ action: StartAction) throws {
    switch action {
    case .deferred:
      return
    case let .fresh(request, sessionIdentifier, taskId):
      guard createsBackgroundSessions else { return }
      let task = session(for: sessionIdentifier).downloadTask(with: request)
      task.taskDescription = taskId
      mutate { self.systemTasks[taskId] = task }
      task.resume()
    case let .resume(data, sessionIdentifier, taskId):
      guard createsBackgroundSessions else { return }
      let task = session(for: sessionIdentifier).downloadTask(withResumeData: data)
      task.taskDescription = taskId
      mutate { self.systemTasks[taskId] = task }
      task.resume()
      try? FileManager.default.removeItem(at: resumeURL(taskId))
    }
  }

  fileprivate func prepareStartLocked(_ record: inout StoredTask) -> StartAction {
    record.attempt += 1
    record.status = TaskStatus.running.wire
    record.startedAtMs = WorkVaultRules.nowMs()
    record.nextAttemptAtMs = nil
    record.failureCode = nil
    record.failureMessage = nil
    record.failureRetryable = false
    record.httpStatus = nil
    let sessionIdentifier = WorkVaultRules.sessionIdentifier(forWireName: record.network)
    if let data = try? Data(contentsOf: resumeURL(record.taskId)), !data.isEmpty {
      return .resume(data, sessionIdentifier, record.taskId)
    }
    guard let url = URL(string: record.url) else {
      return .deferred
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.allHTTPHeaderFields = record.headers
    return .fresh(request, sessionIdentifier, record.taskId)
  }

  fileprivate func session(for identifier: String) -> URLSession {
    if let existing = read({ sessions[identifier] }) {
      return existing
    }
    let created = makeSession(identifier)
    let stored = mutate { () -> URLSession in
      if let existing = self.sessions[identifier] {
        return existing
      }
      self.sessions[identifier] = created
      return created
    }
    if stored !== created {
      created.finishTasksAndInvalidate()
    }
    return stored
  }

  fileprivate func makeSession(_ identifier: String) -> URLSession {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.shouldUseExtendedBackgroundIdleMode = true
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 60 * 60 * 24
    let constraint: NetworkConstraint
    switch identifier {
    case WorkVaultRules.sessionIdentifier(for: .unmetered):
      constraint = .unmetered
    case WorkVaultRules.sessionIdentifier(for: .notRoaming):
      constraint = .notRoaming
    default:
      constraint = .any
    }
    let access = WorkVaultRules.networkAccess(for: constraint)
    configuration.allowsCellularAccess = access.allowsCellular
    configuration.allowsExpensiveNetworkAccess = access.allowsExpensive
    configuration.allowsConstrainedNetworkAccess = true
    return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }

  fileprivate func progressLocked(
    taskId: String,
    bytesWritten: Int64,
    expected: Int64,
    etag: String? = nil
  ) -> TaskProgress? {
    guard var record = records[taskId] else { return nil }
    guard record.status == TaskStatus.running.wire else { return nil }
    let now = Date().timeIntervalSince1970
    let sample = speedSamples[taskId] ?? SpeedSample(bytes: bytesWritten, time: now, speed: 0)
    let deltaTime = now - sample.time
    if deltaTime > 0 {
      let instant = Double(max(0, bytesWritten - sample.bytes)) / deltaTime
      sample.speed = sample.speed == 0 ? instant : (0.3 * instant + 0.7 * sample.speed)
      sample.bytes = bytesWritten
      sample.time = now
    }
    speedSamples[taskId] = sample
    record.bytesDownloaded = max(0, bytesWritten)
    if expected > 0 {
      record.totalBytes = expected
    }
    record.bytesPerSecond = sample.speed
    if let started = record.startedAtMs {
      record.elapsedMs = max(record.elapsedMs, WorkVaultRules.nowMs() - started)
    }
    if let etag, !etag.isEmpty {
      record.etag = etag
    }
    records[taskId] = record

    let last = lastProgressEmit[taskId] ?? 0
    let finished = expected > 0 && bytesWritten >= expected
    guard finished || now - last >= 0.2 else {
      return nil
    }
    lastProgressEmit[taskId] = now
    saveLocked()
    return snapshot(from: record).progress
  }

  fileprivate func failLocked(
    taskId: String,
    code: String,
    message: String,
    httpStatus: Int?,
    retryable: Bool,
    force: Bool = false
  ) -> TaskSnapshot? {
    guard var record = records[taskId] else { return nil }
    if record.status == TaskStatus.cancelled.wire {
      return snapshot(from: record)
    }
    if !force && record.status == TaskStatus.completed.wire {
      return snapshot(from: record)
    }
    if !force && record.status == TaskStatus.paused.wire {
      return snapshot(from: record)
    }
    systemTasks[taskId] = nil
    record.failureCode = code
    record.failureMessage = message
    record.httpStatus = httpStatus
    let canRetry = retryable && record.attempt < record.maxAttempts
    record.failureRetryable = canRetry
    if canRetry {
      record.status = TaskStatus.enqueued.wire
      let delay = WorkVaultRules.backoffMs(
        attempt: record.attempt,
        initial: record.initialBackoffMs,
        maxBackoff: record.maxBackoffMs,
        multiplier: record.multiplier
      )
      record.nextAttemptAtMs = WorkVaultRules.nowMs() + Int64(delay)
      records[taskId] = record
      saveLocked()
      scheduleRetryLocked(taskId: taskId, afterMs: delay)
    } else {
      record.status = TaskStatus.failed.wire
      record.nextAttemptAtMs = nil
      records[taskId] = record
      saveLocked()
    }
    return snapshot(from: record)
  }

  fileprivate func markPausedLocked(_ taskId: String) {
    guard var record = records[taskId] else { return }
    guard record.status == TaskStatus.running.wire else { return }
    record.status = TaskStatus.paused.wire
    record.nextAttemptAtMs = nil
    records[taskId] = record
    systemTasks[taskId] = nil
    saveLocked()
  }

  fileprivate func scheduleRetryLocked(taskId: String, afterMs: Int) {
    retryItems[taskId]?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      Task {
        let power = await WorkVaultPower.current()
        await self.startIfAllowed(taskId: taskId, power: power)
      }
    }
    retryItems[taskId] = item
    timers.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: item)
  }

  fileprivate func scheduleDueRetriesLocked(power: WorkVaultPower.State) {
    let now = WorkVaultRules.nowMs()
    for record in records.values where record.status == TaskStatus.enqueued.wire {
      let delay = max(0, (record.nextAttemptAtMs ?? now) - now)
      if WorkVaultRules.allowsStart(record, power: power) {
        scheduleRetryLocked(taskId: record.taskId, afterMs: Int(delay))
      }
    }
  }

  fileprivate func sweepFilesLocked() {
    let completed = records.values.filter { $0.status == TaskStatus.completed.wire }
    for record in completed {
      let size = fileSize(atPath: record.destinationPath)
      if WorkVaultRules.isIntegrityMismatch(expectedBytes: record.bytesDownloaded, actualBytes: size) {
        _ = failLocked(
          taskId: record.taskId,
          code: "integrity",
          message: "The saved file failed validation.",
          httpStatus: nil,
          retryable: false,
          force: true
        )
      }
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: resumeDirectory.path) {
      let keep = Set(
        records.values
          .filter {
            $0.status == TaskStatus.paused.wire
              || $0.status == TaskStatus.running.wire
              || $0.status == TaskStatus.enqueued.wire
          }
          .map { WorkVaultRules.safeFileName($0.taskId) }
      )
      for name in names {
        let stem = (name as NSString).deletingPathExtension
        if !keep.contains(stem) {
          try? FileManager.default.removeItem(at: resumeDirectory.appendingPathComponent(name))
        }
      }
    }
  }

  fileprivate func scheduleMaintenance() {
    guard createsBackgroundSessions else { return }
    let request = BGProcessingTaskRequest(
      identifier: WorkVaultBackgroundEvents.maintenanceTaskIdentifier
    )
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    let nextDue = read {
      records.values.compactMap(\.nextAttemptAtMs).min()
    }
    if let nextDue {
      request.earliestBeginDate = Date(timeIntervalSince1970: Double(nextDue) / 1000)
    } else {
      request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    }
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      log.error("Unable to submit maintenance task")
    }
  }

  fileprivate func finishBackgroundEvents(identifier: String) {
    let handler = mutate { () -> (() -> Void)? in
      let handler = self.backgroundCompletions.removeValue(forKey: identifier)
      return handler
    }
    guard let handler else { return }
    DispatchQueue.main.async(execute: handler)
  }

  fileprivate func postCompletionNotification(taskId: String) {
    let copy = read { () -> (String, String)? in
      guard let record = records[taskId] else { return nil }
      return (record.notificationTitle, record.notificationBody)
    }
    guard let copy else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        break
      default:
        return
      }
      let content = UNMutableNotificationContent()
      content.title = copy.0
      content.body = copy.1
      let request = UNNotificationRequest(
        identifier: "work_vault.\(taskId)",
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
  }

  fileprivate func snapshotRequired(_ taskId: String) throws -> TaskSnapshot {
    try read {
      guard let record = records[taskId] else {
        throw WorkVaultErrors.missing(taskId)
      }
      return snapshot(from: record)
    }
  }

  fileprivate func requireLocked(_ taskId: String) throws -> StoredTask {
    guard let record = records[taskId] else {
      throw WorkVaultErrors.missing(taskId)
    }
    return record
  }

  fileprivate func snapshot(from record: StoredTask) -> TaskSnapshot {
    let includeProgress = record.status != TaskStatus.enqueued.wire || record.bytesDownloaded > 0
    let progress = includeProgress
      ? TaskProgress(
        taskId: record.taskId,
        bytesDownloaded: record.bytesDownloaded,
        totalBytes: record.totalBytes,
        bytesPerSecond: record.bytesPerSecond,
        elapsedMs: record.elapsedMs,
        percentage: WorkVaultRules.percentage(bytes: record.bytesDownloaded, total: record.totalBytes)
      )
      : nil
    let failure = record.failureCode.map { code in
      TaskFailure(
        taskId: record.taskId,
        code: code,
        message: record.failureMessage ?? "",
        httpStatus: record.httpStatus.map(Int64.init),
        retryable: record.failureRetryable
      )
    }
    return TaskSnapshot(
      taskId: record.taskId,
      status: TaskStatus.fromWire(record.status),
      progress: progress,
      failure: failure
    )
  }

  fileprivate func publish(_ snapshot: TaskSnapshot) {
    switch delivery(for: snapshot.taskId) {
    case let .flutter(api):
      Task { @MainActor in
        try? await api.onStatusChanged(snapshot: snapshot)
      }
    case let .headless(record):
      let resume = record.status == TaskStatus.paused.wire ? cappedResumeData(record.taskId) : nil
      WorkVaultEngineDispatcher.shared.enqueue(
        WorkVaultEngineDispatcher.payload(
          taskId: record.taskId,
          status: record.status,
          filePath: record.destinationPath,
          downloadedBytes: record.bytesDownloaded,
          totalBytes: record.totalBytes,
          eTag: record.etag,
          resumptionData: resume,
          kind: "status"
        )
      )
    case nil:
      break
    }
  }

  fileprivate func publish(_ progress: TaskProgress) {
    switch delivery(for: progress.taskId) {
    case let .flutter(api):
      Task { @MainActor in
        try? await api.onProgress(progress: progress)
      }
    case let .headless(record):
      WorkVaultEngineDispatcher.shared.enqueue(
        WorkVaultEngineDispatcher.payload(
          taskId: record.taskId,
          status: record.status,
          filePath: record.destinationPath,
          downloadedBytes: record.bytesDownloaded,
          totalBytes: record.totalBytes,
          eTag: record.etag,
          resumptionData: nil,
          kind: "progress"
        )
      )
    case nil:
      break
    }
  }

  private enum Delivery {
    case flutter(WorkVaultFlutterApi)
    case headless(StoredTask)
  }

  private func delivery(for taskId: String) -> Delivery? {
    read {
      if self.eventsEnabled, let api = self.flutterApi {
        return .flutter(api)
      }
      guard self.flutterApi == nil, self.createsBackgroundSessions, let record = self.records[taskId] else {
        return nil
      }
      return .headless(record)
    }
  }

  private func cappedResumeData(_ taskId: String) -> Data? {
    let url = resumeURL(taskId)
    guard
      let data = try? Data(contentsOf: url),
      !data.isEmpty,
      data.count <= 8 * 1024 * 1024
    else {
      return nil
    }
    return data
  }

  fileprivate func load() {
    guard let data = try? Data(contentsOf: storeURL) else { return }
    guard let decoded = try? JSONDecoder().decode([StoredTask].self, from: data) else {
      log.error("Task store could not be read")
      return
    }
    records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.taskId, $0) })
  }

  fileprivate func saveLocked() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(Array(records.values)) else { return }
    try? data.write(to: storeURL, options: .atomic)
  }

  fileprivate func read<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  fileprivate func mutate<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  fileprivate var storeURL: URL {
    directory.appendingPathComponent("tasks.json")
  }

  fileprivate var resumeDirectory: URL {
    directory.appendingPathComponent("resume", isDirectory: true)
  }

  fileprivate var stagingDirectory: URL {
    directory.appendingPathComponent("staging", isDirectory: true)
  }

  fileprivate func resumeURL(_ taskId: String) -> URL {
    resumeDirectory.appendingPathComponent(WorkVaultRules.safeFileName(taskId) + ".resume")
  }

  fileprivate func stagingURL(_ taskId: String) -> URL {
    stagingDirectory.appendingPathComponent(WorkVaultRules.safeFileName(taskId) + ".partial")
  }

  fileprivate static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("work_vault", isDirectory: true)
  }
}

private enum StartAction {
  case deferred
  case fresh(URLRequest, String, String)
  case resume(Data, String, String)
}

private final class SpeedSample {
  var bytes: Int64
  var time: TimeInterval
  var speed: Double

  init(bytes: Int64, time: TimeInterval, speed: Double) {
    self.bytes = bytes
    self.time = time
    self.speed = speed
  }
}

private final class CompletionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var expired = false
  private var completed = false

  var isExpired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return expired
  }

  func expire() {
    lock.lock()
    expired = true
    lock.unlock()
  }

  func complete(_ task: BGProcessingTask) {
    lock.lock()
    let shouldComplete = !completed
    completed = true
    let expired = self.expired
    lock.unlock()
    if shouldComplete {
      task.setTaskCompleted(success: !expired)
    }
  }
}

enum WorkVaultPower {
  struct State {
    var isCharging: Bool
    var isLowPower: Bool
  }

  static func current() async -> State {
    let charging = await MainActor.run { isDeviceCharging }
    return State(isCharging: charging, isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
  }

  @MainActor static var isDeviceCharging: Bool {
    UIDevice.current.isBatteryMonitoringEnabled = true
    switch UIDevice.current.batteryState {
    case .charging, .full:
      return true
    case .unplugged, .unknown:
      return false
    @unknown default:
      return false
    }
  }
}

enum WorkVaultRules {
  static func validate(_ config: WorkTaskConfig) throws {
    if config.taskId.isEmpty || config.taskId.contains("/") || config.taskId.contains("\0") {
      throw WorkVaultErrors.invalid("taskId must be a non-empty file-safe token.")
    }
    guard let url = URL(string: config.url), url.scheme == "https", !(url.host?.isEmpty ?? true) else {
      throw WorkVaultErrors.invalid("url must be an absolute https URL.")
    }
    if !config.destinationPath.hasPrefix("/") {
      throw WorkVaultErrors.invalid("destinationPath must be an absolute file path.")
    }
    if config.method != .get {
      throw WorkVaultErrors.invalid("Only GET downloads are supported in this version.")
    }
  }

  static func allowsStart(_ record: StoredTask, power: WorkVaultPower.State) -> Bool {
    if record.requiresCharging && !power.isCharging {
      return false
    }
    if record.requiresBatteryNotLow && power.isLowPower {
      return false
    }
    return true
  }

  static func canCancel(from status: String) -> Bool {
    status == TaskStatus.enqueued.wire
      || status == TaskStatus.running.wire
      || status == TaskStatus.paused.wire
  }

  /// Which paths a session for [network] may use.
  ///
  /// iOS has no roaming signal. `notRoaming` allows cellular and refuses expensive paths,
  /// which is how the system represents roaming and tethering.
  static func networkAccess(
    for network: NetworkConstraint
  ) -> (allowsCellular: Bool, allowsExpensive: Bool) {
    switch network {
    case .any:
      return (true, true)
    case .unmetered:
      return (false, false)
    case .notRoaming:
      return (true, false)
    }
  }

  static func sessionIdentifier(for network: NetworkConstraint) -> String {
    switch network {
    case .any:
      return "com.workvault.work_vault.downloads.any"
    case .unmetered:
      return "com.workvault.work_vault.downloads.unmetered"
    case .notRoaming:
      return "com.workvault.work_vault.downloads.not-roaming"
    }
  }

  static func sessionIdentifier(forWireName name: String) -> String {
    switch name {
    case "unmetered":
      return sessionIdentifier(for: .unmetered)
    case "notRoaming":
      return sessionIdentifier(for: .notRoaming)
    default:
      return sessionIdentifier(for: .any)
    }
  }

  static func isRetryableHTTPStatus(_ code: Int) -> Bool {
    code == 408 || code == 429 || (500...599).contains(code)
  }

  static func isRetryableURLError(_ code: Int) -> Bool {
    switch code {
    case NSURLErrorTimedOut,
      NSURLErrorCannotConnectToHost,
      NSURLErrorNetworkConnectionLost,
      NSURLErrorNotConnectedToInternet,
      NSURLErrorDNSLookupFailed,
      NSURLErrorCannotFindHost,
      NSURLErrorInternationalRoamingOff,
      NSURLErrorCallIsActive,
      NSURLErrorDataNotAllowed:
      return true
    default:
      return false
    }
  }

  static func backoffMs(attempt: Int, initial: Int, maxBackoff: Int, multiplier: Double) -> Int {
    guard initial > 0, maxBackoff > 0 else { return 0 }
    var delay = initial
    if attempt > 1 {
      for _ in 1..<attempt {
        let next = Double(delay) * max(1, multiplier)
        if next >= Double(maxBackoff) {
          return maxBackoff
        }
        delay = Int(next)
      }
    }
    return min(delay, maxBackoff)
  }

  static func percentage(bytes: Int64, total: Int64?) -> Double? {
    guard let total, total > 0 else { return nil }
    return min(100, Double(bytes) / Double(total) * 100)
  }

  static func isIntegrityMismatch(expectedBytes: Int64, actualBytes: Int64?) -> Bool {
    guard expectedBytes > 0 else { return actualBytes == nil }
    return actualBytes != expectedBytes
  }

  static func safeFileName(_ taskId: String) -> String {
    taskId.replacingOccurrences(of: ":", with: "_")
  }

  static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }
}

enum WorkVaultErrors {
  static func invalid(_ message: String) -> WorkVaultError {
    WorkVaultError(code: workVaultInvalidConfig, message: message, details: nil)
  }

  static func duplicate(_ taskId: String) -> WorkVaultError {
    WorkVaultError(
      code: workVaultDuplicateTask,
      message: "Task \"\(taskId)\" is already enqueued.",
      details: ["taskId": taskId]
    )
  }

  static func missing(_ taskId: String) -> WorkVaultError {
    WorkVaultError(
      code: workVaultTaskNotFound,
      message: "Task \"\(taskId)\" was not found.",
      details: ["taskId": taskId]
    )
  }

  static func illegal(taskId: String, from: String, action: String) -> WorkVaultError {
    WorkVaultError(
      code: workVaultIllegalTransition,
      message: "Cannot \(action) task \"\(taskId)\" from \(from).",
      details: ["taskId": taskId, "from": from, "action": action]
    )
  }
}

struct StoredTask: Codable, Equatable {
  var schema: Int
  var taskId: String
  var url: String
  var destinationPath: String
  var headers: [String: String]
  var network: String
  var maxAttempts: Int
  var initialBackoffMs: Int
  var maxBackoffMs: Int
  var multiplier: Double
  var requiresCharging: Bool
  var requiresBatteryNotLow: Bool
  var notificationTitle: String
  var notificationBody: String
  var status: String
  var bytesDownloaded: Int64
  var totalBytes: Int64?
  var bytesPerSecond: Double
  var elapsedMs: Int64
  var attempt: Int
  var nextAttemptAtMs: Int64?
  var failureCode: String?
  var failureMessage: String?
  var httpStatus: Int?
  var failureRetryable: Bool
  var startedAtMs: Int64?
  var etag: String?

  init(config: WorkTaskConfig) {
    schema = 1
    taskId = config.taskId
    url = config.url
    destinationPath = config.destinationPath
    headers = config.headers
    network = config.network.wire
    maxAttempts = Int(config.retry.maxAttempts)
    initialBackoffMs = Int(config.retry.initialBackoffMs)
    maxBackoffMs = Int(config.retry.maxBackoffMs)
    multiplier = config.retry.multiplier
    requiresCharging = config.battery.requiresCharging
    requiresBatteryNotLow = config.battery.requiresBatteryNotLow
    notificationTitle = config.notification.title
    notificationBody = config.notification.body
    status = TaskStatus.enqueued.wire
    bytesDownloaded = 0
    totalBytes = nil
    bytesPerSecond = 0
    elapsedMs = 0
    attempt = 0
    nextAttemptAtMs = nil
    failureCode = nil
    failureMessage = nil
    httpStatus = nil
    failureRetryable = false
    startedAtMs = nil
    etag = nil
  }
}

extension NetworkConstraint {
  var wire: String {
    switch self {
    case .any: return "any"
    case .unmetered: return "unmetered"
    case .notRoaming: return "notRoaming"
    }
  }
}

extension TaskStatus {
  var wire: String {
    switch self {
    case .enqueued: return "enqueued"
    case .running: return "running"
    case .paused: return "paused"
    case .completed: return "completed"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    }
  }

  static func fromWire(_ value: String) -> TaskStatus {
    switch value {
    case "running": return .running
    case "paused": return .paused
    case "completed": return .completed
    case "failed": return .failed
    case "cancelled": return .cancelled
    default: return .enqueued
    }
  }
}

private func fileSize(atPath path: String) -> Int64? {
  guard FileManager.default.fileExists(atPath: path) else { return nil }
  let attributes = try? FileManager.default.attributesOfItem(atPath: path)
  return (attributes?[.size] as? NSNumber)?.int64Value
}

private func replaceFile(at source: URL, withDestination path: String) throws {
  let destination = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.removeItem(at: destination)
  }
  try FileManager.default.moveItem(at: source, to: destination)
}
