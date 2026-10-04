import 'models/task_status.dart';

/// A command the caller can issue against a non-terminal task.
enum TaskCommand { pause, resume, cancel }

/// Next status after [command], or null when the command is illegal.
///
/// The switch covers every status and command so a new value fails analysis.
TaskStatus? nextTaskStatus(TaskStatus from, TaskCommand command) {
  return switch ((from, command)) {
    (TaskStatus.enqueued, TaskCommand.pause) => null,
    (TaskStatus.enqueued, TaskCommand.resume) => null,
    (TaskStatus.enqueued, TaskCommand.cancel) => TaskStatus.cancelled,
    (TaskStatus.running, TaskCommand.pause) => TaskStatus.paused,
    (TaskStatus.running, TaskCommand.resume) => null,
    (TaskStatus.running, TaskCommand.cancel) => TaskStatus.cancelled,
    (TaskStatus.paused, TaskCommand.pause) => null,
    (TaskStatus.paused, TaskCommand.resume) => TaskStatus.running,
    (TaskStatus.paused, TaskCommand.cancel) => TaskStatus.cancelled,
    (TaskStatus.completed, TaskCommand.pause) => null,
    (TaskStatus.completed, TaskCommand.resume) => null,
    (TaskStatus.completed, TaskCommand.cancel) => null,
    (TaskStatus.failed, TaskCommand.pause) => null,
    (TaskStatus.failed, TaskCommand.resume) => null,
    (TaskStatus.failed, TaskCommand.cancel) => null,
    (TaskStatus.cancelled, TaskCommand.pause) => null,
    (TaskStatus.cancelled, TaskCommand.resume) => null,
    (TaskStatus.cancelled, TaskCommand.cancel) => null,
  };
}
