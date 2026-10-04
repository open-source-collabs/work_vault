import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'fixture_server.dart';

const String _package = 'com.workvault.work_vault_example';

const List<String> _allScenarios = <String>[
  'controls',
  'survive',
  'headless',
  'reboot',
  'battery',
  'host-manual',
  'host-provider',
  'quota',
];

/// Runs the Android production rehearsal against a local HTTPS fixture.
///
/// `dart run tool/production_rehearsal.dart [--device=<serial>] [--port=<n>] [scenario...]`
/// runs every scenario in [_allScenarios] when none are named. `quota` needs
/// Android 15 (API 35) and is reported as skipped on older devices.
Future<void> main(List<String> arguments) async {
  final String? requestedDevice = arguments
      .where((String argument) => argument.startsWith('--device='))
      .map((String argument) => argument.substring('--device='.length))
      .firstOrNull;
  final int port = int.parse(
    arguments
            .where((String argument) => argument.startsWith('--port='))
            .map((String argument) => argument.substring('--port='.length))
            .firstOrNull ??
        '8443',
  );
  final List<String> scenarios = arguments
      .where((String argument) => !argument.startsWith('--'))
      .toList();
  for (final String scenario in scenarios) {
    if (!_allScenarios.contains(scenario)) {
      throw ArgumentError('Unknown scenario "$scenario". Use $_allScenarios.');
    }
  }
  final Directory example = _exampleDirectory();
  final FixtureServer server = await FixtureServer.bind(
    port: port,
    certificatePath: '${example.path}${Platform.pathSeparator}tool${Platform.pathSeparator}certs${Platform.pathSeparator}cert.pem',
    keyPath: '${example.path}${Platform.pathSeparator}tool${Platform.pathSeparator}certs${Platform.pathSeparator}key.pem',
  );
  final String adb = _adb();
  final String device = requestedDevice ?? await _emulator(adb);
  await _reverse(adb, device, server.port);
  final String base = 'https://127.0.0.1:${server.port}';
  final int sdk = int.parse(
    await _run(adb, <String>['-s', device, 'shell', 'getprop', 'ro.build.version.sdk']),
  );
  stdout.writeln(
    'Fixture $base sha=${server.sha256} device=$device api=$sdk',
  );
  final _Rehearsal rehearsal = _Rehearsal(example, adb, device, base, server, sdk);
  final List<_Result> results = <_Result>[];
  // initialize() asks for POST_NOTIFICATIONS on API 33+. Granting it as soon as
  // each install lands keeps the system dialog from stalling a phase.
  final Timer grant = Timer.periodic(const Duration(seconds: 20), (Timer _) {
    unawaited(() async {
      try {
        await Process.run(adb, <String>[
          '-s',
          device,
          'reverse',
          'tcp:${server.port}',
          'tcp:${server.port}',
        ]);
      } on Object {
        // adb can fail to spawn when the machine is out of commit charge.
      }
    }());
    if (sdk >= 33) {
      unawaited(() async {
        try {
          await Process.run(adb, <String>[
            '-s',
            device,
            'shell',
            'pm',
            'grant',
            _package,
            'android.permission.POST_NOTIFICATIONS',
          ]);
        } on Object {
          // adb can fail to spawn when the machine is out of commit charge.
        }
      }());
    }
  });
  try {
    await _checkFixture(server);
    await _clearAppData(adb, device);
    for (final String scenario in scenarios.isEmpty ? _allScenarios : scenarios) {
      results.add(await rehearsal.run(scenario));
    }
  } finally {
    grant.cancel();
    try {
      await _run(adb, <String>[
        '-s',
        device,
        'reverse',
        '--remove',
        'tcp:${server.port}',
      ]);
    } on Object {
      // The tunnel is already gone when adb dropped the device.
    }
    await server.close();
  }
  final String summary = <String>[
    'Rehearsal ${DateTime.now().toUtc().toIso8601String()} device=$device api=$sdk',
    for (final _Result result in results)
      '${result.outcome.padRight(7)} ${result.scenario.padRight(14)} ${result.detail}',
  ].join('\n');
  stdout.writeln('\n$summary');
  final File log = File(
    '${example.path}${Platform.pathSeparator}build${Platform.pathSeparator}rehearsal_results.txt',
  );
  await log.parent.create(recursive: true);
  await log.writeAsString('$summary\n\n', mode: FileMode.append);
  if (results.any((_Result result) => result.outcome == 'FAIL')) {
    exitCode = 1;
    return;
  }
  stdout.writeln('Production rehearsal passed.');
}

