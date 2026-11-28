import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';
import 'package:work_vault_example/src/destination_catalog.dart';
import 'package:work_vault_example/src/download_defaults.dart';
import 'package:work_vault_example/src/downloads_controller.dart';

import 'support/fake_engine.dart';

void main() {
  late FakeEngine engine;
  late MemoryDestinationCatalog catalog;
  late DownloadsController controller;

  setUp(() {
    engine = FakeEngine();
    catalog = MemoryDestinationCatalog();
    controller = DownloadsController(
      // ignore: invalid_use_of_visible_for_testing_member
      WorkVault.forTest(engine),
      catalog: catalog,
      resolveDirectory: () async => '/downloads',
    );
  });

  tearDown(() => controller.dispose());

  test('restores the tasks the host kept while the app was closed', () async {
    engine.rows['a'] = const TaskSnapshot(
      taskId: 'a',
      status: TaskStatus.running,
    );
    engine.rows['b'] = const TaskSnapshot(
      taskId: 'b',
      status: TaskStatus.completed,
    );
    catalog = MemoryDestinationCatalog(<String, String>{'b': '/downloads/b'});
    controller.dispose();
    controller = DownloadsController(
      // ignore: invalid_use_of_visible_for_testing_member
      WorkVault.forTest(engine),
      catalog: catalog,
      resolveDirectory: () async => '/downloads',
    );

    await controller.start();

    expect(controller.isLoading, isFalse);
    expect(controller.startupError, isNull);
    expect(controller.tasks.map((TaskSnapshot task) => task.taskId), <String>[
      'a',
      'b',
    ]);
    expect(controller.destinationFor('b'), '/downloads/b');
    expect(controller.downloadDirectory, '/downloads');
  });

  test('reports a host that cannot start and recovers on retry', () async {
    engine.initializeError = PlatformFault('no host');

    await controller.start();
    expect(controller.startupError, 'no host');

    engine.initializeError = null;
    await controller.start();
    expect(controller.startupError, isNull);
  });

  test('status and progress events update the view', () async {
    await controller.start();
    await controller.enqueue(sampleConfig('/downloads', DateTime(2026)));
    final String id = controller.tasks.single.taskId;

    engine.emitStatus(TaskSnapshot(taskId: id, status: TaskStatus.running));
    engine.emitProgress(progressSample(id, downloaded: 300));
    await pumpEventQueue();

    expect(controller.tasks.single.status, TaskStatus.running);
    expect(controller.progressFor(id)?.bytesDownloaded, 300);
    expect(catalog.entries[id], startsWith('/downloads'));
  });

  test('progress stops being followed once a task is terminal', () async {
    await controller.start();
    engine.emitStatus(
      const TaskSnapshot(taskId: 'x', status: TaskStatus.running),
    );
    await pumpEventQueue();
    engine.emitProgress(progressSample('x', downloaded: 100));
    await pumpEventQueue();

    engine.emitStatus(
      const TaskSnapshot(taskId: 'x', status: TaskStatus.completed),
    );
    await pumpEventQueue();
    engine.emitProgress(progressSample('x', downloaded: 900));
    await pumpEventQueue();

    expect(controller.progressFor('x')?.bytesDownloaded, 100);
  });

  test('a command failure is returned for the UI to show', () async {
    engine.rows['r'] = const TaskSnapshot(
      taskId: 'r',
      status: TaskStatus.running,
    );
    await controller.start();

    expect(await controller.run('r', TaskCommand.pause), isNull);
    expect(engine.calls, contains('pause:r'));

    engine.commandError = PlatformFault('host said no');
    expect(await controller.run('r', TaskCommand.cancel), 'host said no');
    expect(controller.isBusy('r'), isFalse);
  });

  test('filters group statuses', () async {
    engine.rows['e'] = const TaskSnapshot(
      taskId: 'e',
      status: TaskStatus.enqueued,
    );
    engine.rows['p'] = const TaskSnapshot(
      taskId: 'p',
      status: TaskStatus.paused,
    );
    await controller.start();

    controller.setFilter(TaskFilter.active);
    expect(controller.tasks.single.taskId, 'e');
    expect(controller.countFor(TaskFilter.paused), 1);
    expect(controller.countFor(TaskFilter.all), 2);
  });

  test('a status the host reports during enqueue is kept', () async {
    await controller.start();
    engine.duringEnqueue = (WorkTaskConfig config) => engine.emitStatus(
      TaskSnapshot(taskId: config.taskId, status: TaskStatus.running),
    );

    await controller.enqueue(sampleConfig('/downloads', DateTime(2026)));
    await pumpEventQueue();

    expect(controller.tasks.single.status, TaskStatus.running);
  });

  test('refresh drops tasks and destinations the host forgot', () async {
    engine.rows['kept'] = const TaskSnapshot(
      taskId: 'kept',
      status: TaskStatus.completed,
    );
    engine.rows['gone'] = const TaskSnapshot(
      taskId: 'gone',
      status: TaskStatus.completed,
    );
    controller.dispose();
    catalog = MemoryDestinationCatalog(<String, String>{
      'kept': '/downloads/kept',
      'gone': '/downloads/gone',
      'stale': '/downloads/stale',
    });
    controller = DownloadsController(
      // ignore: invalid_use_of_visible_for_testing_member
      WorkVault.forTest(engine),
      catalog: catalog,
      resolveDirectory: () async => '/downloads',
    );

    await controller.start();
    await pumpEventQueue();
    // "stale" was never a host task, so start already prunes it.
    expect(catalog.entries.keys, unorderedEquals(<String>['kept', 'gone']));

    engine.rows.remove('gone');
    expect(await controller.refresh(), isNull);
    await pumpEventQueue();

    expect(controller.tasks.map((TaskSnapshot task) => task.taskId), <String>[
      'kept',
    ]);
    expect(catalog.entries.keys, <String>['kept']);
  });

  test('a destination is in use only while its task can write', () async {
    await controller.start();
    final WorkTaskConfig config = sampleConfig('/downloads', DateTime(2026));
    await controller.enqueue(config);

    expect(controller.isDestinationInUse(config.destinationPath), isTrue);
    expect(controller.isDestinationInUse('/downloads/other'), isFalse);

    engine.emitStatus(
      TaskSnapshot(taskId: config.taskId, status: TaskStatus.completed),
    );
    await pumpEventQueue();
    expect(controller.isDestinationInUse(config.destinationPath), isFalse);
  });

  test('catalog writes keep the last state when enqueues overlap', () async {
    await controller.start();
    await Future.wait(<Future<TaskSnapshot>>[
      controller.enqueue(sampleConfig('/downloads', DateTime(2026, 1, 1))),
      controller.enqueue(sampleConfig('/downloads', DateTime(2026, 1, 2))),
    ]);
    await pumpEventQueue();

    expect(catalog.entries, hasLength(2));
  });

  test('task ids are valid and unique per call time', () {
    final String id = taskIdFor('my file (1).zip', DateTime.utc(2026));
    expect(RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(id), isTrue);
    expect(id, startsWith('my-file--1-.zip-'));
    expect(taskIdFor('', DateTime.utc(2026)), startsWith('download-'));
  });
}
