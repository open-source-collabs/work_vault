@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/models/task_snapshot.dart';
import 'package:work_vault/src/models/task_status.dart';
import 'package:work_vault/src/models/work_task_config.dart';
import 'package:work_vault/src/persistence/work_vault_database.dart';
import 'package:work_vault/src/web/web_work_vault_engine.dart';

import '../support.dart';

void main() {
  late WorkVaultDatabase database;
  late WebWorkVaultEngine engine;

  setUp(() async {
    database = WorkVaultDatabase.memory();
    engine = WebWorkVaultEngine(database: database);
    await engine.initialize();
  });

  tearDown(() {
    database.close();
  });

  test('enqueues task and returns enqueued snapshot on web', () async {
    final WorkTaskConfig config = sampleConfig(
      taskId: 'web-task-1',
      destinationPath: 'archive.bin',
    );

    final TaskSnapshot snapshot = await engine.enqueue(config);
    expect(snapshot.taskId, 'web-task-1');
    expect(snapshot.status, TaskStatus.enqueued);

    final TaskSnapshot? stored = await engine.getTask('web-task-1');
    expect(stored, isNotNull);
    expect(stored?.taskId, 'web-task-1');
  });

  test('pauses and cancels task on web', () async {
    final WorkTaskConfig config = sampleConfig(
      taskId: 'web-task-2',
      destinationPath: 'archive.bin',
    );

    await engine.enqueue(config);
    await engine.pause('web-task-2');

    TaskSnapshot? snapshot = await engine.getTask('web-task-2');
    expect(snapshot?.status, TaskStatus.paused);

    await engine.cancel('web-task-2');
    snapshot = await engine.getTask('web-task-2');
    expect(snapshot?.status, TaskStatus.cancelled);
  });

  test('getTasks retrieves all tasks on web', () async {
    final WorkTaskConfig config1 = sampleConfig(
      taskId: 'web-task-a',
      destinationPath: 'a.bin',
    );
    final WorkTaskConfig config2 = sampleConfig(
      taskId: 'web-task-b',
      destinationPath: 'b.bin',
    );

    await engine.enqueue(config1);
    await engine.enqueue(config2);

    final List<TaskSnapshot> tasks = await engine.getTasks();
    expect(tasks.length, 2);
    expect(
      tasks.map((t) => t.taskId),
      containsAll(<String>['web-task-a', 'web-task-b']),
    );
  });
  test(
    'resume continues a paused task and ignores one that is not paused',
    () async {
      await engine.enqueue(
        sampleConfig(taskId: 'web-task-3', destinationPath: 'c.bin'),
      );
      await engine.pause('web-task-3');
      expect((await engine.getTask('web-task-3'))?.status, TaskStatus.paused);

      await engine.resume('web-task-3');
      expect(
        (await engine.getTask('web-task-3'))?.status,
        isNot(TaskStatus.paused),
      );

      await engine.cancel('web-task-3');
      await engine.resume('web-task-3');
      expect(
        (await engine.getTask('web-task-3'))?.status,
        TaskStatus.cancelled,
      );
    },
  );
}
