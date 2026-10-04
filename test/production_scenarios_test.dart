import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/engine/work_vault_engine.dart';
import 'package:work_vault/src/isolate/background_event_processor.dart';
import 'package:work_vault/work_vault.dart';

import 'support.dart';

/// Production scenarios for scheduling, resume state, and completed-file checks.
///
/// Android 8.0 (API 26) through the current SDK is the supported device range.
/// These cases exercise the Dart control plane and the on-disk integrity path
/// that both isolates share.
void main() {
  group('download config', () {
    for (final _ConfigCase item in _acceptedConfigs) {
      test('accepts ${item.name}', () {
        expect(item.build().validate, returnsNormally);
      });
    }

    for (final _ConfigCase item in _rejectedConfigs) {
      test('rejects ${item.name}', () {
        expect(item.build().validate, throwsA(isA<InvalidWorkConfig>()));
      });
    }
  });

  group('task commands', () {
    for (final _TransitionCase item in _transitions) {
      test('${item.from.name} ${item.command.name}', () {
        expect(
          nextTaskStatus(item.from, item.command),
          item.next,
          reason: '${item.from.name} + ${item.command.name}',
        );
      });
    }

    test('every status reports the terminal flag used by the cache', () {
      expect(taskStatusIsTerminal(TaskStatus.enqueued), isFalse);
      expect(taskStatusIsTerminal(TaskStatus.running), isFalse);
      expect(taskStatusIsTerminal(TaskStatus.paused), isFalse);
      expect(taskStatusIsTerminal(TaskStatus.completed), isTrue);
      expect(taskStatusIsTerminal(TaskStatus.failed), isTrue);
      expect(taskStatusIsTerminal(TaskStatus.cancelled), isTrue);
    });
  });

  group('vault session', () {
    late _ScriptedEngine engine;
    late WorkVault vault;

    setUp(() {
      engine = _ScriptedEngine();
      vault = WorkVault.forTest(engine);
    });

    test('enqueue before initialize is rejected', () async {
      await expectLater(
        vault.enqueue(sampleConfig()),
        throwsA(isA<WorkVaultNotInitialized>()),
      );
      expect(engine.enqueued, isEmpty);
    });

    test('pause before initialize is rejected', () async {
      await expectLater(
        vault.pause('job-1'),
        throwsA(isA<WorkVaultNotInitialized>()),
      );
    });

    test('resume before initialize is rejected', () async {
      await expectLater(
        vault.resume('job-1'),
        throwsA(isA<WorkVaultNotInitialized>()),
      );
    });

    test('cancel before initialize is rejected', () async {
      await expectLater(
        vault.cancel('job-1'),
        throwsA(isA<WorkVaultNotInitialized>()),
      );
    });

    test('getTask before initialize is rejected', () async {
      await expectLater(
        vault.getTask('job-1'),
        throwsA(isA<WorkVaultNotInitialized>()),
      );
    });

    test('getTasks before initialize is rejected', () async {
      await expectLater(vault.getTasks(), throwsA(isA<WorkVaultNotInitialized>()));
    });

    test('a failed initialize can be retried', () async {
      engine.initializeError = StateError('storage unavailable');
      await expectLater(vault.initialize(), throwsA(isA<StateError>()));
      expect(vault.isInitialized, isFalse);

      engine.initializeError = null;
      engine.rows['job-1'] = sampleSnapshot();
      await vault.initialize();
      expect(vault.isInitialized, isTrue);
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.enqueued);
    });

    test('dispose during initialize drops the in-flight session', () async {
      engine.blockInitialize = true;
      final Future<void> starting = vault.initialize();
      await vault.dispose();
      engine.releaseInitialize();
      await starting;
      expect(vault.isInitialized, isFalse);
      expect(vault.observationFor('job-1'), isNull);
    });

    test('host events that arrive during initialize are applied in order', () async {
      engine.rows['job-1'] = sampleSnapshot();
      engine.duringInitialize = () {
        engine.observer?.onStatusChanged(
          sampleSnapshot(status: TaskStatus.running),
        );
        engine.observer?.onProgress(_progress(bytes: 25, total: 100));
      };

      await vault.initialize();

      final TaskObservation? observation = vault.observationFor('job-1');
      expect(observation?.snapshot.status, TaskStatus.running);
      expect(observation?.progress?.bytesDownloaded, 25);
      expect(observation?.progress?.fraction, 0.25);
    });

    test('a second initialize does not reload the host', () async {
      await vault.initialize();
      final int loads = engine.calls.where((String call) => call == 'getTasks').length;
      await vault.initialize();
      expect(
        engine.calls.where((String call) => call == 'getTasks'),
        hasLength(loads),
      );
    });

    test('enqueue publishes the host snapshot and rejects a duplicate id', () async {
      await vault.initialize();
      final TaskSnapshot snapshot = await vault.enqueue(sampleConfig());
      expect(snapshot.status, TaskStatus.enqueued);
      expect(vault.observationFor('job-1')?.snapshot, snapshot);

      await expectLater(
        vault.enqueue(sampleConfig()),
        throwsA(
          isA<DuplicateTask>().having(
            (DuplicateTask error) => error.taskId,
            'taskId',
            'job-1',
          ),
        ),
      );
      expect(engine.enqueued, hasLength(1));
    });

    test('an http url never reaches the host', () async {
      await vault.initialize();
      await expectLater(
        vault.enqueue(sampleConfig(url: 'http://cdn.example.com/file.bin')),
        throwsA(isA<InvalidWorkConfig>()),
      );
      expect(engine.enqueued, isEmpty);
    });

    test('a mismatched host task id is a platform fault and is not cached', () async {
      await vault.initialize();
      engine.enqueueTaskId = 'other-job';
      await expectLater(vault.enqueue(sampleConfig()), throwsA(isA<PlatformFault>()));
      expect(vault.observationFor('job-1'), isNull);
      expect(vault.observationFor('other-job'), isNull);
    });

    test('pause from enqueued is illegal and does not call the host', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      await expectLater(vault.pause('job-1'), throwsA(isA<IllegalTaskTransition>()));
      expect(engine.calls, isNot(contains('pause:job-1')));
    });

    test('resume from running is illegal', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      engine.observer?.onStatusChanged(sampleSnapshot(status: TaskStatus.running));
      await pumpEventQueue();
      await expectLater(vault.resume('job-1'), throwsA(isA<IllegalTaskTransition>()));
      expect(engine.calls, isNot(contains('resume:job-1')));
    });

    test('cancel from completed is illegal', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.completed);
      await vault.initialize();
      await expectLater(vault.cancel('job-1'), throwsA(isA<IllegalTaskTransition>()));
      expect(engine.calls, isNot(contains('cancel:job-1')));
    });

    test('pause, resume, and cancel follow the running task', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      engine.observer?.onStatusChanged(sampleSnapshot(status: TaskStatus.running));
      await pumpEventQueue();

      await vault.pause('job-1');
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.paused);
      await vault.resume('job-1');
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.running);
      await vault.cancel('job-1');
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.cancelled);
      expect(engine.calls, containsAll(<String>['pause:job-1', 'resume:job-1', 'cancel:job-1']));
    });

    test('pause clears a failure that was attached to the running row', () async {
      await vault.initialize();
      engine.rows['job-1'] = sampleSnapshot(
        status: TaskStatus.running,
        failure: const TaskFailure(
          taskId: 'job-1',
          code: 'http',
          message: 'Transfer failed with HTTP 503.',
          httpStatus: 503,
          retryable: true,
        ),
      );
      await vault.getTask('job-1');
      await vault.pause('job-1');
      expect(vault.observationFor('job-1')?.snapshot.failure, isNull);
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.paused);
    });

    test('a missing task cannot be cancelled', () async {
      await vault.initialize();
      await expectLater(
        vault.cancel('missing'),
        throwsA(isA<TaskNotFound>().having((TaskNotFound error) => error.taskId, 'taskId', 'missing')),
      );
    });

    test('a command loads a task that is on the host but not yet cached', () async {
      await vault.initialize();
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.running);
      await vault.pause('job-1');
      expect(engine.calls, contains('getTask:job-1'));
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.paused);
    });

    test('progress updates the cached fraction without a second status event', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      engine.observer?.onStatusChanged(sampleSnapshot(status: TaskStatus.running));
      await pumpEventQueue();

      final List<int> bytes = <int>[];
      final List<TaskStatus> statuses = <TaskStatus>[];
      vault.watchProgress('job-1').listen((TaskProgress progress) {
        bytes.add(progress.bytesDownloaded);
      });
      vault.watchStatus(taskId: 'job-1').listen((TaskSnapshot snapshot) {
        statuses.add(snapshot.status);
      });
      await pumpEventQueue();

      engine.observer?.onProgress(_progress(bytes: 50, total: 100));
      engine.observer?.onProgress(_progress(bytes: 50, total: 100));
      await pumpEventQueue();

      expect(bytes, <int>[50]);
      expect(statuses, <TaskStatus>[TaskStatus.running]);
      expect(vault.observationFor('job-1')?.progress?.fraction, 0.5);
    });

    test('progress for an unknown task is ignored', () async {
      await vault.initialize();
      engine.observer?.onProgress(_progress(bytes: 10, total: 10, taskId: 'ghost'));
      await pumpEventQueue();
      expect(vault.observationFor('ghost'), isNull);
    });

    test('progress after completion is ignored', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.completed);
      await vault.initialize();
      engine.observer?.onProgress(_progress(bytes: 4, total: 4));
      await pumpEventQueue();
      expect(vault.observationFor('job-1')?.progress, isNull);
    });

    test('a completed task ignores a later running update', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.completed);
      await vault.initialize();
      engine.observer?.onStatusChanged(sampleSnapshot(status: TaskStatus.running));
      await pumpEventQueue();
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.completed);
    });

    test('a completed task ignores a later failed update', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.completed);
      await vault.initialize();
      engine.observer?.onStatusChanged(
        sampleSnapshot(
          status: TaskStatus.failed,
          failure: const TaskFailure(
            taskId: 'job-1',
            code: 'io',
            message: 'stale',
            httpStatus: null,
            retryable: true,
          ),
        ),
      );
      await pumpEventQueue();
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.completed);
      expect(vault.observationFor('job-1')?.snapshot.failure, isNull);
    });

    test('a cancelled task ignores a later enqueued update', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.cancelled);
      await vault.initialize();
      engine.observer?.onStatusChanged(sampleSnapshot());
      await pumpEventQueue();
      expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.cancelled);
    });

    test('getTasks can filter by status and still keeps every row cached', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      await vault.enqueue(sampleConfig(taskId: 'job-2'));
      engine.rows['job-2'] = sampleSnapshot(taskId: 'job-2', status: TaskStatus.running);
      engine.observer?.onStatusChanged(engine.rows['job-2']!);
      await pumpEventQueue();

      final List<TaskSnapshot> running = await vault.getTasks(status: TaskStatus.running);
      expect(running.map((TaskSnapshot task) => task.taskId), <String>['job-2']);
      expect(vault.observationFor('job-1'), isNotNull);
      expect(vault.observationFor('job-2')?.snapshot.status, TaskStatus.running);
    });

    test('getTasks drops rows the host no longer returns', () async {
      engine.rows['job-1'] = sampleSnapshot();
      engine.rows['job-2'] = sampleSnapshot(taskId: 'job-2');
      await vault.initialize();
      engine.rows.remove('job-2');

      final List<TaskSnapshot> tasks = await vault.getTasks();
      expect(tasks.map((TaskSnapshot task) => task.taskId), <String>['job-1']);
      expect(vault.observationFor('job-2'), isNull);
    });

    test('getTask removes a row the host has forgotten', () async {
      engine.rows['job-1'] = sampleSnapshot();
      await vault.initialize();
      engine.rows.remove('job-1');
      expect(await vault.getTask('job-1'), isNull);
      expect(vault.observationFor('job-1'), isNull);
    });

    test('watchStatus replays the cache to a late listener', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.paused);
      await vault.initialize();
      final List<TaskStatus> statuses = <TaskStatus>[];
      vault.watchStatus(taskId: 'job-1').listen((TaskSnapshot snapshot) {
        statuses.add(snapshot.status);
      });
      await pumpEventQueue();
      expect(statuses, <TaskStatus>[TaskStatus.paused]);
    });

    test('watchStatus without an id replays every cached task', () async {
      engine.rows['job-1'] = sampleSnapshot();
      engine.rows['job-2'] = sampleSnapshot(taskId: 'job-2', status: TaskStatus.running);
      await vault.initialize();
      final List<String> ids = <String>[];
      vault.watchStatus().listen((TaskSnapshot snapshot) {
        ids.add(snapshot.taskId);
      });
      await pumpEventQueue();
      expect(ids, containsAll(<String>['job-1', 'job-2']));
    });

    test('watchProgress replays the sample carried by the cached snapshot', () async {
      const TaskProgress sample = TaskProgress(
        taskId: 'job-1',
        bytesDownloaded: 8,
        totalBytes: 16,
        bytesPerSecond: 4,
        elapsed: Duration(seconds: 2),
        percentage: 50,
      );
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.running, progress: sample);
      await vault.initialize();
      final List<int> bytes = <int>[];
      vault.watchProgress('job-1').listen((TaskProgress progress) {
        bytes.add(progress.bytesDownloaded);
      });
      await pumpEventQueue();
      expect(bytes, <int>[8]);
    });

    test('a listener attached before initialize receives the hydrated row', () async {
      engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.paused);
      final List<TaskStatus> statuses = <TaskStatus>[];
      vault.watchStatus(taskId: 'job-1').listen((TaskSnapshot snapshot) {
        statuses.add(snapshot.status);
      });
      await vault.initialize();
      await pumpEventQueue();
      expect(statuses, <TaskStatus>[TaskStatus.paused]);
    });

    test('dispose ends the session and the next initialize starts empty', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      final List<TaskSnapshot> seen = <TaskSnapshot>[];
      final List<bool> closed = <bool>[false];
      vault.watchStatus().listen(
        seen.add,
        onDone: () {
          closed[0] = true;
        },
      );
      await vault.dispose();
      await pumpEventQueue();

      expect(vault.isInitialized, isFalse);
      expect(vault.observationFor('job-1'), isNull);
      expect(closed, <bool>[true]);
      expect(engine.calls, contains('clearObserver'));

      engine.rows.clear();
      await vault.initialize();
      expect(vault.observationFor('job-1'), isNull);
    });

    test('two downloads keep independent progress', () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      await vault.enqueue(sampleConfig(taskId: 'job-2'));
      engine.observer?.onStatusChanged(sampleSnapshot(status: TaskStatus.running));
      engine.observer?.onStatusChanged(
        sampleSnapshot(taskId: 'job-2', status: TaskStatus.running),
      );
      await pumpEventQueue();
      engine.observer?.onProgress(_progress(bytes: 10, total: 100));
      engine.observer?.onProgress(_progress(bytes: 80, total: 100, taskId: 'job-2'));
      await pumpEventQueue();

      expect(vault.observationFor('job-1')?.progress?.bytesDownloaded, 10);
      expect(vault.observationFor('job-2')?.progress?.bytesDownloaded, 80);
    });

    test('unknown total leaves the fraction null', () async {
      const TaskProgress sample = TaskProgress(
        taskId: 'job-1',
        bytesDownloaded: 12,
        totalBytes: null,
        bytesPerSecond: 3,
        elapsed: Duration(seconds: 4),
        percentage: null,
      );
      expect(sample.fraction, isNull);
      expect(sample, equals(sample));
    });

    test('zero and full percentages become fractions 0 and 1', () {
      expect(_progress(bytes: 0, total: 40).fraction, 0);
      expect(_progress(bytes: 40, total: 40).fraction, 1);
    });

    test('equal configs and snapshots compare by value', () {
      expect(sampleConfig(), equals(sampleConfig()));
      expect(sampleConfig().hashCode, sampleConfig().hashCode);
      expect(sampleSnapshot(), equals(sampleSnapshot()));
      expect(
        const RetryPolicy(),
        equals(const RetryPolicy()),
      );
      expect(
        const BatteryConstraint(requiresCharging: true),
        isNot(equals(const BatteryConstraint())),
      );
      expect(
        const NotificationMetadata(
          title: 'Archive',
          body: 'Saving',
          channelId: 'downloads',
          channelName: 'Downloads',
        ),
        equals(
          const NotificationMetadata(
            title: 'Archive',
            body: 'Saving',
            channelId: 'downloads',
            channelName: 'Downloads',
          ),
        ),
      );
    });
  });

  group('completed file integrity', () {
    late Directory directory;
    late WorkVaultDatabase database;
    const BackgroundEventProcessor processor = BackgroundEventProcessor(
      invoke: _ignoreCallback,
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('work-vault-scenarios-');
      database = WorkVaultDatabase.memory();
    });

    tearDown(() async {
      database.close();
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    });

    test('an empty completed file stores the empty SHA-256', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}empty.bin');
      await file.writeAsBytes(<int>[]);
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _completed(file: file, bytes: 0, taskId: 'empty'),
      );
      expect(event.verificationStatus, Sha256VerificationStatus.verified);
      expect(
        event.sha256,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('a one-byte file stores its digest', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}one.bin');
      await file.writeAsBytes(<int>[0x61]);
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _completed(file: file, bytes: 1, taskId: 'one'),
      );
      expect(
        event.sha256,
        'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb',
      );
    });

    test('a resumed file is hashed only after the full body is on disk', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}resume.bin');
      await file.writeAsBytes(<int>[0x61, 0x62]);
      await processor.apply(database, <Object?, Object?>{
        'kind': 'progress',
        'taskId': 'resume',
        'status': 'running',
        'filePath': file.path,
        'downloadedBytes': 2,
        'totalBytes': 3,
        'databasePath': ':memory:',
      });
      expect(database.getTask('resume')?.sha256, isNull);
      expect(
        database.getTask('resume')?.verificationStatus,
        Sha256VerificationStatus.pending,
      );

      await file.writeAsBytes(<int>[0x61, 0x62, 0x63]);
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _completed(file: file, bytes: 3, taskId: 'resume'),
      );
      expect(event.verificationStatus, Sha256VerificationStatus.verified);
      expect(
        event.sha256,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('binary content that includes a zero byte still hashes the whole file', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}binary.bin');
      await file.writeAsBytes(<int>[0x00, 0xff, 0x10]);
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _completed(file: file, bytes: 3, taskId: 'binary'),
      );
      expect(event.verificationStatus, Sha256VerificationStatus.verified);
      expect(event.sha256, hasLength(64));
    });

    test('a changed file after verification is a mismatch and keeps the first digest', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}changed.bin');
      await file.writeAsString('abc');
      final WorkVaultBackgroundEvent first = await processor.apply(
        database,
        _completed(file: file, bytes: 3, taskId: 'changed'),
      );
      await file.writeAsString('abcd');
      final WorkVaultBackgroundEvent second = await processor.apply(
        database,
        _completed(file: file, bytes: 4, taskId: 'changed'),
      );
      expect(second.verificationStatus, Sha256VerificationStatus.mismatch);
      expect(second.sha256, first.sha256);
    });

    test('a missing completed file is recorded as missing', () async {
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        <Object?, Object?>{
          'kind': 'status',
          'taskId': 'gone',
          'status': 'completed',
          'filePath': '${directory.path}${Platform.pathSeparator}missing.bin',
          'downloadedBytes': 0,
          'databasePath': ':memory:',
        },
      );
      expect(event.verificationStatus, Sha256VerificationStatus.missing);
      expect(event.sha256, isNull);
    });

    test('a progress event does not erase a mismatch', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}sticky.bin');
      await file.writeAsString('abc');
      await processor.apply(database, _completed(file: file, bytes: 3, taskId: 'sticky'));
      await file.writeAsString('zzz');
      await processor.apply(database, _completed(file: file, bytes: 3, taskId: 'sticky'));
      await processor.apply(database, <Object?, Object?>{
        'kind': 'progress',
        'taskId': 'sticky',
        'status': 'running',
        'filePath': file.path,
        'downloadedBytes': 1,
        'databasePath': ':memory:',
      });
      expect(
        database.getTask('sticky')?.verificationStatus,
        Sha256VerificationStatus.mismatch,
      );
    });

    test('cancel drops the resume state the host no longer holds', () async {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}partial.bin',
      );
      await file.writeAsString('ab');
      await processor.apply(database, <Object?, Object?>{
        'kind': 'progress',
        'taskId': 'cancel-me',
        'status': 'running',
        'filePath': file.path,
        'downloadedBytes': 2,
        'totalBytes': 4,
        'eTag': '"v1"',
        'databasePath': ':memory:',
      });
      expect(database.getTask('cancel-me')?.eTag, '"v1"');

      await processor.apply(database, <Object?, Object?>{
        'kind': 'status',
        'taskId': 'cancel-me',
        'status': 'cancelled',
        'filePath': file.path,
        'downloadedBytes': 0,
        'databasePath': ':memory:',
      });

      final WorkVaultTaskRecord? row = database.getTask('cancel-me');
      expect(row?.status, 'cancelled');
      expect(row?.resumptionData, isNull);
      expect(row?.eTag, isNull);
      expect(row?.totalBytes, isNull);
      expect(row?.downloadedBytes, 0);
    });

    test('two tasks stay isolated in the same database', () async {
      final File first = File('${directory.path}${Platform.pathSeparator}a.bin');
      final File second = File('${directory.path}${Platform.pathSeparator}b.bin');
      await first.writeAsString('abc');
      await second.writeAsString('abcd');
      await processor.apply(database, _completed(file: first, bytes: 3, taskId: 'a'));
      await processor.apply(database, _completed(file: second, bytes: 4, taskId: 'b'));
      expect(database.getTasks(), hasLength(2));
      expect(database.getTask('a')?.sha256, isNot(database.getTask('b')?.sha256));
    });

    test('a null etag on update keeps the stored tag', () {
      database.upsert(
        const WorkVaultTaskRecord(
          taskId: 'tagged',
          status: 'running',
          filePath: '/tmp/tagged.bin',
          downloadedBytes: 1,
          eTag: '"keep"',
          verificationStatus: Sha256VerificationStatus.pending,
        ),
      );
      database.upsert(
        const WorkVaultTaskRecord(
          taskId: 'tagged',
          status: 'running',
          filePath: '/tmp/tagged.bin',
          downloadedBytes: 2,
          verificationStatus: Sha256VerificationStatus.pending,
        ),
      );
      expect(database.getTask('tagged')?.eTag, '"keep"');
      expect(database.getTask('tagged')?.downloadedBytes, 2);
    });

    test('clearing the resume token drops it without dropping the etag', () {
      database.upsert(
        WorkVaultTaskRecord(
          taskId: 'token',
          status: 'paused',
          filePath: '/tmp/token.bin',
          downloadedBytes: 8,
          eTag: '"e"',
          resumptionData: Uint8List.fromList(<int>[1, 2, 3]),
          verificationStatus: Sha256VerificationStatus.pending,
        ),
      );
      database.upsert(
        const WorkVaultTaskRecord(
          taskId: 'token',
          status: 'running',
          filePath: '/tmp/token.bin',
          downloadedBytes: 8,
          verificationStatus: Sha256VerificationStatus.pending,
        ),
        clearResumption: true,
      );
      expect(database.getTask('token')?.resumptionData, isNull);
      expect(database.getTask('token')?.eTag, '"e"');
    });

    test('an unknown task id reads as null', () {
      expect(database.getTask('absent'), isNull);
    });

    test('the handler handle can be replaced', () {
      expect(database.handlerHandle(), isNull);
      database.setHandlerHandle(7);
      database.setHandlerHandle(11);
      expect(database.handlerHandle(), 11);
    });

    test('a file database round-trips a paused download', () async {
      final File store = File('${directory.path}${Platform.pathSeparator}vault.db');
      final WorkVaultDatabase fileDatabase = WorkVaultDatabase.openFile(store.path);
      fileDatabase.upsert(
        WorkVaultTaskRecord(
          taskId: 'disk',
          status: 'paused',
          filePath: '${directory.path}${Platform.pathSeparator}disk.bin',
          downloadedBytes: 64,
          totalBytes: 128,
          eTag: '"disk"',
          resumptionData: Uint8List.fromList(<int>[4, 5]),
          verificationStatus: Sha256VerificationStatus.pending,
        ),
      );
      fileDatabase.close();

      final WorkVaultDatabase reopened = WorkVaultDatabase.openFile(store.path);
      addTearDown(reopened.close);
      final WorkVaultTaskRecord? row = reopened.getTask('disk');
      expect(row?.status, 'paused');
      expect(row?.downloadedBytes, 64);
      expect(row?.totalBytes, 128);
      expect(row?.eTag, '"disk"');
      expect(row?.resumptionData, orderedEquals(<int>[4, 5]));
    });
  });
}

