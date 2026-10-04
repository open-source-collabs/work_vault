import 'package:flutter/services.dart';

import '../gen/messages.g.dart' as pigeon;
import '../models/http_method.dart';
import '../models/network_constraint.dart';
import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../models/work_task_config.dart';
import '../models/work_vault_failure.dart';
import '../task_transition.dart';

/// Encodes [config] as a Pigeon payload.
pigeon.WorkTaskConfig workTaskConfigToPigeon(WorkTaskConfig config) {
  return pigeon.WorkTaskConfig(
    taskId: config.taskId,
    url: config.url,
    destinationPath: config.destinationPath,
    method: _methodToPigeon(config.method),
    headers: Map<String, String>.of(config.headers),
    network: _networkToPigeon(config.network),
    retry: pigeon.RetryPolicy(
      maxAttempts: config.retry.maxAttempts,
      initialBackoffMs: config.retry.initialBackoff.inMilliseconds,
      maxBackoffMs: config.retry.maxBackoff.inMilliseconds,
      multiplier: config.retry.multiplier,
    ),
    battery: pigeon.BatteryConstraint(
      requiresCharging: config.battery.requiresCharging,
      requiresBatteryNotLow: config.battery.requiresBatteryNotLow,
    ),
    notification: pigeon.NotificationMetadata(
      title: config.notification.title,
      body: config.notification.body,
      channelId: config.notification.channelId,
      channelName: config.notification.channelName,
    ),
  );
}

/// Decodes a host snapshot into the domain model.
TaskSnapshot taskSnapshotFromPigeon(pigeon.TaskSnapshot snapshot) {
  final pigeon.TaskProgress? progress = snapshot.progress;
  final pigeon.TaskFailure? failure = snapshot.failure;
  return TaskSnapshot(
    taskId: snapshot.taskId,
    status: _statusFromPigeon(snapshot.status),
    progress: progress == null ? null : taskProgressFromPigeon(progress),
    failure: failure == null ? null : _failureFromPigeon(failure),
  );
}

/// Decodes a host progress sample.
///
/// Out-of-range totals and percentages become unknown instead of failing the
/// event stream.
TaskProgress taskProgressFromPigeon(pigeon.TaskProgress progress) {
  final int bytes = progress.bytesDownloaded < 0 ? 0 : progress.bytesDownloaded;
  final int? total = progress.totalBytes == null || progress.totalBytes! < 0
      ? null
      : progress.totalBytes;
  final double speed =
      !progress.bytesPerSecond.isFinite || progress.bytesPerSecond < 0
      ? 0
      : progress.bytesPerSecond;
  final int elapsedMs = progress.elapsedMs < 0 ? 0 : progress.elapsedMs;
  final double? percentage = progress.percentage;
  return TaskProgress(
    taskId: progress.taskId,
    bytesDownloaded: bytes,
    totalBytes: total,
    bytesPerSecond: speed,
    elapsed: Duration(milliseconds: elapsedMs),
    percentage:
        percentage == null ||
            !percentage.isFinite ||
            percentage < 0 ||
            percentage > 100
        ? null
        : percentage,
  );
}

/// Maps a channel error onto a [WorkVaultFailure].
WorkVaultFailure mapPlatformFailure(PlatformException exception) {
  final Map<String, Object?> details = _detailMap(exception.details);
  final String message = exception.message ?? 'The platform call failed.';
  switch (exception.code) {
    case pigeon.workVaultNotInitialized:
      return const WorkVaultNotInitialized();
    case pigeon.workVaultInvalidConfig:
      return InvalidWorkConfig(message);
    case pigeon.workVaultDuplicateTask:
      final String? taskId = _string(details, 'taskId');
      if (taskId == null) {
        return PlatformFault(message, cause: exception);
      }
      return DuplicateTask(taskId);
    case pigeon.workVaultTaskNotFound:
      final String? taskId = _string(details, 'taskId');
      if (taskId == null) {
        return PlatformFault(message, cause: exception);
      }
      return TaskNotFound(taskId);
    case pigeon.workVaultIllegalTransition:
      final String? taskId = _string(details, 'taskId');
      final TaskStatus? from = _statusByName(_string(details, 'from'));
      final TaskCommand? action = _commandByName(_string(details, 'action'));
      if (taskId == null || from == null || action == null) {
        return PlatformFault(message, cause: exception);
      }
      return IllegalTaskTransition(taskId: taskId, from: from, action: action);
    case pigeon.workVaultTransferFailed:
      final String? taskId = _string(details, 'taskId');
      if (taskId == null) {
        return PlatformFault(message, cause: exception);
      }
      final Object? httpStatus = details['httpStatus'];
      final Object? retryable = details['retryable'];
      final String? code = _string(details, 'code');
      return TransferFailed(
        taskId: taskId,
        code: code ?? exception.code,
        message: message,
        httpStatus: httpStatus is int ? httpStatus : null,
        retryable: retryable is bool && retryable,
      );
    default:
      return PlatformFault(message, cause: exception);
  }
}

pigeon.HttpMethod _methodToPigeon(HttpMethod method) {
  return switch (method) {
    HttpMethod.get => pigeon.HttpMethod.get,
    HttpMethod.post => pigeon.HttpMethod.post,
    HttpMethod.put => pigeon.HttpMethod.put,
    HttpMethod.head => pigeon.HttpMethod.head,
  };
}

pigeon.NetworkConstraint _networkToPigeon(NetworkConstraint network) {
  return switch (network) {
    NetworkConstraint.any => pigeon.NetworkConstraint.any,
    NetworkConstraint.unmetered => pigeon.NetworkConstraint.unmetered,
    NetworkConstraint.notRoaming => pigeon.NetworkConstraint.notRoaming,
  };
}

TaskStatus _statusFromPigeon(pigeon.TaskStatus status) {
  return switch (status) {
    pigeon.TaskStatus.enqueued => TaskStatus.enqueued,
    pigeon.TaskStatus.running => TaskStatus.running,
    pigeon.TaskStatus.paused => TaskStatus.paused,
    pigeon.TaskStatus.completed => TaskStatus.completed,
    pigeon.TaskStatus.failed => TaskStatus.failed,
    pigeon.TaskStatus.cancelled => TaskStatus.cancelled,
  };
}

TaskFailure _failureFromPigeon(pigeon.TaskFailure failure) {
  return TaskFailure(
    taskId: failure.taskId,
    code: failure.code,
    message: failure.message,
    httpStatus: failure.httpStatus,
    retryable: failure.retryable,
  );
}

TaskStatus? _statusByName(String? name) {
  if (name == null) {
    return null;
  }
  for (final TaskStatus status in TaskStatus.values) {
    if (status.name == name) {
      return status;
    }
  }
  return null;
}

TaskCommand? _commandByName(String? name) {
  if (name == null) {
    return null;
  }
  for (final TaskCommand command in TaskCommand.values) {
    if (command.name == name) {
      return command;
    }
  }
  return null;
}

Map<String, Object?> _detailMap(Object? details) {
  if (details is! Map<Object?, Object?>) {
    return const <String, Object?>{};
  }
  final Map<String, Object?> mapped = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in details.entries) {
    final Object? key = entry.key;
    if (key is String) {
      mapped[key] = entry.value;
    }
  }
  return mapped;
}

String? _string(Map<String, Object?> details, String key) {
  final Object? value = details[key];
  return value is String ? value : null;
}