class _Result {
  const _Result(this.scenario, this.outcome, this.detail);

  final String scenario;
  final String outcome;
  final String detail;
}

class _Rehearsal {
  _Rehearsal(this.example, this.adb, this.device, this.base, this.server, this.sdk);

  final Directory example;
  final String adb;
  final String device;
  final String base;
  final FixtureServer server;
  final int sdk;

  Future<_Result> run(String scenario) async {
    stdout.writeln('\n=== $scenario ===');
    try {
      final String detail = switch (scenario) {
        'controls' => await _controls(),
        'survive' => await _surviveScenario(),
        'headless' => await _headlessScenario(),
        'reboot' => await _reboot(),
        'battery' => await _battery(),
        'host-manual' => await _hostInit('manual'),
        'host-provider' => await _hostInit('provider'),
        'quota' => await _quota(),
        _ => throw ArgumentError(scenario),
      };
      return _Result(scenario, detail.startsWith('skipped') ? 'SKIP' : 'PASS', detail);
    } on Object catch (error) {
      stderr.writeln('$scenario failed: $error');
      return _Result(scenario, 'FAIL', '$error'.split('\n').first);
    }
  }

  Future<String> _controls() async {
    await _runPhase(example: example, device: device, phase: 'controls', base: base, server: server);
    return 'enqueue, pause/resume, cancel, duplicate, 404, drop, truncated';
  }

  Future<String> _surviveScenario() async {
    await _survive(example, adb, device, base, server);
    return 'force-stop mid-download; relaunch resumed and hash matched';
  }

  Future<String> _headlessScenario() async {
    await _headless(example, adb, device, base, server);
    return 'process killed; headless engine finished and shut down once';
  }

  Future<String> _reboot() async {
    final _RunningTest seed = await _startPhase(
      example: example,
      device: device,
      phase: 'reboot-seed',
      base: base,
      server: server,
      allowFailure: true,
    );
    try {
      await _pollFile(adb, device, 'files/rehearsal/reboot_seeded');
      final String before = _jsonField(
        await _readFile(adb, device, 'files/work_vault/tasks/reboot-transfer.json'),
        'status',
      );
      stdout.writeln('Reboot record before reboot: status=$before');
      await _run(adb, <String>['-s', device, 'reboot']);
    } finally {
      seed.stop();
    }
    await seed.done.timeout(const Duration(minutes: 2), onTimeout: () => -1);
    await _run(adb, <String>['-s', device, 'wait-for-device']);
    await _retry(() => _reverse(adb, device, server.port), const Duration(minutes: 2));
    await _retry(() async {
      final String booted = await _run(adb, <String>['-s', device, 'shell', 'getprop', 'sys.boot_completed']);
      if (booted != '1') {
        throw StateError('boot not complete');
      }
    }, const Duration(minutes: 5));
    stdout.writeln('Device booted; waiting without launching the app.');
    final String status = await _awaitRecordStatus(
      'reboot-transfer',
      const <String>{'completed'},
      const Duration(minutes: 6),
    );
    final String launched = await _shell(<String>['dumpsys', 'activity', 'activities']);
    final bool uiStarted = launched.contains('$_package/.MainActivity');
    if (uiStarted) {
      throw StateError('MainActivity started before the check; the boot path is not isolated.');
    }
    await _runPhase(example: example, device: device, phase: 'reboot-check', base: base, server: server);
    return 'rebooted mid-download; finished as $status before any UI launch';
  }

