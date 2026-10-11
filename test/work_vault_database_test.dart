import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:work_vault/src/isolate/background_event_processor.dart';
import 'package:work_vault/src/persistence/work_vault_database.dart';

void main() {
  test('round-trips a task, resume token, and handler handle', () {
    final WorkVaultDatabase database = WorkVaultDatabase.memory();
    addTearDown(database.close);
    final Uint8List token = Uint8List.fromList(<int>[1, 2, 3, 4]);
    database.upsert(
      WorkVaultTaskRecord(
        taskId: 'job-1',
        status: 'paused',
        filePath: '/tmp/archive.bin',
        eTag: '"v1"',
        downloadedBytes: 4,
        totalBytes: 10,
        resumptionData: token,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );
    database.upsert(
      const WorkVaultTaskRecord(
        taskId: 'job-1',
        status: 'running',
        filePath: '/tmp/archive.bin',
        downloadedBytes: 6,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
      preserveVerification: true,
    );
    database.setHandlerHandle(42);

    final WorkVaultTaskRecord? row = database.getTask('job-1');
    expect(row?.status, 'running');
    expect(row?.eTag, '"v1"');
    expect(row?.downloadedBytes, 6);
    expect(row?.totalBytes, 10);
    expect(row?.resumptionData, orderedEquals(<int>[1, 2, 3, 4]));
    expect(row?.verificationStatus, Sha256VerificationStatus.pending);
    expect(database.handlerHandle(), 42);
    expect(database.getTasks(), hasLength(1));
  });

  test('completed file stores a verified digest and a later change mismatches', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'work-vault-db-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/archive.bin');
    await file.writeAsString('abc');
    final WorkVaultDatabase database = WorkVaultDatabase.memory();
    addTearDown(database.close);
    final BackgroundEventProcessor processor = BackgroundEventProcessor(
      invoke: (int handle, WorkVaultBackgroundEvent event) async {},
    );

    final WorkVaultBackgroundEvent verified = await processor.apply(
      database,
      <Object?, Object?>{
        'kind': 'status',
        'taskId': 'job-1',
        'status': 'completed',
        'filePath': file.path,
        'downloadedBytes': 3,
        'databasePath': '${directory.path}/work_vault.db',
        'callbackHandle': 7,
      },
    );
    expect(verified.verificationStatus, Sha256VerificationStatus.verified);
    expect(
      verified.sha256,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    await file.writeAsString('abcd');
    final WorkVaultBackgroundEvent mismatched = await processor.apply(
      database,
      <Object?, Object?>{
        'kind': 'status',
        'taskId': 'job-1',
        'status': 'completed',
        'filePath': file.path,
        'downloadedBytes': 4,
        'databasePath': '${directory.path}/work_vault.db',
      },
    );
    expect(mismatched.verificationStatus, Sha256VerificationStatus.mismatch);
    expect(mismatched.sha256, verified.sha256);

    final List<int> handles = <int>[];
    final BackgroundEventProcessor recording = BackgroundEventProcessor(
      invoke: (int handle, WorkVaultBackgroundEvent event) async {
        handles.add(handle);
      },
    );
    await recording.apply(database, <Object?, Object?>{
      'kind': 'progress',
      'taskId': 'job-1',
      'status': 'running',
      'filePath': file.path,
      'downloadedBytes': 1,
      'databasePath': '${directory.path}/work_vault.db',
      'callbackHandle': 7,
    });
    expect(handles, <int>[7]);
    expect(
      database.getTask('job-1')?.verificationStatus,
      Sha256VerificationStatus.mismatch,
    );
  });

  test('a missing completed file is recorded as missing', () async {
    final WorkVaultDatabase database = WorkVaultDatabase.memory();
    addTearDown(database.close);
    final BackgroundEventProcessor processor = const BackgroundEventProcessor(
      invoke: _ignoreCallback,
    );
    final WorkVaultBackgroundEvent event = await processor.apply(
      database,
      <Object?, Object?>{
        'kind': 'status',
        'taskId': 'gone',
        'status': 'completed',
        'filePath': '/tmp/work-vault-missing-file.bin',
        'downloadedBytes': 0,
        'databasePath': ':memory:',
      },
    );
    expect(event.verificationStatus, Sha256VerificationStatus.missing);
    expect(event.sha256, isNull);
  });

  group('schema version', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('work_vault_schema');
    });

    tearDown(() {
      directory.deleteSync(recursive: true);
    });

    int storedVersion(String path) {
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      try {
        return raw.select('PRAGMA user_version').first.values.first! as int;
      } finally {
        raw.close();
      }
    }

    test('a new file is stamped with version 1', () {
      final String path = '${directory.path}/new.db';
      WorkVaultDatabase.openFile(path).close();

      expect(storedVersion(path), 1);
    });

    test('a file written before versioning keeps its rows and is stamped', () {
      final String path = '${directory.path}/legacy.db';
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw
        ..execute('''
          CREATE TABLE tasks (
            task_id TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL,
            file_path TEXT NOT NULL,
            etag TEXT,
            downloaded_bytes INTEGER NOT NULL,
            total_bytes INTEGER,
            resumption_data BLOB,
            sha256 TEXT,
            verification_status TEXT NOT NULL
          )
          ''')
        ..execute(
          "INSERT INTO tasks VALUES ('old', 'paused', '/tmp/a.bin', NULL, 5, "
          "NULL, NULL, NULL, 'pending')",
        )
        ..close();

      final WorkVaultDatabase database = WorkVaultDatabase.openFile(path);
      final WorkVaultTaskRecord? row = database.getTask('old');
      database.close();

      expect(row?.downloadedBytes, 5);
      expect(storedVersion(path), 1);
    });

    test('a file from a newer version is refused', () {
      final String path = '${directory.path}/newer.db';
      sqlite.sqlite3.open(path)
        ..execute('PRAGMA user_version = 2')
        ..close();

      expect(() => WorkVaultDatabase.openFile(path), throwsStateError);
      expect(storedVersion(path), 2);
    });
  });
}

Future<void> _ignoreCallback(int handle, WorkVaultBackgroundEvent event) async {}
