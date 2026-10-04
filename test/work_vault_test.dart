import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';

import 'fake_work_vault_engine.dart';
import 'support.dart';

void main() {
  late FakeWorkVaultEngine engine;
  late WorkVault vault;

  setUp(() {
    engine = FakeWorkVaultEngine();
    vault = WorkVault.forTest(engine);
  });

  test('initialize hydrates tasks and ignores a second call', () async {
    engine.rows['job-1'] = sampleSnapshot();
    final List<TaskStatus> statuses = <TaskStatus>[];
    vault.watchStatus(taskId: 'job-1').listen((TaskSnapshot snapshot) {
      statuses.add(snapshot.status);
    });

    await vault.initialize();
    await vault.initialize();
    await pumpEventQueue();

    expect(vault.isInitialized, isTrue);
    expect(engine.calls, <String>['setObserver', 'initialize', 'getTasks']);
    expect(statuses, <TaskStatus>[TaskStatus.enqueued]);
    expect(vault.observationFor('job-1'), (
      snapshot: sampleSnapshot(),
      progress: null,
    ));
  });

  test(
    'applies host events that arrive while initialize is in flight',
    () async {
      engine.rows['job-1'] = sampleSnapshot();
      engine.duringInitialize = () {
        engine.observer?.onStatusChanged(
          sampleSnapshot(status: TaskStatus.running),
        );
      };

      await vault.initialize();

      expect(
        vault.observationFor('job-1')?.snapshot.status,
        TaskStatus.running,
      );
    },
  );

  test(
    'enqueue validates, rejects duplicates, and publishes the snapshot',
    () async {
      await vault.initialize();

      await expectLater(
        vault.enqueue(sampleConfig(url: 'http://example.com/file.bin')),
        throwsA(isA<InvalidWorkConfig>()),
      );
      expect(engine.calls, isNot(contains('enqueue')));

      final TaskSnapshot snapshot = await vault.enqueue(sampleConfig());
      expect(snapshot.status, TaskStatus.enqueued);

      await expectLater(
        vault.enqueue(sampleConfig()),
        throwsA(isA<DuplicateTask>()),
      );
      expect(
        engine.calls.where((String call) => call == 'enqueue'),
        hasLength(1),
      );
    },
  );

  test('commands follow the status machine', () async {
    await vault.initialize();
    await vault.enqueue(sampleConfig());

    await expectLater(
      vault.pause('job-1'),
      throwsA(isA<IllegalTaskTransition>()),
    );
    expect(engine.calls, isNot(contains('pause:job-1')));

    engine.observer?.onStatusChanged(
      sampleSnapshot(status: TaskStatus.running),
    );
    await pumpEventQueue();
    await vault.pause('job-1');
    expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.paused);

    await vault.resume('job-1');
    expect(vault.observationFor('job-1')?.snapshot.status, TaskStatus.running);

    await vault.cancel('job-1');
    expect(
      vault.observationFor('job-1')?.snapshot.status,
      TaskStatus.cancelled,
    );
    await expectLater(vault.cancel('missing'), throwsA(isA<TaskNotFound>()));
  });

  test('progress updates the cache without a second status event', () async {
    await vault.initialize();
    await vault.enqueue(sampleConfig());
    engine.observer?.onStatusChanged(
      sampleSnapshot(status: TaskStatus.running),
    );
    await pumpEventQueue();

    final List<TaskStatus> statuses = <TaskStatus>[];
    final List<int> bytes = <int>[];
    vault.watchStatus(taskId: 'job-1').listen((TaskSnapshot snapshot) {
      statuses.add(snapshot.status);
    });
    vault.watchProgress('job-1').listen((TaskProgress progress) {
      bytes.add(progress.bytesDownloaded);
    });

    const TaskProgress sample = TaskProgress(
      taskId: 'job-1',
      bytesDownloaded: 50,
      totalBytes: 100,
      bytesPerSecond: 10,
      elapsed: Duration(seconds: 5),
      percentage: 50,
    );
    engine.observer?.onProgress(sample);
    await pumpEventQueue();

    expect(bytes, <int>[50]);
    expect(statuses, <TaskStatus>[TaskStatus.running]);
    expect(vault.observationFor('job-1')?.progress?.fraction, 0.5);
  });

  test('a terminal snapshot ignores a later stale running update', () async {
    engine.rows['job-1'] = sampleSnapshot(status: TaskStatus.completed);
    await vault.initialize();

    engine.observer?.onStatusChanged(
      sampleSnapshot(status: TaskStatus.running),
    );
    engine.observer?.onProgress(
      const TaskProgress(
        taskId: 'job-1',
        bytesDownloaded: 1,
        totalBytes: 2,
        bytesPerSecond: 1,
        elapsed: Duration(seconds: 1),
        percentage: 50,
      ),
    );
    await pumpEventQueue();

    final TaskObservation? observation = vault.observationFor('job-1');
    expect(observation?.snapshot.status, TaskStatus.completed);
    expect(observation?.progress, isNull);
  });

  test('commands before initialize fail', () async {
    await expectLater(
      vault.enqueue(sampleConfig()),
      throwsA(isA<WorkVaultNotInitialized>()),
    );
  });

  test(
    'dispose ends the session and the next initialize starts clean',
    () async {
      await vault.initialize();
      await vault.enqueue(sampleConfig());
      await vault.dispose();

      expect(vault.isInitialized, isFalse);
      expect(vault.observationFor('job-1'), isNull);
      expect(engine.calls, contains('clearObserver'));

      engine.rows.clear();
      await vault.initialize();
      expect(vault.observationFor('job-1'), isNull);
      expect(vault.isInitialized, isTrue);
    },
  );
}
