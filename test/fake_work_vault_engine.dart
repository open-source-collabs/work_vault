import 'package:work_vault/src/engine/work_vault_engine.dart';
import 'package:work_vault/work_vault.dart';

/// In-memory host used by the vault tests.
final class FakeWorkVaultEngine implements WorkVaultEngine {
  /// Calls recorded in order.
  final List<String> calls = <String>[];

  /// Rows returned by [getTasks].
  final Map<String, TaskSnapshot> rows = <String, TaskSnapshot>{};

  /// Observer currently attached by the vault.
  WorkVaultObserver? observer;

  /// Runs inside [initialize], after the call is recorded.
  void Function()? duringInitialize;

  /// Runs inside [enqueue], before it returns, like a host that starts work immediately.
  void Function(WorkTaskConfig config)? duringEnqueue;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    duringInitialize?.call();
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    calls.add(observer == null ? 'clearObserver' : 'setObserver');
    this.observer = observer;
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) {
    calls.add('enqueue');
    final TaskSnapshot snapshot = TaskSnapshot(
      taskId: config.taskId,
      status: TaskStatus.enqueued,
    );
    rows[config.taskId] = snapshot;
    duringEnqueue?.call(config);
    return Future<TaskSnapshot>.value(snapshot);
  }

  @override
  Future<void> pause(String taskId) async {
    calls.add('pause:$taskId');
  }

  @override
  Future<void> resume(String taskId) async {
    calls.add('resume:$taskId');
  }

  @override
  Future<void> cancel(String taskId) async {
    calls.add('cancel:$taskId');
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) async {
    calls.add('getTask:$taskId');
    return rows[taskId];
  }

  @override
  Future<List<TaskSnapshot>> getTasks() async {
    calls.add('getTasks');
    return List<TaskSnapshot>.of(rows.values);
  }
}
