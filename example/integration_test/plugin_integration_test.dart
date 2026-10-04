import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:work_vault/src/isolate/background_event_processor.dart'
    show sha256HexOfFile;
import 'package:work_vault/work_vault.dart';
import 'package:work_vault_example/background.dart';

const String _phase = String.fromEnvironment(
  'WORK_VAULT_PHASE',
  defaultValue: 'controls',
);

const String _base = String.fromEnvironment('WORK_VAULT_FIXTURE_BASE');

const String _sha = String.fromEnvironment('WORK_VAULT_FIXTURE_SHA256');

const int _length = int.fromEnvironment('WORK_VAULT_FIXTURE_LENGTH');

const Duration _transferTimeout = Duration(minutes: 2);

const NotificationMetadata _notification = NotificationMetadata(
  title: 'Fixture',
  body: 'Rehearsal download',
  channelId: 'work.vault.rehearsal',
  channelName: 'Work Vault rehearsal',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    if (_base.isEmpty || _sha.isEmpty || _length <= 0) {
      fail(
        'Set WORK_VAULT_FIXTURE_BASE, WORK_VAULT_FIXTURE_SHA256, and '
        'WORK_VAULT_FIXTURE_LENGTH. tool/production_rehearsal.dart does this.',
      );
    }
    await rehearsalDirectory().create(recursive: true);
    await WorkVault.registerBackgroundHandler(onWorkVaultBackground);
    await WorkVault.instance.initialize();
  });

  tearDown(() async {
    if (!WorkVault.instance.isInitialized) {
      return;
    }
    if (_phase == 'controls') {
      for (final TaskSnapshot task in await WorkVault.instance.getTasks()) {
        if (!taskStatusIsTerminal(task.status)) {
          await WorkVault.instance.cancel(task.taskId);
        }
      }
    }
    await WorkVault.instance.dispose();
  });

  switch (_phase) {
    case 'controls':
      _controls();
    case 'survive-seed':
      _surviveSeed();
    case 'survive-check':
      _surviveCheck();
    case 'headless-seed':
      _headlessSeed();
    case 'headless-check':
      _headlessCheck();
    case 'reboot-seed':
      _rebootSeed();
    case 'reboot-check':
      _rebootCheck();
    case 'battery-hold':
      _batteryHold();
    case 'battery-drop':
      _batteryDrop();
    case 'host-init':
      _hostInit();
    case 'quota':
      _quota();
    default:
      test('phase is recognized', () {
        fail('Unknown WORK_VAULT_PHASE "$_phase".');
      });
  }
}

void _controls() {
  testWidgets('enqueue reports progress and completes', (
    WidgetTester tester,
  ) async {
    final File file = _file('controls-blob');
    final Stream<TaskProgress> progress = WorkVault.instance.watchProgress(
      'controls-blob',
    );
    final TaskSnapshot enqueued = await _enqueue(
      'controls-blob',
      '/blob',
      file,
    );
    expect(enqueued.status, TaskStatus.enqueued);
    final TaskProgress sample = await progress
        .firstWhere((TaskProgress event) => event.bytesDownloaded > 0)
        .timeout(_transferTimeout);
    expect(sample.totalBytes, _length);
    await _awaitStatus('controls-blob', TaskStatus.completed);
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  });

  testWidgets('pause keeps bytes and resume finishes', (
    WidgetTester tester,
  ) async {
    final File file = _file('controls-pause');
    await _enqueue('controls-pause', '/drip', file);
    await _awaitBytes(file);
    await WorkVault.instance.pause('controls-pause');
    await _awaitStatus('controls-pause', TaskStatus.paused);
    final int paused = file.lengthSync();
    expect(paused, greaterThan(0));
    expect(paused, lessThan(_length));
    await WorkVault.instance.resume('controls-pause');
    await _awaitStatus('controls-pause', TaskStatus.completed);
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  });

  testWidgets('cancel stops a running download', (WidgetTester tester) async {
    final File file = _file('controls-cancel');
    await _enqueue('controls-cancel', '/drip', file);
    await _awaitStatus('controls-cancel', TaskStatus.running);
    await WorkVault.instance.cancel('controls-cancel');
    await _awaitStatus('controls-cancel', TaskStatus.cancelled);
  });

  testWidgets('a second enqueue of the same taskId fails', (
    WidgetTester tester,
  ) async {
    final File file = _file('controls-dup');
    await _enqueue('controls-dup', '/blob', file);
    await expectLater(
      _enqueue('controls-dup', '/blob', file),
      throwsA(isA<DuplicateTask>()),
    );
  });

  testWidgets('HTTP 404 fails the task', (WidgetTester tester) async {
    final File file = _file('controls-missing');
    await _enqueue(
      'controls-missing',
      '/missing',
      file,
      attempts: 1,
      expectSha: false,
    );
    final TaskSnapshot failed = await _awaitStatus(
      'controls-missing',
      TaskStatus.failed,
    );
    expect(failed.failure?.code, 'http');
    expect(failed.failure?.httpStatus, 404);
  });

  testWidgets('a dropped connection keeps bytes already written', (
    WidgetTester tester,
  ) async {
    final File file = _file('controls-drop');
    final List<int> sizes = <int>[];
    final Timer poll = Timer.periodic(const Duration(milliseconds: 40), (
      Timer timer,
    ) {
      if (file.existsSync()) {
        sizes.add(file.lengthSync());
      }
    });
    try {
      await _enqueue('controls-drop', '/drop', file);
      await _awaitStatus('controls-drop', TaskStatus.completed);
    } finally {
      poll.cancel();
    }
    expect(
      sizes.any((int size) => size > 0 && size < _length),
      isTrue,
      reason: 'bytes written before the drop were discarded',
    );
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  });

  testWidgets('a truncated file fails integrity', (WidgetTester tester) async {
    final File file = _file('controls-short');
    await _enqueue('controls-short', '/short', file, attempts: 1);
    final TaskSnapshot failed = await _awaitStatus(
      'controls-short',
      TaskStatus.failed,
    );
    expect(failed.failure?.code, 'checksum');
    expect(file.lengthSync(), greaterThan(0));
    expect(file.lengthSync(), lessThan(_length));
    expect(await sha256HexOfFile(file.path), isNot(_sha));
  });
}

