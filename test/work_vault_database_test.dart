import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  test(
    'completed file stores a verified digest and a later change mismatches',
    () async {
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
    },
  );

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
}

Future<void> _ignoreCallback(
  int handle,
  WorkVaultBackgroundEvent event,
) async {}
