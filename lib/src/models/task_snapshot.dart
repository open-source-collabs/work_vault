import 'task_failure.dart';
import 'task_progress.dart';
import 'task_status.dart';

/// Last known state of a task.
final class TaskSnapshot {
  /// Creates a task snapshot.
  const TaskSnapshot({
    required this.taskId,
    required this.status,
    this.progress,
    this.failure,
  });

  /// Stable task identity.
  final String taskId;

  /// Current lifecycle value.
  final TaskStatus status;

  /// Latest progress sample, when the worker has reported one.
  final TaskProgress? progress;

  /// Failure details when [status] is [TaskStatus.failed].
  final TaskFailure? failure;

  /// Returns a copy with the given fields replaced.
  TaskSnapshot copyWith({
    TaskStatus? status,
    TaskProgress? progress,
    TaskFailure? failure,
    bool clearProgress = false,
    bool clearFailure = false,
  }) {
    return TaskSnapshot(
      taskId: taskId,
      status: status ?? this.status,
      progress: clearProgress ? null : progress ?? this.progress,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TaskSnapshot &&
        other.taskId == taskId &&
        other.status == status &&
        other.progress == progress &&
        other.failure == failure;
  }

  @override
  int get hashCode => Object.hash(taskId, status, progress, failure);

  @override
  String toString() => 'TaskSnapshot($taskId, $status)';
}

/// A cached snapshot paired with the progress sample it currently carries.
typedef TaskObservation = ({TaskSnapshot snapshot, TaskProgress? progress});
