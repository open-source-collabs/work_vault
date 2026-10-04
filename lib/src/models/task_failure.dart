import 'task_status.dart';

/// Why a task reached [TaskStatus.failed].
final class TaskFailure {
  /// Creates a task failure.
  const TaskFailure({
    required this.taskId,
    required this.code,
    required this.message,
    required this.httpStatus,
    required this.retryable,
  });

  /// Task that failed.
  final String taskId;

  /// Stable machine-readable reason, such as `http` or `io`.
  final String code;

  /// Human-readable explanation.
  final String message;

  /// HTTP status line when the failure came from a response.
  final int? httpStatus;

  /// Whether the native scheduler may try the transfer again.
  final bool retryable;

  @override
  bool operator ==(Object other) {
    return other is TaskFailure &&
        other.taskId == taskId &&
        other.code == code &&
        other.message == message &&
        other.httpStatus == httpStatus &&
        other.retryable == retryable;
  }

  @override
  int get hashCode => Object.hash(taskId, code, message, httpStatus, retryable);

  @override
  String toString() => 'TaskFailure($taskId, $code, httpStatus: $httpStatus)';
}