  Future<String> _battery() async {
    try {
      await _lowBattery();
      final _RunningTest hold = await _startPhase(
        example: example,
        device: device,
        phase: 'battery-hold',
        base: base,
        server: server,
      );
      await _pollFile(adb, device, 'files/rehearsal/battery_held');
      await _shell(<String>['dumpsys', 'battery', 'reset']);
      await hold.done;

      final _RunningTest drop = await _startPhase(
        example: example,
        device: device,
        phase: 'battery-drop',
        base: base,
        server: server,
      );
      await _pollFile(adb, device, 'files/rehearsal/battery_running');
      await _lowBattery();
      await _pollFile(adb, device, 'files/rehearsal/battery_stopped');
      final String kept = await _readFile(adb, device, 'files/rehearsal/battery_stopped');
      await _shell(<String>['dumpsys', 'battery', 'reset']);
      await drop.done;
      return 'held at 5% before start; stopped mid-download with $kept bytes kept; both finished after reset';
    } finally {
      await _shell(<String>['dumpsys', 'battery', 'reset']);
    }
  }

  Future<void> _lowBattery() async {
    await _shell(<String>['dumpsys', 'battery', 'unplug']);
    await _shell(<String>['dumpsys', 'battery', 'set', 'level', '5']);
  }

  Future<String> _hostInit(String mode) async {
    await _clearAppData(adb, device);
    await _run(adb, <String>['-s', device, 'logcat', '-c']);
    await _run(adb, <String>['-s', device, 'logcat', '-b', 'crash', '-c']);
    Object? failure;
    try {
      await _runPhase(
        example: example,
        device: device,
        phase: 'host-init',
        base: base,
        server: server,
        environment: <String, String>{'WORK_VAULT_HOST_INIT': mode},
      );
    } on Object catch (error) {
      failure = error;
    }
    final String crashes = await _run(adb, <String>['-s', device, 'logcat', '-b', 'crash', '-d']);
    final String host = await _run(adb, <String>['-s', device, 'logcat', '-d', '-s', 'WorkVaultHost:I']);
    final String crash = crashes
        .split('\n')
        .where((String line) => line.contains('Exception') || line.contains('FATAL'))
        .take(3)
        .join(' | ');
    if (failure != null || crash.isNotEmpty) {
      throw StateError('host=$mode crashed or failed: ${crash.isEmpty ? failure : crash}');
    }
    if (!host.contains('Host factory asked for com.workvault.work_vault.WorkVaultWorker')) {
      throw StateError('host=$mode: the host WorkerFactory never saw the plugin worker.\n$host');
    }
    return 'host $mode WorkManager config stayed active; plugin worker built by fallback';
  }

  Future<String> _quota() async {
    if (sdk < 35) {
      return 'skipped: dataSync timeout needs API 35, device is API $sdk';
    }
    await _shell(<String>['cmd', 'device_config', 'set_sync_disabled_for_tests', 'persistent']);
    await _shell(<String>[
      'cmd',
      'device_config',
      'put',
      'activity_manager',
      'data_sync_fgs_timeout_duration',
      '30000',
    ]);
    try {
      await _run(adb, <String>['-s', device, 'logcat', '-c']);
      final _RunningTest test = await _startPhase(
        example: example,
        device: device,
        phase: 'quota',
        base: base,
        server: server,
      );
      await _pollFile(adb, device, 'files/rehearsal/quota_seeded');
      await _shell(<String>['input', 'keyevent', 'KEYCODE_HOME']);
      await test.done;
      final String statuses = await _readFile(adb, device, 'files/rehearsal/quota_statuses');
      final String log = await _run(adb, <String>['-s', device, 'logcat', '-d']);
      final List<String> evidence = log
          .split('\n')
          .where((String line) =>
              line.contains('dataSync time limit reached') ||
              line.contains('dataSync foreground unavailable') ||
              line.contains('ForegroundServiceStartNotAllowed') ||
              (line.contains('WM-') && line.toLowerCase().contains('timeout')))
          .map((String line) => line.trim())
          .toList();
      stdout.writeln('Quota evidence:\n${evidence.join('\n')}');
      if (!log.contains('dataSync time limit reached')) {
        throw StateError('Download finished but the dataSync timeout never fired. statuses=$statuses');
      }
      return 'onTimeout fired at 30 s; statuses $statuses; hash matched';
    } finally {
      await _shell(<String>['cmd', 'device_config', 'delete', 'activity_manager', 'data_sync_fgs_timeout_duration']);
      await _shell(<String>['cmd', 'device_config', 'set_sync_disabled_for_tests', 'none']);
    }
  }

