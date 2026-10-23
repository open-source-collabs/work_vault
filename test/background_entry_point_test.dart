import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:work_vault/work_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a closure cannot be registered as the background handler', () async {
    await expectLater(
      WorkVault.registerBackgroundHandler(
        (WorkVaultBackgroundEvent _) async {},
      ),
      throwsArgumentError,
    );
  });

  testWidgets('the headless entry point signals ready', (
    WidgetTester tester,
  ) async {
    final List<String> methods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(workVaultBackgroundChannel),
      (MethodCall call) async {
        methods.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(workVaultBackgroundChannel),
        null,
      );
    });

    workVaultBackgroundMain();
    await tester.idle();

    expect(methods, contains('ready'));
  });

  group('dispatch', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('work_vault_dispatch');
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    Map<String, Object?> payload(String databasePath, String taskId) {
      return <String, Object?>{
        'kind': 'status',
        'taskId': taskId,
        'status': 'running',
        'filePath': '/data/user/0/$taskId.bin',
        'downloadedBytes': 10,
        'databasePath': databasePath,
      };
    }

    Future<ByteData?> send(
      WidgetTester tester,
      String method, [
      Object? arguments,
    ]) async {
      const MethodChannel channel = MethodChannel(workVaultBackgroundChannel);
      final ByteData? reply = await tester.runAsync<ByteData?>(() async {
        final Completer<ByteData?> done = Completer<ByteData?>();
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, arguments)),
          done.complete,
        );
        return done.future;
      });
      return reply;
    }

    void mockHost(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(workVaultBackgroundChannel),
        (MethodCall call) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(workVaultBackgroundChannel),
          null,
        );
      });
    }

    testWidgets('each event is written to the database its payload names', (
      WidgetTester tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(workVaultBackgroundChannel),
        (MethodCall call) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(workVaultBackgroundChannel),
          null,
        );
      });
      final String first = '${directory.path}/first.db';
      final String second = '${directory.path}/second.db';

      workVaultBackgroundMain();
      await send(tester, 'dispatch', payload(first, 'job-a'));
      await send(tester, 'dispatch', payload(second, 'job-b'));
      await send(tester, 'shutdown');

      final WorkVaultDatabase firstDb = WorkVaultDatabase.openFile(first);
      final WorkVaultDatabase secondDb = WorkVaultDatabase.openFile(second);
      addTearDown(firstDb.close);
      addTearDown(secondDb.close);
      expect(firstDb.getTasks().map((r) => r.taskId), <String>['job-a']);
      expect(secondDb.getTasks().map((r) => r.taskId), <String>['job-b']);
    });

    testWidgets('events for one path share a database and survive a shutdown', (
      WidgetTester tester,
    ) async {
      mockHost(tester);
      final String path = '${directory.path}/shared.db';

      workVaultBackgroundMain();
      await send(tester, 'dispatch', payload(path, 'job-a'));
      await send(tester, 'dispatch', payload(path, 'job-b'));
      await send(tester, 'shutdown');
      await send(tester, 'dispatch', payload(path, 'job-c'));
      await send(tester, 'shutdown');

      final WorkVaultDatabase database = WorkVaultDatabase.openFile(path);
      addTearDown(database.close);
      expect(database.getTasks().map((r) => r.taskId), <String>[
        'job-a',
        'job-b',
        'job-c',
      ]);
    });

    testWidgets('a database written by a newer version is refused', (
      WidgetTester tester,
    ) async {
      mockHost(tester);
      final String path = '${directory.path}/newer.db';
      sqlite3.open(path)
        ..execute('PRAGMA user_version = 2')
        ..close();
      const MethodChannel channel = MethodChannel(workVaultBackgroundChannel);

      workVaultBackgroundMain();
      final ByteData? reply = await send(
        tester,
        'dispatch',
        payload(path, 'job-a'),
      );

      expect(
        () => channel.codec.decodeEnvelope(reply!),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
