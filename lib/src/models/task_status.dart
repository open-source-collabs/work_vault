/// Lifecycle of one task.
///
/// [TaskStatus.completed], [TaskStatus.failed], and [TaskStatus.cancelled]
/// are terminal.
enum TaskStatus { enqueued, running, paused, completed, failed, cancelled }

/// Whether [status] will not change again.
bool taskStatusIsTerminal(TaskStatus status) {
  return switch (status) {
    TaskStatus.enqueued || TaskStatus.running || TaskStatus.paused => false,
    TaskStatus.completed || TaskStatus.failed || TaskStatus.cancelled => true,
  };
}
