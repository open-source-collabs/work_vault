import Flutter
import Foundation

/// Starts `workVaultBackgroundMain` when a background session wakes the process
/// and the UI engine is not attached.
///
/// The completion handler for `handleEventsForBackgroundURLSession` stays with
/// the session manager. This dispatcher only delivers the Dart callback.
public final class WorkVaultEngineDispatcher {
  /// Channel the headless entry point registers.
  public static let channelName = "com.workvault.work_vault/background"

  /// Snapshot entrypoint. Must match `workVaultBackgroundEntrypoint`.
  public static let entrypoint = "workVaultBackgroundMain"

  /// Library that contains [entrypoint].
  public static let libraryURI = "package:work_vault/src/isolate/background_entry_point.dart"

  /// Shared dispatcher. The session manager reaches it before Flutter starts.
  public static let shared = WorkVaultEngineDispatcher()

  private static let handlerKey = "com.workvault.work_vault.backgroundHandler"
  private static let readyTimeout: TimeInterval = 30

  private var uiChannel: FlutterMethodChannel?
  private var engine: FlutterEngine?
  private var headlessChannel: FlutterMethodChannel?
  private var pending: [[String: Any]] = []
  private var ready = false
  private var starting = false
  private var inFlight = false
  private var readyItem: DispatchWorkItem?

  /// Binds registration calls from the UI engine.
  public func bindUi(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleUi(call, result: result)
    }
    uiChannel = channel
  }

  /// Drops the UI messenger. Later session events use the headless engine.
  public func unbindUi() {
    uiChannel?.setMethodCallHandler(nil)
    uiChannel = nil
  }

  /// Queues [event] for the headless isolate.
  public func enqueue(_ event: [String: Any]) {
    DispatchQueue.main.async {
      self.offer(event)
      self.ensureEngine()
      if self.ready {
        self.pump()
      }
    }
  }

  /// Absolute path of the SQLite file the headless isolate opens.
  public func databasePath() -> String {
    let root = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("work_vault", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("work_vault.db").path
  }

  /// Builds the map Dart decodes in the headless isolate.
  public static func payload(
    taskId: String,
    status: String,
    filePath: String,
    downloadedBytes: Int64,
    totalBytes: Int64?,
    eTag: String?,
    resumptionData: Data?,
    kind: String
  ) -> [String: Any] {
    var payload: [String: Any] = [
      "kind": kind,
      "taskId": taskId,
      "status": status,
      "filePath": filePath,
      "downloadedBytes": NSNumber(value: downloadedBytes),
    ]
    if let totalBytes {
      payload["totalBytes"] = NSNumber(value: totalBytes)
    }
    if let eTag, !eTag.isEmpty {
      payload["eTag"] = eTag
    }
    if let resumptionData, !resumptionData.isEmpty {
      payload["resumptionData"] = FlutterStandardTypedData(bytes: resumptionData)
    }
    return payload
  }

  private func handleUi(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "databasePath":
      result(databasePath())
    case "registerHandler":
      guard let handle = Self.int64Argument(call.arguments) else {
        result(
          FlutterError(
            code: "invalid_config",
            message: "The callback handle is missing.",
            details: nil
          )
        )
        return
      }
      UserDefaults.standard.set(handle, forKey: Self.handlerKey)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func offer(_ event: [String: Any]) {
    if event["kind"] as? String == "progress", let taskId = event["taskId"] as? String {
      if let index = pending.lastIndex(where: { queued in
        (queued["kind"] as? String) == "progress" && (queued["taskId"] as? String) == taskId
      }) {
        pending.remove(at: index)
      }
    }
    pending.append(event)
  }

  private func ensureEngine() {
    if engine != nil || starting {
      return
    }
    starting = true
    let created = FlutterEngine(
      name: "work_vault.background",
      project: nil,
      allowHeadlessExecution: true
    )
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: created.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.ready = true
      result(nil)
      self?.pump()
    }
    headlessChannel = channel
    engine = created
    let started = created.run(
      withEntrypoint: Self.entrypoint,
      libraryURI: Self.libraryURI
    )
    guard started else {
      teardown()
      return
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.ready, self.engine === created else { return }
      self.pending.removeAll()
      self.teardown()
    }
    readyItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout, execute: timeout)
  }

  private func pump() {
    guard ready, !inFlight, let channel = headlessChannel else { return }
    guard !pending.isEmpty else {
      shutdown()
      return
    }
    readyItem?.cancel()
    readyItem = nil
    var payload = pending.removeFirst()
    payload["databasePath"] = databasePath()
    let handle = UserDefaults.standard.object(forKey: Self.handlerKey) as? Int64
      ?? (UserDefaults.standard.object(forKey: Self.handlerKey) as? NSNumber)?.int64Value
    if let handle, handle != 0 {
      payload["callbackHandle"] = NSNumber(value: handle)
    }
    inFlight = true
    channel.invokeMethod("dispatch", arguments: payload) { [weak self] _ in
      DispatchQueue.main.async {
        self?.finishOne()
      }
    }
  }

  private func finishOne() {
    inFlight = false
    if pending.isEmpty {
      shutdown()
    } else {
      pump()
    }
  }

  private func shutdown() {
    guard let channel = headlessChannel, let running = engine else {
      teardown()
      return
    }
    inFlight = true
    channel.invokeMethod("shutdown", arguments: nil) { [weak self] _ in
      DispatchQueue.main.async {
        self?.completeShutdown(running)
      }
    }
  }

  private func completeShutdown(_ running: FlutterEngine) {
    inFlight = false
    guard engine === running else { return }
    if !pending.isEmpty {
      pump()
      return
    }
    teardown()
  }

  private func teardown() {
    readyItem?.cancel()
    readyItem = nil
    ready = false
    starting = false
    inFlight = false
    headlessChannel?.setMethodCallHandler(nil)
    headlessChannel = nil
    engine?.destroyContext()
    engine = nil
  }

  private static func int64Argument(_ value: Any?) -> Int64? {
    switch value {
    case let number as NSNumber:
      return number.int64Value
    case let number as Int:
      return Int64(number)
    case let number as Int64:
      return number
    default:
      return nil
    }
  }
}