final List<_ConfigCase> _acceptedConfigs = <_ConfigCase>[
  _ConfigCase('a default https GET', sampleConfig),
  _ConfigCase(
    'an explicit port',
    () => sampleConfig(url: 'https://cdn.example.com:443/archive.bin'),
  ),
  _ConfigCase(
    'a query string',
    () => sampleConfig(url: 'https://cdn.example.com/archive.bin?token=1'),
  ),
  _ConfigCase(
    'an encoded path',
    () => sampleConfig(url: 'https://cdn.example.com/my%20archive.bin'),
  ),
  _ConfigCase(
    'a loopback host',
    () => sampleConfig(url: 'https://127.0.0.1/archive.bin'),
  ),
  _ConfigCase(
    'an uppercase scheme',
    () => sampleConfig(url: 'HTTPS://cdn.example.com/archive.bin'),
  ),
  _ConfigCase(
    'user info on an https url',
    () => sampleConfig(url: 'https://user:secret@cdn.example.com/archive.bin'),
  ),
  _ConfigCase(
    'a Windows drive path',
    () => sampleConfig(destinationPath: r'D:\Downloads\archive.bin'),
  ),
  _ConfigCase(
    'a Windows path with slashes',
    () => sampleConfig(destinationPath: 'D:/Downloads/archive.bin'),
  ),
  _ConfigCase(
    'a UNC path',
    () => sampleConfig(destinationPath: r'\\server\share\archive.bin'),
  ),
  _ConfigCase('a one-character task id', () => sampleConfig(taskId: 'a')),
  _ConfigCase(
    'a 128-character task id',
    () => sampleConfig(taskId: 'a' * 128),
  ),
  _ConfigCase(
    'dots, underscores, hyphens, and colons in the task id',
    () => sampleConfig(taskId: 'job.1_a-b:c'),
  ),
  _ConfigCase(
    'an authorization header',
    () => sampleConfig(headers: const <String, String>{'Authorization': 'Bearer token'}),
  ),
  _ConfigCase(
    'a custom request header',
    () => sampleConfig(headers: const <String, String>{'X-Request-Id': 'abc-123'}),
  ),
  _ConfigCase(
    'a single attempt',
    () => sampleConfig(retry: const RetryPolicy(maxAttempts: 1)),
  ),
  _ConfigCase(
    'a multiplier of 1',
    () => sampleConfig(retry: const RetryPolicy(multiplier: 1)),
  ),
  _ConfigCase(
    'a zero backoff',
    () => sampleConfig(
      retry: const RetryPolicy(
        initialBackoff: Duration.zero,
        maxBackoff: Duration.zero,
      ),
    ),
  ),
  _ConfigCase(
    'unmetered network',
    () => sampleConfig().copyWith(network: NetworkConstraint.unmetered),
  ),
  _ConfigCase(
    'not roaming',
    () => sampleConfig().copyWith(network: NetworkConstraint.notRoaming),
  ),
  _ConfigCase(
    'charging required',
    () => sampleConfig().copyWith(
      battery: const BatteryConstraint(requiresCharging: true),
    ),
  ),
  _ConfigCase(
    'battery not low',
    () => sampleConfig().copyWith(
      battery: const BatteryConstraint(requiresBatteryNotLow: true),
    ),
  ),
  _ConfigCase(
    'a dotted notification channel',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: 'Saving archive.bin',
        channelId: 'work.vault.downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
];

final List<_ConfigCase> _rejectedConfigs = <_ConfigCase>[
  _ConfigCase('plain http', () => sampleConfig(url: 'http://cdn.example.com/file.bin')),
  _ConfigCase('ftp', () => sampleConfig(url: 'ftp://cdn.example.com/file.bin')),
  _ConfigCase('a file url', () => sampleConfig(url: 'file:///tmp/file.bin')),
  _ConfigCase('an empty url', () => sampleConfig(url: '')),
  _ConfigCase('a url without a scheme', () => sampleConfig(url: 'cdn.example.com/file.bin')),
  _ConfigCase('https without a host', () => sampleConfig(url: 'https://')),
  _ConfigCase('a relative destination', () => sampleConfig(destinationPath: 'archive.bin')),
  _ConfigCase('an empty destination', () => sampleConfig(destinationPath: '')),
  _ConfigCase(
    'a destination with a newline',
    () => sampleConfig(destinationPath: '/tmp/archive\n.bin'),
  ),
  _ConfigCase('an empty task id', () => sampleConfig(taskId: '')),
  _ConfigCase('a task id with a space', () => sampleConfig(taskId: 'job 1')),
  _ConfigCase('a task id with a slash', () => sampleConfig(taskId: '../job')),
  _ConfigCase('a 129-character task id', () => sampleConfig(taskId: 'a' * 129)),
  _ConfigCase('a unicode task id', () => sampleConfig(taskId: 'job-ن')),
  _ConfigCase('a padded task id', () => sampleConfig(taskId: ' job-1')),
  _ConfigCase('POST', () => sampleConfig(method: HttpMethod.post)),
  _ConfigCase('PUT', () => sampleConfig(method: HttpMethod.put)),
  _ConfigCase('HEAD', () => sampleConfig(method: HttpMethod.head)),
  _ConfigCase(
    'a header name with a space',
    () => sampleConfig(headers: const <String, String>{'Bad Header': '1'}),
  ),
  _ConfigCase(
    'a header name with an underscore',
    () => sampleConfig(headers: const <String, String>{'X_Request': '1'}),
  ),
  _ConfigCase(
    'a header value with a newline',
    () => sampleConfig(headers: const <String, String>{'Accept': 'a\nb'}),
  ),
  _ConfigCase(
    'a header value with a null',
    () => sampleConfig(headers: const <String, String>{'Accept': 'a\u0000b'}),
  ),
  _ConfigCase(
    'zero attempts',
    () => sampleConfig(retry: const RetryPolicy(maxAttempts: 0)),
  ),
  _ConfigCase(
    'a negative attempt count',
    () => sampleConfig(retry: const RetryPolicy(maxAttempts: -1)),
  ),
  _ConfigCase(
    'a negative initial backoff',
    () => sampleConfig(retry: const RetryPolicy(initialBackoff: Duration(seconds: -1))),
  ),
  _ConfigCase(
    'a max backoff below the initial backoff',
    () => sampleConfig(
      retry: const RetryPolicy(
        initialBackoff: Duration(seconds: 5),
        maxBackoff: Duration(seconds: 1),
      ),
    ),
  ),
  _ConfigCase(
    'a multiplier below 1',
    () => sampleConfig(retry: const RetryPolicy(multiplier: 0.5)),
  ),
  _ConfigCase(
    'a NaN multiplier',
    () => sampleConfig(retry: const RetryPolicy(multiplier: double.nan)),
  ),
  _ConfigCase(
    'an infinite multiplier',
    () => sampleConfig(retry: const RetryPolicy(multiplier: double.infinity)),
  ),
  _ConfigCase(
    'an empty notification title',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: '',
        body: 'Saving',
        channelId: 'downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'a blank notification title',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: '   ',
        body: 'Saving',
        channelId: 'downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'a notification title with a newline',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Bad\ntitle',
        body: 'Saving',
        channelId: 'downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'an empty notification body',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: '',
        channelId: 'downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'an empty channel id',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: 'Saving',
        channelId: '',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'a channel id with a colon',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: 'Saving',
        channelId: 'work:downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'a channel id with a space',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: 'Saving',
        channelId: 'work downloads',
        channelName: 'Downloads',
      ),
    ),
  ),
  _ConfigCase(
    'an empty channel name',
    () => sampleConfig().copyWith(
      notification: const NotificationMetadata(
        title: 'Archive',
        body: 'Saving',
        channelId: 'downloads',
        channelName: '',
      ),
    ),
  ),
];

