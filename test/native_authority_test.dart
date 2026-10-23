import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/isolate/background_event_processor.dart';
import 'package:work_vault/work_vault.dart';

/// Version 1 ownership rules.
///
/// The host store decides status, bytes, the entity tag, and the resume token. SQLite is
/// the projection the headless callback reads. Hashing a completed file records
/// verified, mismatch, or missing and never moves the task to another status.
void main() {
  late Directory directory;
  late WorkVaultDatabase database;
  const BackgroundEventProcessor processor = BackgroundEventProcessor(
    invoke: _ignoreCallback,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('work-vault-authority-');
    database = WorkVaultDatabase.memory();
  });

  tearDown(() async {
    database.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  group('host projection', () {
    test(
      'a projection replaces a stale status, byte count, and entity tag',
      () {
        database.project(
          _record(status: 'running', bytes: 10, eTag: '"v1"', total: 100),
        );
        database.project(
          _record(status: 'paused', bytes: 64, eTag: '"v2"', total: 128),
        );

        final WorkVaultTaskRecord? row = database.getTask('job-1');
        expect(row?.status, 'paused');
        expect(row?.downloadedBytes, 64);
        expect(row?.eTag, '"v2"');
        expect(row?.totalBytes, 128);
      },
    );

    test('a host value that is now unknown clears the stored one', () {
      database.project(
        _record(status: 'running', bytes: 10, eTag: '"v1"', total: 100),
      );
      database.project(_record(status: 'enqueued', bytes: 0));

      final WorkVaultTaskRecord? row = database.getTask('job-1');
      expect(row?.eTag, isNull);
      expect(row?.totalBytes, isNull);
      expect(row?.downloadedBytes, 0);
    });

    test('a projection drops a resume token the host no longer holds', () {
      database.project(
        _record(
          status: 'paused',
          bytes: 32,
          resumptionData: Uint8List.fromList(<int>[7, 7]),
        ),
      );
      expect(database.getTask('job-1')?.resumptionData, isNotNull);

      database.project(_record(status: 'running', bytes: 48));
      expect(database.getTask('job-1')?.resumptionData, isNull);
    });

    test(
      'a projection keeps the digest and verification this isolate owns',
      () async {
        final File file = await _file('keep.bin', 'abc');
        await processor.apply(database, _event(file: file, bytes: 3));
        final String? digest = database.getTask('job-1')?.sha256;
        expect(digest, isNotNull);

        database.project(
          _record(status: 'completed', bytes: 3, path: file.path),
        );

        expect(database.getTask('job-1')?.sha256, digest);
        expect(
          database.getTask('job-1')?.verificationStatus,
          Sha256VerificationStatus.verified,
        );
      },
    );

    test('a reload removes tasks the host has forgotten', () async {
      final File file = await _file('reload.bin', 'abc');
      await processor.apply(database, _event(file: file, bytes: 3));
      database.project(_record(taskId: 'job-2', status: 'running', bytes: 5));
      expect(database.getTasks(), hasLength(2));

      database.projectAll(<WorkVaultTaskRecord>[
        _record(status: 'completed', bytes: 3, path: file.path),
      ]);

      expect(
        database.getTasks().map((WorkVaultTaskRecord r) => r.taskId),
        <String>['job-1'],
      );
      expect(
        database.getTask('job-1')?.verificationStatus,
        Sha256VerificationStatus.verified,
      );
    });

    test('a reload with no host tasks empties the projection', () async {
      final File file = await _file('empty.bin', 'abc');
      await processor.apply(database, _event(file: file, bytes: 3));
      database.projectAll(const <WorkVaultTaskRecord>[]);
      expect(database.getTasks(), isEmpty);
    });

    test('a progress event projects the host byte count', () async {
      final File file = await _file('progress.bin', 'ab');
      await processor.apply(database, <Object?, Object?>{
        'kind': 'progress',
        'taskId': 'job-1',
        'status': 'running',
        'filePath': file.path,
        'downloadedBytes': 2,
        'totalBytes': 3,
        'databasePath': ':memory:',
      });

      final WorkVaultTaskRecord? row = database.getTask('job-1');
      expect(row?.status, 'running');
      expect(row?.downloadedBytes, 2);
      expect(row?.totalBytes, 3);
      expect(row?.verificationStatus, Sha256VerificationStatus.pending);
      expect(row?.sha256, isNull);
    });
  });

  group('checksum ownership', () {
    test('a matching file is verified and stays completed', () async {
      final File file = await _file('match.bin', 'abc');
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _event(file: file, bytes: 3),
      );

      expect(event.status, 'completed');
      expect(event.verificationStatus, Sha256VerificationStatus.verified);
      expect(event.sha256, _abcDigest);
      expect(database.getTask('job-1')?.status, 'completed');
    });

    test(
      'a mismatch is recorded without moving the task off completed',
      () async {
        final File file = await _file('drifted.bin', 'abc');
        await processor.apply(database, _event(file: file, bytes: 3));
        await file.writeAsString('zzz');

        final WorkVaultBackgroundEvent event = await processor.apply(
          database,
          _event(file: file, bytes: 3),
        );

        expect(event.status, 'completed');
        expect(event.verificationStatus, Sha256VerificationStatus.mismatch);
        expect(event.sha256, _abcDigest);
        expect(database.getTask('job-1')?.status, 'completed');
      },
    );

    test(
      'a missing file is recorded without moving the task off completed',
      () async {
        final WorkVaultBackgroundEvent event = await processor.apply(
          database,
          <Object?, Object?>{
            'kind': 'status',
            'taskId': 'job-1',
            'status': 'completed',
            'filePath': '${directory.path}${Platform.pathSeparator}absent.bin',
            'downloadedBytes': 0,
            'databasePath': ':memory:',
          },
        );

        expect(event.status, 'completed');
        expect(event.verificationStatus, Sha256VerificationStatus.missing);
        expect(event.sha256, isNull);
        expect(database.getTask('job-1')?.status, 'completed');
      },
    );

    test(
      'the host digest is the one a first hash is compared against',
      () async {
        final File file = await _file('host.bin', 'abc');
        final WorkVaultBackgroundEvent event = await processor.apply(
          database,
          _event(file: file, bytes: 3, sha256: _abcDigest),
        );
        expect(event.verificationStatus, Sha256VerificationStatus.verified);
        expect(event.sha256, _abcDigest);
      },
    );

    test('a file that differs from the host digest is a mismatch on the first hash', () async {
      final File file = await _file('wrong.bin', 'zzz');
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        _event(file: file, bytes: 3, sha256: _abcDigest),
      );

      expect(event.status, 'completed');
      expect(event.verificationStatus, Sha256VerificationStatus.mismatch);
      expect(event.sha256, _abcDigest);
    });

    test('a failed task is never hashed', () async {
      final File file = await _file('failed.bin', 'abc');
      final WorkVaultBackgroundEvent event = await processor.apply(
        database,
        <Object?, Object?>{
          'kind': 'status',
          'taskId': 'job-1',
          'status': 'failed',
          'filePath': file.path,
          'downloadedBytes': 3,
          'databasePath': ':memory:',
        },
      );

      expect(event.status, 'failed');
      expect(event.verificationStatus, Sha256VerificationStatus.pending);
      expect(event.sha256, isNull);
    });

    test('a later progress event keeps the recorded verification', () async {
      final File file = await _file('sticky.bin', 'abc');
      await processor.apply(database, _event(file: file, bytes: 3));
      await processor.apply(database, <Object?, Object?>{
        'kind': 'progress',
        'taskId': 'job-1',
        'status': 'running',
        'filePath': file.path,
        'downloadedBytes': 1,
        'databasePath': ':memory:',
      });

      final WorkVaultTaskRecord? row = database.getTask('job-1');
      expect(row?.status, 'running');
      expect(row?.verificationStatus, Sha256VerificationStatus.verified);
      expect(row?.sha256, _abcDigest);
    });
  });

  group('version 1 transfer surface', () {
    test('only GET is accepted', () {
      for (final HttpMethod method in HttpMethod.values) {
        final WorkTaskConfig config = WorkTaskConfig(
          taskId: 'job-1',
          url: 'https://cdn.example.com/archive.bin',
          destinationPath: '/data/user/0/archive.bin',
          method: method,
          notification: const NotificationMetadata(
            title: 'Archive',
            body: 'Saving archive.bin',
            channelId: 'downloads',
            channelName: 'Downloads',
          ),
        );
        if (method == HttpMethod.get) {
          expect(config.validate, returnsNormally, reason: method.name);
        } else {
          expect(
            config.validate,
            throwsA(isA<InvalidWorkConfig>()),
            reason: method.name,
          );
        }
      }
    });
  });
}