void _surviveSeed() {
  testWidgets('survive download is running before the process is killed', (
    WidgetTester tester,
  ) async {
    final File file = _file('survive-transfer');
    await _enqueue('survive-transfer', '/survive', file, attempts: 5);
    await _awaitStatus('survive-transfer', TaskStatus.running);
    await surviveSeedFile().writeAsString('seeded', flush: true);
    await Completer<void>().future.timeout(const Duration(minutes: 8));
  }, timeout: const Timeout(Duration(minutes: 9)));
}

void _surviveCheck() {
  testWidgets('a killed download comes back and finishes', (
    WidgetTester tester,
  ) async {
    final TaskSnapshot? task = await WorkVault.instance.getTask(
      'survive-transfer',
    );
    expect(task, isNotNull);
    expect(task!.status, anyOf(TaskStatus.enqueued, TaskStatus.running));
    await _awaitStatus('survive-transfer', TaskStatus.completed);
    final File file = _file('survive-transfer');
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  });
}

void _headlessSeed() {
  testWidgets('headless download has bytes before the UI process is killed', (
    WidgetTester tester,
  ) async {
    final File file = _file('headless-transfer');
    await _enqueue('headless-transfer', '/headless', file, attempts: 5);
    await _awaitBytes(file);
    await headlessSeedFile().writeAsString('seeded', flush: true);
    await Completer<void>().future.timeout(const Duration(minutes: 8));
  }, timeout: const Timeout(Duration(minutes: 9)));
}

void _headlessCheck() {
  testWidgets('the headless engine wrote SQLite and invoked the handler once', (
    WidgetTester tester,
  ) async {
    final List<String> lines = headlessLogFile()
        .readAsLinesSync()
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    expect(lines, isNotEmpty);
    final Set<String> engines = <String>{
      for (final String line in lines) _field(line, 'engine'),
    };
    expect(engines, hasLength(1));
    final String databasePath = _field(lines.first, 'databasePath');
    final WorkVaultDatabase database = WorkVaultDatabase.openFile(databasePath);
    try {
      final WorkVaultTaskRecord? row = database.getTask('headless-transfer');
      expect(row, isNotNull);
      expect(row!.status, 'completed');
      expect(row.downloadedBytes, _length);
    } finally {
      database.close();
    }
  });
}

void _rebootSeed() {
  testWidgets('reboot download has bytes before the device restarts', (
    WidgetTester tester,
  ) async {
    final File file = _file('reboot-transfer');
    await _enqueue('reboot-transfer', '/slow', file, attempts: 8);
    await _awaitBytes(file);
    await _marker('reboot_seeded').writeAsString('seeded', flush: true);
    await Completer<void>().future.timeout(const Duration(minutes: 8));
  }, timeout: const Timeout(Duration(minutes: 9)));
}

void _rebootCheck() {
  testWidgets('a download interrupted by reboot finished without the UI', (
    WidgetTester tester,
  ) async {
    final TaskSnapshot? task = await WorkVault.instance.getTask(
      'reboot-transfer',
    );
    expect(task?.status, TaskStatus.completed);
    final File file = _file('reboot-transfer');
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  });
}