final List<_TransitionCase> _transitions = <_TransitionCase>[
  for (final TaskStatus status in TaskStatus.values)
    for (final TaskCommand command in TaskCommand.values)
      _TransitionCase(status, command, _legal["${status.name}:${command.name}"]),
];

const Map<String, TaskStatus> _legal = <String, TaskStatus>{
  'running:pause': TaskStatus.paused,
  'paused:resume': TaskStatus.running,
  'enqueued:cancel': TaskStatus.cancelled,
  'running:cancel': TaskStatus.cancelled,
  'paused:cancel': TaskStatus.cancelled,
};

final class _ConfigCase {
  const _ConfigCase(this.name, this.build);

  final String name;
  final WorkTaskConfig Function() build;
}

final class _TransitionCase {
  const _TransitionCase(this.from, this.command, this.next);

  final TaskStatus from;
  final TaskCommand command;
  final TaskStatus? next;
}

TaskProgress _progress({
  required int bytes,
  required int total,
  String taskId = 'job-1',
}) {
  return TaskProgress(
    taskId: taskId,
    bytesDownloaded: bytes,
    totalBytes: total,
    bytesPerSecond: 10,
    elapsed: const Duration(seconds: 1),
    percentage: bytes * 100 / total,
  );
}

Map<Object?, Object?> _completed({
  required File file,
  required int bytes,
  required String taskId,
}) {
  return <Object?, Object?>{
    'kind': 'status',
    'taskId': taskId,
    'status': 'completed',
    'filePath': file.path,
    'downloadedBytes': bytes,
    'databasePath': ':memory:',
  };
}

