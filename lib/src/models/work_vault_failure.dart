import '../task_transition.dart';
import 'task_status.dart';

/// Failure raised by [WorkVault] before or after a platform call.
sealed class WorkVaultFailure implements Exception {
  /// Creates a failure with a caller-facing [message].
  const WorkVaultFailure(this.message);

  /// Explanation suitable for logs and UI.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// `WorkVault.initialize` has not completed.
final class WorkVaultNotInitialized extends WorkVaultFailure {
  /// Creates a not-initialized failure.
  const WorkVaultNotInitialized()
    : super('WorkVault.initialize must complete before tasks can be used.');
}

/// A task config or retry policy failed validation.
final class InvalidWorkConfig extends WorkVaultFailure {
  /// Creates an invalid-config failure.
  const InvalidWorkConfig(super.message);
}

/// [taskId] is already present.
final class DuplicateTask extends WorkVaultFailure {
  /// Creates a duplicate-task failure.
  DuplicateTask(this.taskId) : super('Task "$taskId" is already enqueued.');

  /// Identity that collided.
  final String taskId;
}

/// [taskId] is not in the vault.
final class TaskNotFound extends WorkVaultFailure {
  /// Creates a missing-task failure.
  TaskNotFound(this.taskId) : super('Task "$taskId" was not found.');

  /// Identity that was requested.
  final String taskId;
}

/// Pause, resume, or cancel is not legal from the current status.
final class IllegalTaskTransition extends WorkVaultFailure {
  /// Creates an illegal-transition failure.
  IllegalTaskTransition({
    required this.taskId,
    required this.from,
    required this.action,
  }) : super('Cannot ${action.name} task "$taskId" from ${from.name}.');

  /// Task that rejected the command.
  final String taskId;

  /// Status at the time of the command.
  final TaskStatus from;

  /// Command that was rejected.
  final TaskCommand action;
}

/// The transfer failed on the host.
final class TransferFailed extends WorkVaultFailure {
  /// Creates a transfer failure.
  TransferFailed({
    required this.taskId,
    required this.code,
    required String message,
    required this.httpStatus,
    required this.retryable,
  }) : super(message);

  /// Task that failed.
  final String taskId;

  /// Stable machine-readable reason.
  final String code;

  /// HTTP status when the response itself failed.
  final int? httpStatus;

  /// Whether the host may retry within the task's retry policy.
  final bool retryable;
}

/// The platform channel failed, or the native engine is not linked yet.
final class PlatformFault extends WorkVaultFailure {
  /// Creates a platform fault.
  PlatformFault(super.message, {this.cause});

  /// Underlying channel or host error, when one was attached.
  final Object? cause;
}
