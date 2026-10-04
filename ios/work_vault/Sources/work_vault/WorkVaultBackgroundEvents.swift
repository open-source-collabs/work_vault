import BackgroundTasks
import Foundation

/// Hooks the host app calls from `AppDelegate`.
///
/// Background `URLSession` events are delivered by relaunching the process,
/// which can happen before the Flutter engine exists. Register the maintenance
/// task inside `application(_:didFinishLaunchingWithOptions:)` and forward
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here.
public enum WorkVaultBackgroundEvents {
  /// `BGProcessingTask` identifier. The host `Info.plist` must list it under
  /// `BGTaskSchedulerPermittedIdentifiers`.
  public static let maintenanceTaskIdentifier = "com.workvault.work_vault.maintenance"

  /// Background `URLSession` identifiers, one per network constraint.
  public static let sessionIdentifiers: Set<String> = [
    WorkVaultRules.sessionIdentifier(for: .any),
    WorkVaultRules.sessionIdentifier(for: .unmetered),
    WorkVaultRules.sessionIdentifier(for: .notRoaming),
  ]

  private static let registrationLock = NSLock()
  private static var maintenanceRegistered = false

  /// Registers the maintenance task. Call this once, before
  /// `application(_:didFinishLaunchingWithOptions:)` returns.
  public static func registerMaintenanceTask() {
    registrationLock.lock()
    let alreadyRegistered = maintenanceRegistered
    maintenanceRegistered = true
    registrationLock.unlock()
    guard !alreadyRegistered else {
      return
    }

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: maintenanceTaskIdentifier,
      using: nil
    ) { task in
      guard let processing = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      WorkVaultSessionManager.shared.performMaintenance(processing)
    }
  }

  /// Stores the system completion handler and reconnects the named background session.
  ///
  /// The handler is invoked from `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
  /// Identifiers this engine does not own run the handler immediately.
  public static func handleEvents(
    forBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard sessionIdentifiers.contains(identifier) else {
      completionHandler()
      return
    }
    WorkVaultSessionManager.shared.handleBackgroundEvents(
      identifier: identifier,
      completionHandler: completionHandler
    )
  }
}