const String _abcDigest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

Future<File> _file(String name, String contents) async {
  final Directory parent = Directory.systemTemp;
  final File file = File(
    '${parent.path}${Platform.pathSeparator}work-vault-$name',
  );
  await file.writeAsString(contents);
  addTearDown(() async {
    if (file.existsSync()) {
      await file.delete();
    }
  });
  return file;
}

WorkVaultTaskRecord _record({
  String taskId = 'job-1',
  required String status,
  required int bytes,
  String path = '/tmp/work-vault.bin',
  String? eTag,
  int? total,
  Uint8List? resumptionData,
}) {
  return WorkVaultTaskRecord(
    taskId: taskId,
    status: status,
    filePath: path,
    eTag: eTag,
    downloadedBytes: bytes,
    totalBytes: total,
    resumptionData: resumptionData,
    verificationStatus: Sha256VerificationStatus.pending,
  );
}

Map<Object?, Object?> _event({
  required File file,
  required int bytes,
  String taskId = 'job-1',
  String? sha256,
}) {
  return <Object?, Object?>{
    'kind': 'status',
    'taskId': taskId,
    'status': 'completed',
    'filePath': file.path,
    'downloadedBytes': bytes,
    'databasePath': ':memory:',
    'sha256': ?sha256,
  };
}

Future<void> _ignoreCallback(
  int handle,
  WorkVaultBackgroundEvent event,
) async {}
