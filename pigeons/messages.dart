import 'package:pigeon/pigeon.dart';

/// Platform contract for work_vault.
///
/// Regenerate with `dart run pigeon --input pigeons/messages.dart`.
/// Both sides of the channel must come from the same Pigeon version.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/gen/messages.g.dart',
    dartOptions: DartOptions(),
    dartPackageName: 'work_vault',
    kotlinOut: 'android/src/main/kotlin/com/workvault/work_vault/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.workvault.work_vault',
      errorClassName: 'WorkVaultError',
    ),
    swiftOut: 'ios/work_vault/Sources/work_vault/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'WorkVaultError'),
  ),
)
/// Channel error codes shared by Dart, Kotlin, and Swift.
const String workVaultNotInitialized = 'not_initialized';
const String workVaultInvalidConfig = 'invalid_config';
const String workVaultDuplicateTask = 'duplicate_task';
const String workVaultTaskNotFound = 'task_not_found';
const String workVaultIllegalTransition = 'illegal_transition';
const String workVaultTransferFailed = 'transfer_failed';
const String workVaultUnimplemented = 'unimplemented';

/// Who may carry the transfer.
enum NetworkConstraint { any, unmetered, notRoaming }

/// HTTP verb stored on the task.
///
/// Version 1 executes [HttpMethod.get] only. The other values reserve the
/// contract for later upload work.
enum HttpMethod { get, post, put, head }

/// Lifecycle of one task. Terminal values are completed, failed, and cancelled.
enum TaskStatus { enqueued, running, paused, completed, failed, cancelled }

/// Backoff applied after a retryable transfer failure.
class RetryPolicy {
  RetryPolicy({
    required this.maxAttempts,
    required this.initialBackoffMs,
    required this.maxBackoffMs,
    required this.multiplier,
  });

  int maxAttempts;
  int initialBackoffMs;
  int maxBackoffMs;
  double multiplier;
}

/// Power conditions that must hold before the task runs.
class BatteryConstraint {
  BatteryConstraint({
    required this.requiresCharging,
    required this.requiresBatteryNotLow,
  });

  bool requiresCharging;
  bool requiresBatteryNotLow;
}

/// Copy shown while a foreground transfer is running, and when it finishes.
class NotificationMetadata {
  NotificationMetadata({
    required this.title,
    required this.body,
    required this.channelId,
    required this.channelName,
  });

  String title;
  String body;
  String channelId;
  String channelName;
}

/// Everything the native worker needs to start one download.
class WorkTaskConfig {
  WorkTaskConfig({
    required this.taskId,
    required this.url,
    required this.destinationPath,
    required this.method,
    required this.headers,
    required this.network,
    required this.retry,
    required this.battery,
    required this.notification,
  });

  /// Stable caller-supplied identity. Enqueueing the same id again fails.
  String taskId;

  /// Absolute https URL.
  String url;

  /// Absolute file path that receives the response body.
  String destinationPath;

  HttpMethod method;
  Map<String, String> headers;
  NetworkConstraint network;
  RetryPolicy retry;
  BatteryConstraint battery;
  NotificationMetadata notification;
}

/// One progress sample.
///
/// [percentage] is in the range 0 to 100 when [totalBytes] is known.
/// Both [percentage] and [totalBytes] are null for an indeterminate transfer.
class TaskProgress {
  TaskProgress({
    required this.taskId,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.elapsedMs,
    required this.percentage,
  });

  String taskId;
  int bytesDownloaded;
  int? totalBytes;
  double bytesPerSecond;
  int elapsedMs;
  double? percentage;
}

/// Why a task reached [TaskStatus.failed].
class TaskFailure {
  TaskFailure({
    required this.taskId,
    required this.code,
    required this.message,
    required this.httpStatus,
    required this.retryable,
  });

  String taskId;
  String code;
  String message;
  int? httpStatus;
  bool retryable;
}

/// Last known state of a task, including the latest progress sample.
class TaskSnapshot {
  TaskSnapshot({
    required this.taskId,
    required this.status,
    required this.progress,
    required this.failure,
  });

  String taskId;
  TaskStatus status;
  TaskProgress? progress;
  TaskFailure? failure;
}

/// Commands the host executes.
///
/// Each handler runs serially on a background task queue. [initialize] must
/// complete before any [WorkVaultFlutterApi] callback.
@HostApi()
abstract class WorkVaultHostApi {
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void initialize();

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  TaskSnapshot enqueue(WorkTaskConfig config);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void pause(String taskId);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void resume(String taskId);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void cancel(String taskId);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  TaskSnapshot? getTask(String taskId);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<TaskSnapshot> getTasks();
}

/// Events the host delivers while a Flutter engine is attached.
@FlutterApi()
abstract class WorkVaultFlutterApi {
  void onProgress(TaskProgress progress);

  void onStatusChanged(TaskSnapshot snapshot);
}
