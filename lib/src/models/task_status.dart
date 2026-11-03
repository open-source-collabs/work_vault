/// Lifecycle of one task.
///
/// [TaskStatus.completed], [TaskStatus.failed], and [TaskStatus.cancelled]
/// are terminal.
enum TaskStatus {
  /// Accepted and waiting to start, for example for its constraints.
  enqueued,

  /// Bytes are being transferred.
  running,

  /// Stopped by the caller; [TaskCommand.resume] continues from the stored
  /// position.
  paused,

  /// Finished and, when a digest was known, verified. Terminal.
  completed,

  /// Ended with a [TaskFailure]. Terminal.
  failed,

  /// Ended by the caller. Terminal.
  cancelled,
}

/// Whether [status] will not change again.
bool taskStatusIsTerminal(TaskStatus status) {
  return switch (status) {
    TaskStatus.enqueued || TaskStatus.running || TaskStatus.paused => false,
    TaskStatus.completed || TaskStatus.failed || TaskStatus.cancelled => true,
  };
}
