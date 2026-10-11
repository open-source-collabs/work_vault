import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:work_vault/src/isolate/background_event_processor.dart'
    show sha256HexOfFile;
import 'package:work_vault/work_vault.dart';

/// Exit criterion for version 1 on a device.
///
/// One GET fixture is downloaded straight through to establish a reference digest, then
/// downloaded again with a pause and a resume in the middle. Both files must hash to the
/// same SHA-256, which is what proves the resumed bytes were appended at the right offset.
///
/// Run against a real fixture:
///
/// ```sh
/// flutter test integration_test/resumable_download_test.dart \
///   --dart-define=WORK_VAULT_FIXTURE_URL=https://host/path/fixture.bin \
///   --dart-define=WORK_VAULT_FIXTURE_SHA256=<hex>
/// ```
const String _fixtureUrl = String.fromEnvironment(
  'WORK_VAULT_FIXTURE_URL',
  defaultValue: 'https://speed.cloudflare.com/__down?bytes=8388608',
);

/// Optional expected digest. When empty the reference download supplies it.
const String _fixtureSha256 = String.fromEnvironment(
  'WORK_VAULT_FIXTURE_SHA256',
);

const Duration _transferTimeout = Duration(minutes: 5);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('work-vault-fixture-');
    await WorkVault.instance.initialize();
  });

  tearDown(() async {
    for (final TaskSnapshot task in await WorkVault.instance.getTasks()) {
      if (!taskStatusIsTerminal(task.status)) {
        await WorkVault.instance.cancel(task.taskId);
      }
    }
    await WorkVault.instance.dispose();
    if (workspace.existsSync()) {
      await workspace.delete(recursive: true);
    }
  });

  testWidgets('a paused and resumed GET matches the reference digest', (
    WidgetTester tester,
  ) async {
    final File reference = File('${workspace.path}/reference.bin');
    final File resumed = File('${workspace.path}/resumed.bin');

    await _enqueue(taskId: 'fixture-reference', file: reference);
    await _awaitStatus('fixture-reference', TaskStatus.completed);
    final String? referenceDigest = await sha256HexOfFile(reference.path);
    expect(referenceDigest, isNotNull, reason: 'the reference file is missing');
    if (_fixtureSha256.isNotEmpty) {
      expect(referenceDigest, _fixtureSha256.toLowerCase());
    }
    final int size = reference.lengthSync();
    expect(size, greaterThan(0));

    await _enqueue(taskId: 'fixture-resumed', file: resumed);
    final int pausedAt = await _awaitPartialBytes('fixture-resumed');
    expect(pausedAt, greaterThan(0));
    expect(pausedAt, lessThan(size));

    await WorkVault.instance.pause('fixture-resumed');
    await _awaitStatus('fixture-resumed', TaskStatus.paused);
    if (Platform.isAndroid) {
      // Android appends to the destination file, so the paused bytes are on disk.
      final int settled = resumed.existsSync() ? resumed.lengthSync() : 0;
      expect(settled, greaterThan(0), reason: 'the paused bytes were discarded');
      expect(settled, lessThanOrEqualTo(size));
    } else {
      // iOS keeps paused bytes as URLSession resume data until the download
      // finishes, so the host's byte count is what shows they were retained.
      final TaskSnapshot? paused = await WorkVault.instance.getTask(
        'fixture-resumed',
      );
      expect(
        paused?.progress?.bytesDownloaded ?? 0,
        greaterThan(0),
        reason: 'the paused bytes were discarded',
      );
    }

    await WorkVault.instance.resume('fixture-resumed');
    await _awaitStatus('fixture-resumed', TaskStatus.completed);

    expect(resumed.lengthSync(), size);
    expect(await sha256HexOfFile(resumed.path), referenceDigest);
  }, timeout: const Timeout(Duration(minutes: 12)));
}

Future<void> _enqueue({required String taskId, required File file}) async {
  await WorkVault.instance.enqueue(
    WorkTaskConfig(
      taskId: taskId,
      url: _fixtureUrl,
      destinationPath: file.path,
      notification: const NotificationMetadata(
        title: 'Fixture',
        body: 'Downloading the test fixture',
        channelId: 'work.vault.tests',
        channelName: 'Work Vault tests',
      ),
    ),
  );
}

/// Waits until [taskId] reaches [target], failing on any other terminal status.
Future<void> _awaitStatus(String taskId, TaskStatus target) async {
  final Completer<void> reached = Completer<void>();
  final StreamSubscription<TaskSnapshot> subscription = WorkVault.instance
      .watchStatus(taskId: taskId)
      .listen((TaskSnapshot snapshot) {
        if (reached.isCompleted) {
          return;
        }
        if (snapshot.status == target) {
          reached.complete();
        } else if (taskStatusIsTerminal(snapshot.status)) {
          reached.completeError(
            StateError(
              'Task "$taskId" reached ${snapshot.status.name} '
              'instead of ${target.name}: ${snapshot.failure?.message}',
            ),
          );
        }
      });
  try {
    await reached.future.timeout(
      _transferTimeout,
      onTimeout: () => throw TimeoutException(
        'Task "$taskId" did not reach ${target.name}',
        _transferTimeout,
      ),
    );
  } finally {
    await subscription.cancel();
  }
}

/// Waits for the first progress sample that has bytes on disk but is not finished.
Future<int> _awaitPartialBytes(String taskId) async {
  final Completer<int> partial = Completer<int>();
  final StreamSubscription<TaskProgress> subscription = WorkVault.instance
      .watchProgress(taskId)
      .listen((TaskProgress progress) {
        if (partial.isCompleted) {
          return;
        }
        final int? total = progress.totalBytes;
        final bool finished =
            total != null && progress.bytesDownloaded >= total;
        if (progress.bytesDownloaded > 0 && !finished) {
          partial.complete(progress.bytesDownloaded);
        }
      });
  try {
    return await partial.future.timeout(
      _transferTimeout,
      onTimeout: () => throw TimeoutException(
        'Task "$taskId" never reported partial bytes',
        _transferTimeout,
      ),
    );
  } finally {
    await subscription.cancel();
  }
}