  Future<String> _awaitRecordStatus(String taskId, Set<String> targets, Duration limit) async {
    final DateTime deadline = DateTime.now().add(limit);
    String? last;
    while (DateTime.now().isBefore(deadline)) {
      try {
        last = _jsonField(
          await _readFile(adb, device, 'files/work_vault/tasks/$taskId.json'),
          'status',
        );
        if (targets.contains(last)) {
          return last;
        }
        if (last == 'failed' || last == 'cancelled') {
          throw StateError('$taskId finished as $last');
        }
      } on StateError catch (error) {
        if (error.message.startsWith(taskId)) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw TimeoutException('$taskId stayed at $last', limit);
  }

  Future<String> _shell(List<String> command) {
    return _run(adb, <String>['-s', device, 'shell', ...command]);
  }
}

Future<void> _reverse(String adb, String device, int port) async {
  // This guest has no route to 10.0.2.2. Reverse the fixture port so the
  // device reaches the host at 127.0.0.1, which is on the fixture certificate.
  await _run(adb, <String>['-s', device, 'reverse', 'tcp:$port', 'tcp:$port']);
}

Future<void> _retry(Future<void> Function() action, Duration limit) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (true) {
    try {
      await action();
      return;
    } on Object {
      if (DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

Future<void> _clearAppData(String adb, String device) async {
  final ProcessResult result = await Process.run(adb, <String>[
    '-s',
    device,
    'shell',
    'pm',
    'clear',
    _package,
  ]);
  if (result.exitCode != 0) {
    stdout.writeln('pm clear skipped: ${result.stdout}${result.stderr}');
  } else {
    stdout.writeln('pm clear: ${'${result.stdout}${result.stderr}'.trim()}');
  }
}

Future<void> _checkFixture(FixtureServer server) async {
  final HttpClient client = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) =>
        host == '127.0.0.1' || host == '10.0.2.2';
  final HttpClientRequest request = await client.getUrl(
    Uri.parse('https://127.0.0.1:${server.port}/blob'),
  );
  final HttpClientResponse response = await request.close();
  final List<int> bytes = await response.fold<List<int>>(
    <int>[],
    (List<int> previous, List<int> chunk) => previous..addAll(chunk),
  );
  client.close();
  if (response.statusCode != 200 || bytes.length != server.payload.length) {
    throw StateError(
      'Fixture /blob returned ${response.statusCode} and ${bytes.length} bytes.',
    );
  }
}

Future<void> _survive(
  Directory example,
  String adb,
  String device,
  String base,
  FixtureServer server,
) async {
  stdout.writeln('Survive: seed, kill, relaunch.');
  await _removeMarker(adb, device, 'files/rehearsal/survive_seeded');
  final _RunningTest seed = await _startPhase(
    example: example,
    device: device,
    phase: 'survive-seed',
    base: base,
    server: server,
    allowFailure: true,
  );
  try {
    await _pollFile(adb, device, 'files/rehearsal/survive_seeded');
    stdout.writeln(
      'Before force-stop:\n${await _dumpTask(adb, device, 'survive-transfer')}',
    );
    await _run(adb, <String>[
      '-s',
      device,
      'shell',
      'am',
      'force-stop',
      _package,
    ]);
    final String record = await _dumpTask(adb, device, 'survive-transfer');
    final String status = _jsonField(record, 'status');
    stdout.writeln('Survive record after force-stop: status=$status');
    if (status != 'enqueued' && status != 'running') {
      throw StateError(
        'Killed task came back as "$status", expected enqueued or running.',
      );
    }
  } finally {
    seed.stop();
  }
  final int seedCode = await seed.done.timeout(const Duration(minutes: 2));
  stdout.writeln('Survive seed exited $seedCode after force-stop.');
  server.releaseSurvive();
  await _run(adb, <String>[
    '-s',
    device,
    'shell',
    'am',
    'start',
    '-n',
    '$_package/.MainActivity',
  ]);
  await _awaitSurviveComplete(adb, device, server);
}

Future<void> _headless(
  Directory example,
  String adb,
  String device,
  String base,
  FixtureServer server,
) async {
  stdout.writeln('Headless: detach the UI engine.');
  final _RunningTest seed = await _startPhase(
    example: example,
    device: device,
    phase: 'headless-seed',
    base: base,
    server: server,
    allowFailure: true,
  );
  try {
    var seeded = false;
    await Future.any<void>(<Future<void>>[
      _pollFile(adb, device, 'files/rehearsal/headless_seeded').then((_) {
        seeded = true;
      }),
      seed.done.then((int code) {
        if (!seeded) {
          throw StateError(
            'headless-seed exited $code before the marker was written.',
          );
        }
      }),
    ]);
    await _run(adb, <String>['-s', device, 'logcat', '-c']);
    // Stop the test runner first. Its shutdown force-stops the package, and
    // WorkManager will not resume a force-stopped app until the next launch.
    seed.stop();
    await _killProcess(adb, device);
  } finally {
    seed.stop();
  }
  final int seedCode = await seed.done.timeout(const Duration(minutes: 2));
  stdout.writeln(
    'Headless seed exited $seedCode after the process was killed.',
  );
  await _pollFile(adb, device, 'files/rehearsal/headless.jsonl');
  await _waitForCompleted(adb, device);
  await Future<void>.delayed(const Duration(seconds: 3));
  final String log = await _run(adb, <String>[
    '-s',
    device,
    'logcat',
    '-d',
    '-s',
    'WorkVault:I',
  ]);
  final int shutdowns = 'Headless engine shut down'.allMatches(log).length;
  if (shutdowns != 1) {
    throw StateError('Expected one headless shutdown, found $shutdowns.\n$log');
  }
  await _runPhase(
    example: example,
    device: device,
    phase: 'headless-check',
    base: base,
    server: server,
  );
}

Future<void> _removeMarker(String adb, String device, String path) async {
  final ProcessResult result = await Process.run(adb, <String>[
    '-s',
    device,
    'shell',
    'run-as',
    _package,
    'rm',
    '-f',
    path,
  ]);
  if (result.exitCode != 0) {
    stdout.writeln('Marker remove skipped for $path: ${result.stdout}${result.stderr}');
  }
}

Future<String> _dumpTask(String adb, String device, String taskId) async {
  final ProcessResult result = await Process.run(adb, <String>[
    '-s',
    device,
    'exec-out',
    'run-as',
    _package,
    'cat',
    'files/work_vault/tasks/$taskId.json',
  ]);
  final String output = '${result.stdout}';
  if (result.exitCode != 0 || output.contains('No such file')) {
    final String listing = await _run(adb, <String>[
      '-s',
      device,
      'shell',
      'run-as',
      _package,
      'ls',
      'files/work_vault/tasks',
    ]);
    throw StateError(
      'Task $taskId is not on disk (exit ${result.exitCode}).\n$output\n$listing',
    );
  }
  return output.trim();
}

Future<void> _awaitSurviveComplete(
  String adb,
  String device,
  FixtureServer server,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 3));
  String? lastStatus;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final String record = await _readFile(
        adb,
        device,
        'files/work_vault/tasks/survive-transfer.json',
      );
      lastStatus = _jsonField(record, 'status');
      if (lastStatus == 'completed') {
        final List<int> bytes = await _readBytes(
          adb,
          device,
          'files/rehearsal/survive-transfer.bin',
        );
        if (bytes.length != server.payload.length) {
          throw StateError(
            'Finished survive file is ${bytes.length} bytes, expected ${server.payload.length}.',
          );
        }
        final String digest = sha256.convert(bytes).toString();
        if (digest != server.sha256) {
          throw StateError(
            'Finished survive file hash $digest does not match ${server.sha256}.',
          );
        }
        stdout.writeln('Survive download finished after relaunch.');
        return;
      }
      if (lastStatus == 'failed' || lastStatus == 'cancelled') {
        throw StateError('Killed task finished as $lastStatus.\n$record');
      }
    } on Object catch (error) {
      lastStatus = '$error';
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TimeoutException(
    'Killed task did not finish after relaunch ($lastStatus).',
  );
}

String _jsonField(String json, String key) {
  final Object? decoded = jsonDecode(json);
  final Map<Object?, Object?> map = decoded! as Map<Object?, Object?>;
  final Object? value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Task record is missing $key.');
  }
  return value;
}

Future<List<int>> _readBytes(String adb, String device, String path) async {
  final ProcessResult result = await Process.run(
    adb,
    <String>[
      '-s',
      device,
      'exec-out',
      'run-as',
      _package,
      'cat',
      path,
    ],
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) {
    throw StateError('Could not read $path: ${result.stderr}');
  }
  final Object stdoutBytes = result.stdout;
  if (stdoutBytes is! List<int>) {
    throw StateError('adb exec-out did not return bytes for $path.');
  }
  return stdoutBytes;
}

Future<void> _waitForCompleted(String adb, String device) async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    final String body = await _readFile(
      adb,
      device,
      'files/rehearsal/headless.jsonl',
    );
    if (body.contains('"status":"completed"')) {
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TimeoutException('The headless handler did not record completion.');
}

Future<void> _runPhase({
  required Directory example,
  required String device,
  required String phase,
  required String base,
  required FixtureServer server,
  Map<String, String> environment = const <String, String>{},
}) async {
  final _RunningTest test = await _startPhase(
    example: example,
    device: device,
    phase: phase,
    base: base,
    server: server,
    environment: environment,
  );
  final int code = await test.done;
  if (code != 0) {
    throw StateError('flutter test phase=$phase exited $code.');
  }
}

Future<_RunningTest> _startPhase({
  required Directory example,
  required String device,
  required String phase,
  required String base,
  required FixtureServer server,
  bool allowFailure = false,
  Map<String, String> environment = const <String, String>{},
}) async {
  final String flutter = _flutterBat();
  stdout.writeln('flutter test phase=$phase');
  final Process process = await Process.start(
    flutter,
    <String>[
      'test',
      'integration_test/plugin_integration_test.dart',
      '-d',
      device,
      '--reporter',
      'expanded',
      '--no-uninstall',
      '--dart-define=WORK_VAULT_PHASE=$phase',
      '--dart-define=WORK_VAULT_FIXTURE_BASE=$base',
      '--dart-define=WORK_VAULT_FIXTURE_SHA256=${server.sha256}',
      '--dart-define=WORK_VAULT_FIXTURE_LENGTH=${server.payload.length}',
    ],
    workingDirectory: example.path,
    environment: <String, String>{
      ...Platform.environment,
      'GRADLE_USER_HOME':
          '${Platform.environment['USERPROFILE'] ?? ''}${Platform.pathSeparator}.gradle',
      'WORK_VAULT_HOST_INIT': '',
      ...environment,
    },
    runInShell: true,
  );
  bool released = false;
  final Future<int> done = () async {
    final Future<void> pipes = Future.wait<void>(<Future<void>>[
      process.stdout.transform(utf8.decoder).forEach((String chunk) {
        stdout.write(chunk);
        if (!released && chunk.contains('Installing build')) {
          released = true;
          unawaited(_releaseBuildDaemons());
        }
      }),
      process.stderr.transform(utf8.decoder).forEach(stderr.write),
    ]);
    final int code = await process.exitCode;
    await pipes;
    if (!allowFailure && code != 0) {
      throw StateError('flutter test phase=$phase exited $code.');
    }
    return code;
  }();
  return _RunningTest(process, done);
}

/// Stops idle Gradle and Kotlin daemons once an APK is built. Their 8 GB heaps
/// otherwise hold the commit charge a second emulator needs during the test.
Future<void> _releaseBuildDaemons() async {
  if (!Platform.isWindows) {
    return;
  }
  try {
    await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      r"$java = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'java.exe' }; "
          r"if ($java | Where-Object { $_.CommandLine -match 'GradleWrapperMain' }) { return }; "
          r"$java | Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon' } | "
          r"ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
    ]);
  } on Object {
    // Releasing memory is best-effort.
  }
}

