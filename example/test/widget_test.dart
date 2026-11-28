@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:work_vault/work_vault.dart';
import 'package:work_vault_example/src/app.dart';
import 'package:work_vault_example/src/destination_catalog.dart';
import 'package:work_vault_example/src/downloads_controller.dart';

import 'support/fake_engine.dart';

void main() {
  late FakeEngine engine;
  late DownloadsController controller;

  setUp(() {
    engine = FakeEngine();
    controller = DownloadsController(
      // ignore: invalid_use_of_visible_for_testing_member
      WorkVault.forTest(engine),
      catalog: MemoryDestinationCatalog(),
      resolveDirectory: () async => '/downloads',
    );
  });

  tearDown(() => controller.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(WorkVaultExampleApp(controller: controller));
    await tester.pumpAndSettle();
  }

  /// Lets real file IO finish, then pumps until [finder] matches.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (int i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsOneWidget);
  }

  testWidgets('a completed file shows its size and can be hashed', (
    WidgetTester tester,
  ) async {
    final Directory dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('work_vault_example_widget'),
    ))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}${Platform.pathSeparator}done.txt';
    await tester.runAsync(() => File(path).writeAsString('hello'));

    engine.rows['done'] = const TaskSnapshot(
      taskId: 'done',
      status: TaskStatus.completed,
    );
    controller.dispose();
    controller = DownloadsController(
      // ignore: invalid_use_of_visible_for_testing_member
      WorkVault.forTest(engine),
      catalog: MemoryDestinationCatalog(<String, String>{'done': path}),
      resolveDirectory: () async => dir.path,
    );
    await pumpApp(tester);

    await pumpUntilFound(tester, find.text('5 B'));
    await tester.tap(find.text('Compute SHA-256'));
    await pumpUntilFound(
      tester,
      find.text(
        'SHA-256 '
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      ),
    );
    expect(find.byTooltip('Copy SHA-256'), findsOneWidget);
  });

  testWidgets('a completed task without a recorded file says so', (
    WidgetTester tester,
  ) async {
    engine.rows['old'] = const TaskSnapshot(
      taskId: 'old',
      status: TaskStatus.completed,
    );
    await pumpApp(tester);

    expect(find.textContaining('Saved outside this app'), findsOneWidget);
  });

  testWidgets('the form refuses a file an active download is writing', (
    WidgetTester tester,
  ) async {
    engine.rows['seed'] = const TaskSnapshot(
      taskId: 'seed',
      status: TaskStatus.completed,
    );
    await pumpApp(tester);

    for (int attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('New download'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('fileName')),
        'same.bin',
      );
      await tester.tap(find.text('Start download'));
      await tester.pumpAndSettle();
    }

    expect(
      find.text(
        'Another download is still saving to this file. Pick another name.',
      ),
      findsOneWidget,
    );
    expect(
      engine.calls.where((String c) => c.startsWith('enqueue:')),
      hasLength(1),
    );
  });

  testWidgets('empty state enqueues the sample download', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('No downloads yet'), findsOneWidget);
    await tester.tap(find.text('Add sample download'));
    await tester.pumpAndSettle();

    expect(
      engine.calls.where((String c) => c.startsWith('enqueue:')),
      hasLength(1),
    );
    expect(find.text('enqueued'), findsOneWidget);
    expect(find.text('New download'), findsOneWidget);
  });

  testWidgets('controls follow the status machine', (
    WidgetTester tester,
  ) async {
    // A known size keeps the bar determinate, so the frame can settle.
    engine.rows['run'] = TaskSnapshot(
      taskId: 'run',
      status: TaskStatus.running,
      progress: progressSample('run', downloaded: 512, total: 1024),
    );
    engine.rows['zz-paused'] = const TaskSnapshot(
      taskId: 'zz-paused',
      status: TaskStatus.paused,
    );
    await pumpApp(tester);

    Finder inTile(String taskId, String tooltip) => find.descendant(
      of: find.byKey(ValueKey<String>(taskId)),
      matching: find.byTooltip(tooltip),
    );

    expect(inTile('run', 'Pause'), findsOneWidget);
    expect(inTile('run', 'Resume'), findsNothing);
    expect(inTile('run', 'Cancel'), findsOneWidget);
    expect(inTile('zz-paused', 'Pause'), findsNothing);
    expect(inTile('zz-paused', 'Resume'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.textContaining('512 B of 1.0 KB'), findsOneWidget);

    await tester.tap(inTile('run', 'Pause'));
    await tester.pumpAndSettle();
    expect(engine.calls, contains('pause:run'));

    // Cancel asks first, and "Keep" sends nothing.
    await tester.tap(inTile('zz-paused', 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(engine.calls, isNot(contains('cancel:zz-paused')));
  });

  testWidgets('a failed task shows its failure', (WidgetTester tester) async {
    engine.rows['bad'] = const TaskSnapshot(
      taskId: 'bad',
      status: TaskStatus.failed,
      failure: TaskFailure(
        taskId: 'bad',
        code: 'http',
        message: 'Server returned 404.',
        httpStatus: 404,
        retryable: false,
      ),
    );
    await pumpApp(tester);

    expect(find.text('http'), findsOneWidget);
    expect(find.text('HTTP 404'), findsOneWidget);
    expect(find.text('Server returned 404.'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);
  });

  testWidgets('the form shows the vault validation message', (
    WidgetTester tester,
  ) async {
    engine.rows['seed'] = const TaskSnapshot(
      taskId: 'seed',
      status: TaskStatus.completed,
    );
    await pumpApp(tester);

    await tester.tap(find.text('New download'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('url')),
      'http://example.com/file',
    );
    await tester.tap(find.text('Start download'));
    await tester.pumpAndSettle();

    expect(find.text('url must be an absolute https URL.'), findsOneWidget);
    expect(engine.calls.where((String c) => c.startsWith('enqueue:')), isEmpty);
  });

  testWidgets('a valid form enqueues and closes', (WidgetTester tester) async {
    engine.rows['seed'] = const TaskSnapshot(
      taskId: 'seed',
      status: TaskStatus.completed,
    );
    await pumpApp(tester);

    await tester.tap(find.text('New download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start download'));
    await tester.pumpAndSettle();

    expect(find.text('Start download'), findsNothing);
    expect(
      engine.calls.where((String c) => c.startsWith('enqueue:')),
      hasLength(1),
    );
  });
}
