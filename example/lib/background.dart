import 'dart:convert';
import 'dart:io';

import 'package:work_vault/work_vault.dart';

/// Identifies this engine process. A later headless engine gets a new value.
final String workVaultHeadlessEngineToken = DateTime.now()
    .toUtc()
    .microsecondsSinceEpoch
    .toString();

/// App files directory next to the cache directory Android gives this process.
Directory rehearsalDirectory() {
  final String temp = Directory.systemTemp.path.replaceAll(r'\', '/');
  final int slash = temp.lastIndexOf('/');
  final String leaf = slash < 0 ? temp : temp.substring(slash + 1);
  if (slash <= 0 || (leaf != 'cache' && leaf != 'code_cache')) {
    throw StateError('Could not resolve the app files directory from $temp.');
  }
  return Directory('${temp.substring(0, slash)}/files/rehearsal');
}

/// Marker written once a survive download is running and safe to kill.
File surviveSeedFile() => File('${rehearsalDirectory().path}/survive_seeded');

/// One JSON object per headless callback, appended by [onWorkVaultBackground].
File headlessLogFile() => File('${rehearsalDirectory().path}/headless.jsonl');

/// Marker written once a headless download has bytes on disk and can be killed.
File headlessSeedFile() => File('${rehearsalDirectory().path}/headless_seeded');

/// Persists [event] so a later launch can see that the headless engine ran.
@pragma('vm:entry-point')
Future<void> onWorkVaultBackground(WorkVaultBackgroundEvent event) async {
  final Directory directory = rehearsalDirectory();
  await directory.create(recursive: true);
  final String line = jsonEncode(<String, Object?>{
    'engine': workVaultHeadlessEngineToken,
    'kind': event.kind,
    'taskId': event.taskId,
    'status': event.status,
    'downloadedBytes': event.downloadedBytes,
    'databasePath': event.databasePath,
    'verification': event.verificationStatus.name,
  });
  await headlessLogFile().writeAsString(
    '$line\n',
    mode: FileMode.append,
    flush: true,
  );
}
