import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/work_task_config.dart';

/// Native execution seam used by the vault facade.
///
/// The host must not deliver [WorkVaultObserver] callbacks until [initialize]
/// has completed.
abstract interface class WorkVaultEngine {
  /// Prepares native storage and workers.
  Future<void> initialize();

  /// Attaches or detaches the listener that receives host events.
  void setObserver(WorkVaultObserver? observer);

  /// Persists [config] and schedules it.
  Future<TaskSnapshot> enqueue(WorkTaskConfig config);

  /// Requests a pause of a running task.
  Future<void> pause(String taskId);

  /// Requests that a paused task continue.
  Future<void> resume(String taskId);

  /// Requests cancellation of a non-terminal task.
  Future<void> cancel(String taskId);

  /// Reads one task, or null when the host has no row for [taskId].
  Future<TaskSnapshot?> getTask(String taskId);

  /// Reads every task the host still remembers.
  Future<List<TaskSnapshot>> getTasks();
}

/// Host events delivered while an engine is attached.
abstract interface class WorkVaultObserver {
  /// A progress sample arrived.
  void onProgress(TaskProgress progress);

  /// A task's status row changed.
  void onStatusChanged(TaskSnapshot snapshot);
}
