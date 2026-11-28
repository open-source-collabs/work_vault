import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:work_vault/work_vault.dart';

import 'platform/file_info.dart';

/// Public HTTPS file used by the one-tap sample download.
const String sampleDownloadUrl =
    'https://raw.githubusercontent.com/flutter/flutter/master/README.md';

/// File name the sample download is saved as.
const String sampleFileName = 'flutter-readme.md';

/// Android notification channel shared by every download in the example.
const String notificationChannelId = 'work.vault.downloads';

/// Directory that receives downloads, or an empty string on web.
///
/// Uses the app documents directory and falls back to the temporary
/// directory on platforms that do not provide one.
Future<String> resolveDownloadDirectory() async {
  if (kIsWeb) {
    return '';
  }
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } on Object {
    return (await getTemporaryDirectory()).path;
  }
}

/// A task id derived from [fileName] that is unique per call time.
///
/// Characters the vault rejects are replaced, and the result stays within the
/// 128-character limit that [WorkTaskConfig.validate] enforces.
String taskIdFor(String fileName, DateTime now) {
  String stem = fileName.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  if (stem.isEmpty) {
    stem = 'download';
  }
  if (stem.length > 100) {
    stem = stem.substring(0, 100);
  }
  return '$stem-${now.toUtc().millisecondsSinceEpoch}';
}

/// Notification copy shown while [fileName] downloads.
NotificationMetadata notificationFor(String fileName) {
  return NotificationMetadata(
    title: 'Downloading',
    body: 'Saving $fileName',
    channelId: notificationChannelId,
    channelName: 'Downloads',
  );
}

/// Config for the one-tap sample download, saved under [directory].
///
/// Each call gets its own task id and file, so the sample can be added more
/// than once without two tasks writing the same destination.
WorkTaskConfig sampleConfig(String directory, DateTime now) {
  final String taskId = taskIdFor('sample', now);
  final String fileName = '$taskId-$sampleFileName';
  return WorkTaskConfig(
    taskId: taskId,
    url: sampleDownloadUrl,
    destinationPath: joinDownloadPath(directory, fileName),
    notification: notificationFor(fileName),
  );
}
