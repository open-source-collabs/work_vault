import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'work_vault_database_interface.dart';

/// Opens file database using sqlite3 and dart:io.
WorkVaultDatabase openWorkVaultDatabaseFile(String path) {
  return WorkVaultDatabaseIO.openFile(path);
}

/// Opens in-memory database using sqlite3.
WorkVaultDatabase openWorkVaultDatabaseMemory() {
  return WorkVaultDatabaseIO.memory();
}

/// SQLite implementation of [WorkVaultDatabase] for IO platforms.
final class WorkVaultDatabaseIO implements WorkVaultDatabase {
  WorkVaultDatabaseIO._(this._database) {
    _ensureSchema();
  }

  final Database _database;

  /// Opens [path], creating parent directories and the schema.
  factory WorkVaultDatabaseIO.openFile(String path) {
    final Directory parent = File(path).parent;
    parent.createSync(recursive: true);
    return WorkVaultDatabaseIO._(sqlite3.open(path));
  }

  /// Opens a private in-memory database for tests.
  factory WorkVaultDatabaseIO.memory() {
    return WorkVaultDatabaseIO._(sqlite3.openInMemory());
  }

  @override
  void upsert(
    WorkVaultTaskRecord record, {
    bool clearResumption = false,
    bool preserveVerification = false,
  }) {
    _database.execute(
      '''
      INSERT INTO tasks (
        task_id, status, file_path, etag, downloaded_bytes, total_bytes,
        resumption_data, sha256, verification_status
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(task_id) DO UPDATE SET
        status = excluded.status,
        file_path = excluded.file_path,
        etag = COALESCE(excluded.etag, tasks.etag),
        downloaded_bytes = excluded.downloaded_bytes,
        total_bytes = COALESCE(excluded.total_bytes, tasks.total_bytes),
        resumption_data = CASE
          WHEN ? = 1 THEN NULL
          ELSE COALESCE(excluded.resumption_data, tasks.resumption_data)
        END,
        sha256 = CASE
          WHEN ? = 1 THEN tasks.sha256
          ELSE COALESCE(excluded.sha256, tasks.sha256)
        END,
        verification_status = CASE
          WHEN ? = 1 THEN tasks.verification_status
          ELSE excluded.verification_status
        END
      ''',
      <Object?>[
        record.taskId,
        record.status,
        record.filePath,
        record.eTag,
        record.downloadedBytes,
        record.totalBytes,
        record.resumptionData,
        record.sha256,
        record.verificationStatus.name,
        clearResumption ? 1 : 0,
        preserveVerification ? 1 : 0,
        preserveVerification ? 1 : 0,
      ],
    );
  }

  @override
  void project(WorkVaultTaskRecord record) {
    _database.execute(
      '''
      INSERT INTO tasks (
        task_id, status, file_path, etag, downloaded_bytes, total_bytes,
        resumption_data, sha256, verification_status
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(task_id) DO UPDATE SET
        status = excluded.status,
        file_path = excluded.file_path,
        etag = excluded.etag,
        downloaded_bytes = excluded.downloaded_bytes,
        total_bytes = excluded.total_bytes,
        resumption_data = excluded.resumption_data
      ''',
      <Object?>[
        record.taskId,
        record.status,
        record.filePath,
        record.eTag,
        record.downloadedBytes,
        record.totalBytes,
        record.resumptionData,
        record.sha256,
        record.verificationStatus.name,
      ],
    );
  }

  @override
  void projectAll(List<WorkVaultTaskRecord> records) {
    final List<Object?> ids = <Object?>[
      for (final WorkVaultTaskRecord record in records) record.taskId,
    ];
    if (ids.isEmpty) {
      _database.execute('DELETE FROM tasks');
    } else {
      final String slots = List<String>.filled(ids.length, '?').join(', ');
      _database.execute('DELETE FROM tasks WHERE task_id NOT IN ($slots)', ids);
    }
    for (final WorkVaultTaskRecord record in records) {
      project(record);
    }
  }

  @override
  void recordVerification(
    String taskId,
    Sha256VerificationStatus status, {
    String? sha256,
  }) {
    _database.execute(
      'UPDATE tasks SET sha256 = ?, verification_status = ? WHERE task_id = ?',
      <Object?>[sha256, status.name, taskId],
    );
  }

  @override
  WorkVaultTaskRecord? getTask(String taskId) {
    final ResultSet rows = _database.select(
      'SELECT * FROM tasks WHERE task_id = ?',
      <Object?>[taskId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _read(rows.first);
  }

  @override
  List<WorkVaultTaskRecord> getTasks() {
    final ResultSet rows = _database.select(
      'SELECT * FROM tasks ORDER BY task_id',
    );
    return <WorkVaultTaskRecord>[for (final Row row in rows) _read(row)];
  }

  @override
  void setHandlerHandle(int handle) {
    _database.execute(
      '''
      INSERT INTO meta (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''',
      <Object?>[_handlerKey, handle.toString()],
    );
  }

  @override
  int? handlerHandle() {
    final ResultSet rows = _database.select(
      'SELECT value FROM meta WHERE key = ?',
      <Object?>[_handlerKey],
    );
    if (rows.isEmpty) {
      return null;
    }
    return int.tryParse(rows.first['value']! as String);
  }

  @override
  void close() {
    _database.close();
  }

  void _ensureSchema() {
    _database
      ..execute('PRAGMA busy_timeout = 4000')
      ..execute('''
        CREATE TABLE IF NOT EXISTS tasks (
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
      ..execute('''
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
        ''');
  }

  WorkVaultTaskRecord _read(Row row) {
    final Object? total = row['total_bytes'];
    final Object? resume = row['resumption_data'];
    final Object? digest = row['sha256'];
    final Object? etag = row['etag'];
    Uint8List? bytes;
    if (resume is Uint8List) {
      bytes = Uint8List.fromList(resume);
    } else if (resume is List<int>) {
      bytes = Uint8List.fromList(resume);
    }
    return WorkVaultTaskRecord(
      taskId: row['task_id']! as String,
      status: row['status']! as String,
      filePath: row['file_path']! as String,
      eTag: etag as String?,
      downloadedBytes: row['downloaded_bytes']! as int,
      totalBytes: total as int?,
      resumptionData: bytes,
      sha256: digest as String?,
      verificationStatus: Sha256VerificationStatus.values.byName(
        row['verification_status']! as String,
      ),
    );
  }
}

const String _handlerKey = 'background_handler';
