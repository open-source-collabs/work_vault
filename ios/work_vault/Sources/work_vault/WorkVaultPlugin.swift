import Flutter
import Foundation

/// Pigeon host API backed by the background `URLSession` engine.
public class WorkVaultPlugin: NSObject, FlutterPlugin, WorkVaultHostApi {
  private let flutterApi: WorkVaultFlutterApi

  init(flutterApi: WorkVaultFlutterApi) {
    self.flutterApi = flutterApi
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WorkVaultPlugin(
      flutterApi: WorkVaultFlutterApi(binaryMessenger: registrar.messenger())
    )
    WorkVaultEngineDispatcher.shared.bindUi(binaryMessenger: registrar.messenger())
    WorkVaultSessionManager.shared.attach(flutterApi: instance.flutterApi)
    WorkVaultHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    WorkVaultEngineDispatcher.shared.unbindUi()
    WorkVaultSessionManager.shared.attach(flutterApi: nil)
    WorkVaultHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
  }

  func initialize() async throws {
    try await WorkVaultSessionManager.shared.initialize()
  }

  func enqueue(config: WorkTaskConfig) async throws -> TaskSnapshot {
    try await WorkVaultSessionManager.shared.enqueue(config)
  }

  func pause(taskId: String) async throws {
    try await WorkVaultSessionManager.shared.pause(taskId: taskId)
  }

  func resume(taskId: String) async throws {
    try await WorkVaultSessionManager.shared.resume(taskId: taskId)
  }

  func cancel(taskId: String) async throws {
    try await WorkVaultSessionManager.shared.cancel(taskId: taskId)
  }

  func getTask(taskId: String) async throws -> TaskSnapshot? {
    WorkVaultSessionManager.shared.task(taskId: taskId)
  }

  func getTasks() async throws -> [TaskSnapshot] {
    WorkVaultSessionManager.shared.tasks()
  }
}
