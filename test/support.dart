import 'package:work_vault/work_vault.dart';

/// A valid download description for tests.
WorkTaskConfig sampleConfig({
  String taskId = 'job-1',
  String url = 'https://cdn.example.com/archive.bin',
  String destinationPath = '/data/user/0/archive.bin',
  HttpMethod method = HttpMethod.get,
  Map<String, String> headers = const <String, String>{},
  RetryPolicy retry = const RetryPolicy(),
}) {
  return WorkTaskConfig(
    taskId: taskId,
    url: url,
    destinationPath: destinationPath,
    method: method,
    headers: headers,
    retry: retry,
    notification: const NotificationMetadata(
      title: 'Archive',
      body: 'Saving archive.bin',
      channelId: 'work.vault.downloads',
      channelName: 'Downloads',
    ),
  );
}

/// Minimal snapshot used by stream tests.
TaskSnapshot sampleSnapshot({
  String taskId = 'job-1',
  TaskStatus status = TaskStatus.enqueued,
  TaskProgress? progress,
  TaskFailure? failure,
}) {
  return TaskSnapshot(
    taskId: taskId,
    status: status,
    progress: progress,
    failure: failure,
  );
}
