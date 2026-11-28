// The engine seam is not part of the public API. Tests reach it the same way
// the plugin's own tests do (see test/fake_work_vault_engine.dart).
// ignore: implementation_imports
import 'package:work_vault/src/engine/work_vault_engine.dart';
import 'package:work_vault/work_vault.dart';

/// In-memory host for the example's tests.
final class FakeEngine implements WorkVaultEngine {
  /// Calls recorded in order.
  final List<String> calls = <String>[];

  /// Rows returned by [getTasks], as the host would remember them.
  final Map<String, TaskSnapshot> rows = <String, TaskSnapshot>{};

  /// When set, [initialize] throws this.
  Object? initializeError;

  /// When set, pause, resume, and cancel throw this.
  WorkVaultFailure? commandError;

  /// Runs inside [enqueue] before it returns, like a host that starts at once.
  void Function(WorkTaskConfig config)? duringEnqueue;

  WorkVaultObserver? _observer;

  /// Delivers a status change as the host would.
  void emitStatus(TaskSnapshot snapshot) {
    rows[snapshot.taskId] = snapshot;
    _observer?.onStatusChanged(snapshot);
  }

  /// Delivers a progress sample as the host would.
  void emitProgress(TaskProgress progress) {
    _observer?.onProgress(progress);
  }

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    final Object? error = initializeError;
    if (error != null) {
      throw error;
    }
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    _observer = observer;
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    calls.add('enqueue:${config.taskId}');
    final TaskSnapshot snapshot = TaskSnapshot(
      taskId: config.taskId,
      status: TaskStatus.enqueued,
    );
    rows[config.taskId] = snapshot;
    duringEnqueue?.call(config);
    return snapshot;
  }

  @override
  Future<void> pause(String taskId) => _command('pause', taskId);

  @override
  Future<void> resume(String taskId) => _command('resume', taskId);

  @override
  Future<void> cancel(String taskId) => _command('cancel', taskId);

  Future<void> _command(String name, String taskId) async {
    calls.add('$name:$taskId');
    final WorkVaultFailure? error = commandError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) async => rows[taskId];

  @override
  Future<List<TaskSnapshot>> getTasks() async {
    calls.add('getTasks');
    return List<TaskSnapshot>.of(rows.values);
  }
}

/// A progress sample for [taskId].
TaskProgress progressSample(
  String taskId, {
  int downloaded = 512,
  int? total = 1024,
  double speed = 256,
}) {
  return TaskProgress(
    taskId: taskId,
    bytesDownloaded: downloaded,
    totalBytes: total,
    bytesPerSecond: speed,
    elapsed: const Duration(seconds: 2),
    percentage: total == null ? null : downloaded * 100 / total,
  );
}
