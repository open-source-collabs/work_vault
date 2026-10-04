import Flutter
import XCTest

@testable import work_vault

final class RunnerTests: XCTestCase {
  private var directory: URL!
  private var manager: WorkVaultSessionManager!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("work-vault-tests-\(UUID().uuidString)", isDirectory: true)
    manager = WorkVaultSessionManager(directory: directory, createsBackgroundSessions: false)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    manager = nil
    super.tearDown()
  }

  func testEnqueueRejectsDuplicatesAndNonGet() async throws {
    let config = try sampleConfig()
    let snapshot = try await manager.enqueue(config)
    XCTAssertEqual(snapshot.status, .running)

    do {
      _ = try await manager.enqueue(config)
      XCTFail("Expected duplicate")
    } catch let error as WorkVaultError {
      XCTAssertEqual(error.code, workVaultDuplicateTask)
    }

    var post = config
    post.taskId = "job-2"
    post.method = .post
    do {
      _ = try await manager.enqueue(post)
      XCTFail("Expected invalid config")
    } catch let error as WorkVaultError {
      XCTAssertEqual(error.code, workVaultInvalidConfig)
    }
  }

  func testPauseResumeAndCancelFollowTheStatusMachine() async throws {
    _ = try await manager.enqueue(try sampleConfig())
    XCTAssertEqual(manager.task(taskId: "job-1")?.status, .running)

    try await manager.pause(taskId: "job-1")
    XCTAssertEqual(manager.task(taskId: "job-1")?.status, .paused)

    try await manager.resume(taskId: "job-1")
    XCTAssertEqual(manager.task(taskId: "job-1")?.status, .running)

    try await manager.pause(taskId: "job-1")
    do {
      try await manager.pause(taskId: "job-1")
      XCTFail("Expected illegal transition")
    } catch let error as WorkVaultError {
      XCTAssertEqual(error.code, workVaultIllegalTransition)
    }

    try await manager.cancel(taskId: "job-1")
    XCTAssertEqual(manager.task(taskId: "job-1")?.status, .cancelled)
  }

  func testRetryableFailureRequeuesAndCompletedStaysCompleted() async throws {
    let snapshot = try await manager.enqueue(try sampleConfig())
    XCTAssertEqual(snapshot.status, .running)

    manager.testing_recordFailure(taskId: "job-1", retryable: true)
    let retrying = manager.task(taskId: "job-1")
    XCTAssertEqual(retrying?.status, .enqueued)
    XCTAssertEqual(retrying?.failure?.retryable, true)

    manager.testing_markCompleted(taskId: "job-1", bytes: 4)
    manager.testing_recordFailure(taskId: "job-1", retryable: true)
    XCTAssertEqual(manager.task(taskId: "job-1")?.status, .completed)
  }

  func testIntegritySweepMarksATruncatedFileFailed() async throws {
    let destination = directory.appendingPathComponent("archive.bin")
    let snapshot = try await manager.enqueue(try sampleConfig(destinationPath: destination.path))
    XCTAssertEqual(snapshot.taskId, "job-1")
    manager.testing_markCompleted(taskId: "job-1", bytes: 10)
    try Data([1, 2, 3]).write(to: destination)

    manager.testing_sweep()

    let swept = manager.task(taskId: "job-1")
    XCTAssertEqual(swept?.status, .failed)
    XCTAssertEqual(swept?.failure?.code, "integrity")
    XCTAssertEqual(swept?.failure?.retryable, false)
  }

  func testBackgroundCompletionHandlerRunsOnce() {
    let identifier = WorkVaultRules.sessionIdentifier(for: .any)
    let finished = expectation(description: "background session finished")
    manager.handleBackgroundEvents(identifier: identifier) {
      finished.fulfill()
    }
    manager.testing_finishBackgroundEvents(identifier: identifier)
    manager.testing_finishBackgroundEvents(identifier: identifier)
    wait(for: [finished], timeout: 1)
  }

  func testBackoffSessionAndHttpRules() {
    XCTAssertEqual(
      WorkVaultRules.backoffMs(attempt: 1, initial: 1000, maxBackoff: 10_000, multiplier: 2),
      1000
    )
    XCTAssertEqual(
      WorkVaultRules.backoffMs(attempt: 3, initial: 1000, maxBackoff: 1500, multiplier: 2),
      1500
    )
    XCTAssertEqual(
      WorkVaultRules.sessionIdentifier(for: .notRoaming),
      "com.workvault.work_vault.downloads.not-roaming"
    )
    XCTAssertTrue(WorkVaultRules.isRetryableHTTPStatus(503))
    XCTAssertFalse(WorkVaultRules.isRetryableHTTPStatus(404))
    XCTAssertTrue(WorkVaultRules.isIntegrityMismatch(expectedBytes: 10, actualBytes: nil))
    XCTAssertFalse(WorkVaultRules.isIntegrityMismatch(expectedBytes: 10, actualBytes: 10))
  }

  func testBackgroundPayloadKeepsResumeBytesAndDropsEmptyFields() {
    let token = Data([9, 8, 7])
    let payload = WorkVaultEngineDispatcher.payload(
      taskId: "job-1",
      status: "paused",
      filePath: "/tmp/archive.bin",
      downloadedBytes: 3,
      totalBytes: nil,
      eTag: "\"v1\"",
      resumptionData: token,
      kind: "status"
    )
    XCTAssertEqual(payload["kind"] as? String, "status")
    XCTAssertEqual(payload["taskId"] as? String, "job-1")
    XCTAssertEqual(payload["eTag"] as? String, "\"v1\"")
    XCTAssertNil(payload["totalBytes"])
    let bytes = payload["resumptionData"] as? FlutterStandardTypedData
    XCTAssertEqual(bytes?.data, token)
  }
}

private func sampleConfig(
  taskId: String = "job-1",
  destinationPath: String = "/tmp/work-vault-archive.bin"
) throws -> WorkTaskConfig {
  WorkTaskConfig(
    taskId: taskId,
    url: "https://cdn.example.com/archive.bin",
    destinationPath: destinationPath,
    method: .get,
    headers: ["Accept": "application/octet-stream"],
    network: .any,
    retry: RetryPolicy(
      maxAttempts: 3,
      initialBackoffMs: 1000,
      maxBackoffMs: 300_000,
      multiplier: 2
    ),
    battery: BatteryConstraint(requiresCharging: false, requiresBatteryNotLow: false),
    notification: NotificationMetadata(
      title: "Archive",
      body: "Saving archive.bin",
      channelId: "work.vault.downloads",
      channelName: "Downloads"
    )
  )
}