Future<void> _ignoreCallback(int handle, WorkVaultBackgroundEvent event) async {}

final class _ScriptedEngine implements WorkVaultEngine {
  final List<String> calls = <String>[];
  final Map<String, TaskSnapshot> rows = <String, TaskSnapshot>{};
  final List<WorkTaskConfig> enqueued = <WorkTaskConfig>[];

  WorkVaultObserver? observer;
  Object? initializeError;
  String? enqueueTaskId;
  void Function()? duringInitialize;
  bool blockInitialize = false;
  Completer<void>? _initializeGate;

  @override
  Future<void> initialize() async {
    calls.add('initialize');
    if (blockInitialize) {
      _initializeGate = Completer<void>();
      await _initializeGate!.future;
    }
    final Object? error = initializeError;
    if (error != null) {
      throw error;
    }
    duringInitialize?.call();
  }

  void releaseInitialize() {
    final Completer<void>? gate = _initializeGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    calls.add(observer == null ? 'clearObserver' : 'setObserver');
    this.observer = observer;
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    calls.add('enqueue');
    enqueued.add(config);
    final TaskSnapshot snapshot = TaskSnapshot(
      taskId: enqueueTaskId ?? config.taskId,
      status: TaskStatus.enqueued,
    );
    rows[snapshot.taskId] = snapshot;
    return snapshot;
  }

  @override
  Future<void> pause(String taskId) async {
    calls.add('pause:$taskId');
  }

  @override
  Future<void> resume(String taskId) async {
    calls.add('resume:$taskId');
  }

  @override
  Future<void> cancel(String taskId) async {
    calls.add('cancel:$taskId');
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) async {
    calls.add('getTask:$taskId');
    return rows[taskId];
  }

  @override
  Future<List<TaskSnapshot>> getTasks() async {
    calls.add('getTasks');
    return List<TaskSnapshot>.of(rows.values);
  }
}