void _batteryHold() {
  testWidgets('a low battery holds requiresBatteryNotLow work until it recovers', (
    WidgetTester tester,
  ) async {
    final File file = _file('battery-hold');
    await _enqueue(
      'battery-hold',
      '/blob',
      file,
      battery: const BatteryConstraint(requiresBatteryNotLow: true),
    );
    await Future<void>.delayed(const Duration(seconds: 20));
    final TaskSnapshot? held = await WorkVault.instance.getTask('battery-hold');
    expect(held?.status, TaskStatus.enqueued);
    expect(file.existsSync() ? file.lengthSync() : 0, 0);
    await _marker('battery_held').writeAsString('held', flush: true);
    await _awaitStatus('battery-hold', TaskStatus.completed);
    expect(await sha256HexOfFile(file.path), _sha);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

void _batteryDrop() {
  testWidgets('a low battery stops a running download and keeps its bytes', (
    WidgetTester tester,
  ) async {
    final File file = _file('battery-drop');
    await _enqueue(
      'battery-drop',
      '/slow',
      file,
      attempts: 5,
      battery: const BatteryConstraint(requiresBatteryNotLow: true),
    );
    await _awaitBytes(file);
    final Future<TaskSnapshot> stopped = _awaitStatus(
      'battery-drop',
      TaskStatus.enqueued,
    );
    await _marker('battery_running').writeAsString('running', flush: true);
    await stopped;
    final int kept = file.lengthSync();
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(kept, greaterThan(0));
    expect(kept, lessThan(_length));
    expect(file.lengthSync(), kept, reason: 'bytes kept arriving while stopped');
    final Future<TaskSnapshot> finished = _awaitStatus(
      'battery-drop',
      TaskStatus.completed,
    );
    await _marker('battery_stopped').writeAsString('$kept', flush: true);
    await finished;
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

void _hostInit() {
  testWidgets('a download completes when the host owns WorkManager', (
    WidgetTester tester,
  ) async {
    final File file = _file('host-blob');
    await _enqueue('host-blob', '/blob', file);
    await _awaitStatus('host-blob', TaskStatus.completed);
    expect(await sha256HexOfFile(file.path), _sha);
  });
}

void _quota() {
  testWidgets('a dataSync timeout yields and the download still finishes', (
    WidgetTester tester,
  ) async {
    final File file = _file('quota-transfer');
    final List<String> seen = <String>[];
    final StreamSubscription<TaskSnapshot> statuses = WorkVault.instance
        .watchStatus(taskId: 'quota-transfer')
        .listen((TaskSnapshot snapshot) => seen.add(snapshot.status.name));
    try {
      await _enqueue(
        'quota-transfer',
        '/slow?chunk=2048&gapMs=500',
        file,
        attempts: 5,
      );
      await _awaitBytes(file);
      await _marker('quota_seeded').writeAsString('seeded', flush: true);
      await _awaitStatus(
        'quota-transfer',
        TaskStatus.completed,
        timeout: const Duration(minutes: 10),
      );
    } finally {
      await statuses.cancel();
      await _marker('quota_statuses').writeAsString(seen.join(','), flush: true);
    }
    expect(file.lengthSync(), _length);
    expect(await sha256HexOfFile(file.path), _sha);
  }, timeout: const Timeout(Duration(minutes: 12)));
}

File _marker(String name) => File('${rehearsalDirectory().path}/$name');

String _field(String line, String key) {
  final Object? decoded = jsonDecode(line);
  final Map<Object?, Object?> map = decoded! as Map<Object?, Object?>;
  final Object? value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Headless log is missing $key.');
  }
  return value;
}

File _file(String taskId) => File('${rehearsalDirectory().path}/$taskId.bin');

Future<TaskSnapshot> _enqueue(
  String taskId,
  String path,
  File file, {
  int attempts = 3,
  bool expectSha = true,
  BatteryConstraint battery = const BatteryConstraint(),
}) {
  return WorkVault.instance.enqueue(
    WorkTaskConfig(
      taskId: taskId,
      url: '$_base$path',
      destinationPath: file.path,
      headers: expectSha
          ? <String, String>{'X-Work-Vault-Sha256': _sha}
          : const <String, String>{},
      retry: RetryPolicy(
        maxAttempts: attempts,
        initialBackoff: const Duration(seconds: 1),
        maxBackoff: const Duration(seconds: 2),
      ),
      battery: battery,
      notification: _notification,
    ),
  );
}

Future<TaskSnapshot> _awaitStatus(
  String taskId,
  TaskStatus target, {
  Duration timeout = _transferTimeout,
}) async {
  final Completer<TaskSnapshot> reached = Completer<TaskSnapshot>();
  final StreamSubscription<TaskSnapshot> subscription = WorkVault.instance
      .watchStatus(taskId: taskId)
      .listen((TaskSnapshot snapshot) {
        if (reached.isCompleted) {
          return;
        }
        if (snapshot.status == target) {
          reached.complete(snapshot);
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
    return await reached.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Task "$taskId" did not reach ${target.name}',
        timeout,
      ),
    );
  } finally {
    await subscription.cancel();
  }
}

Future<void> _awaitBytes(File file) async {
  final DateTime deadline = DateTime.now().add(_transferTimeout);
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync() && file.lengthSync() > 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('${file.path} did not receive bytes');
}