class _RunningTest {
  _RunningTest(this._process, this.done);

  final Process _process;

  final Future<int> done;

  void stop() {
    if (Platform.isWindows) {
      Process.runSync('taskkill', <String>[
        '/F',
        '/T',
        '/PID',
        '${_process.pid}',
      ]);
      return;
    }
    _process.kill();
  }
}

Future<void> _pollFile(String adb, String device, String path) async {
  final DateTime deadline = DateTime.now().add(const Duration(minutes: 8));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      final String body = await _readFile(adb, device, path);
      if (body.trim().isNotEmpty) {
        stdout.writeln('Saw $path');
        return;
      }
    } on Object catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw TimeoutException('Timed out waiting for $path ($lastError).');
}

Future<String> _readFile(String adb, String device, String path) async {
  final String output = await _run(adb, <String>[
    '-s',
    device,
    'exec-out',
    'run-as',
    _package,
    'cat',
    path,
  ]);
  if (output.contains('No such file') || output.contains('Permission denied')) {
    throw StateError('Missing $path: $output');
  }
  return output;
}

Future<void> _killProcess(String adb, String device) async {
  await _run(adb, <String>[
    '-s',
    device,
    'shell',
    'input',
    'keyevent',
    'KEYCODE_HOME',
  ]);
  await Future<void>.delayed(const Duration(seconds: 1));
  final String listed = await _run(adb, <String>[
    '-s',
    device,
    'shell',
    'pidof',
    _package,
  ]);
  final List<String> pids = listed
      .split(RegExp(r'\s+'))
      .where((String pid) => pid.isNotEmpty)
      .toList();
  if (pids.isEmpty) {
    throw StateError('No process for $_package.');
  }
  for (final String pid in pids) {
    // The shell user cannot signal the app. run-as can, and unlike force-stop
    // it leaves WorkManager free to start the process again.
    final ProcessResult result = await Process.run(adb, <String>[
      '-s',
      device,
      'shell',
      'run-as',
      _package,
      '/system/bin/kill',
      '-9',
      pid,
    ]);
    if (result.exitCode != 0) {
      final String output = '${result.stdout}${result.stderr}';
      if (!output.contains('No such process')) {
        throw StateError('Could not kill $pid: $output');
      }
    }
  }
}

Future<String> _emulator(String adb) async {
  final String listed = await _run(adb, <String>['devices']);
  final List<String> ids = <String>[
    for (final String line in listed.split('\n'))
      if (line.startsWith('emulator-') && line.contains('device'))
        line.split(RegExp(r'\s+')).first,
  ];
  if (ids.isEmpty) {
    throw StateError('Start an Android emulator, then run this script again.');
  }
  return ids.first;
}

Future<String> _run(String executable, List<String> args) async {
  final ProcessResult result = await Process.run(executable, args);
  final String output = '${result.stdout}${result.stderr}';
  if (result.exitCode != 0) {
    throw StateError('$executable ${args.join(' ')} failed: $output');
  }
  return output.trim();
}

Directory _exampleDirectory() {
  final Directory tool = File(Platform.script.toFilePath()).parent;
  return tool.parent;
}

String _flutterBat() {
  final String root =
      Platform.environment['FLUTTER_ROOT'] ??
      r'D:\flutter_windows_3.47.1-stable\flutter';
  return '$root${Platform.pathSeparator}bin${Platform.pathSeparator}flutter.bat';
}

String _adb() {
  final String sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk';
  return '$sdk\\platform-tools\\adb.exe';
}
