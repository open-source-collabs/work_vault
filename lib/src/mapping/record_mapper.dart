import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../persistence/work_vault_database.dart';

/// Snapshot of a stored row, as the desktop and web engines report it.
///
/// The failure is only read while the row is `failed`. A failed row written
/// before failures were stored reads as the generic code `failed`.
TaskSnapshot taskSnapshotFromRecord(WorkVaultTaskRecord record) {
  final TaskStatus status = TaskStatus.values.byName(record.status);
  final int? total = record.totalBytes;
  return TaskSnapshot(
    taskId: record.taskId,
    status: status,
    progress: TaskProgress(
      taskId: record.taskId,
      bytesDownloaded: record.downloadedBytes,
      totalBytes: total,
      bytesPerSecond: 0,
      elapsed: Duration.zero,
      percentage: total != null && total > 0
          ? (record.downloadedBytes / total) * 100.0
          : null,
    ),
    failure: status == TaskStatus.failed ? _failure(record) : null,
  );
}

TaskFailure _failure(WorkVaultTaskRecord record) {
  final String? code = record.failureCode;
  if (code == null) {
    return TaskFailure(
      taskId: record.taskId,
      code: 'failed',
      message: 'Transfer failed',
      httpStatus: null,
      retryable: false,
    );
  }
  return TaskFailure(
    taskId: record.taskId,
    code: code,
    message: record.failureMessage ?? '',
    httpStatus: record.failureHttpStatus,
    retryable: record.failureRetryable ?? false,
  );
}
