import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// SHA-256 check of a completed download.
enum Sha256VerificationStatus {
  /// The file has not been hashed.
  pending,

  /// The file hash matches the stored digest, or this is the first digest.
  verified,

  /// The file hash differs from the digest already stored for this task.
  mismatch,

  /// The destination file was not on disk when the hash ran.
  missing,
}

/// One persisted download row.
final class WorkVaultTaskRecord {
  /// Creates a stored task row.
  const WorkVaultTaskRecord({
    required this.taskId,
    required this.status,
    required this.filePath,
    required this.downloadedBytes,
    required this.verificationStatus,
    this.eTag,
    this.totalBytes,
    this.resumptionData,
    this.sha256,
  });

  /// Stable task identity.
  final String taskId;

  /// Lifecycle name stored by the host (`enqueued`, `running`, ...).
  final String status;

  /// Absolute destination path.
  final String filePath;

  /// Entity tag from the response, when the host observed one.
  final String? eTag;

  /// Bytes written to [filePath].
  final int downloadedBytes;

  /// Response size when the host knows it.
  final int? totalBytes;

  /// Resume token captured for a paused transfer.
  final Uint8List? resumptionData;

  /// Lowercase hex SHA-256 of [filePath], once computed.
  final String? sha256;

  /// Result of the last integrity hash.
  final Sha256VerificationStatus verificationStatus;

  /// Returns a copy with the given fields replaced.
  WorkVaultTaskRecord copyWith({
    String? status,
    String? filePath,
    String? eTag,
    int? downloadedBytes,
    int? totalBytes,
    Uint8List? resumptionData,
    String? sha256,
    Sha256VerificationStatus? verificationStatus,
    bool clearEtag = false,
    bool clearTotalBytes = false,
    bool clearResumption = false,
    bool clearSha256 = false,
  }) {
    return WorkVaultTaskRecord(
      taskId: taskId,
      status: status ?? this.status,
      filePath: filePath ?? this.filePath,
      eTag: clearEtag ? null : eTag ?? this.eTag,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: clearTotalBytes ? null : totalBytes ?? this.totalBytes,
      resumptionData: clearResumption
          ? null
          : resumptionData ?? this.resumptionData,
      sha256: clearSha256 ? null : sha256 ?? this.sha256,
      verificationStatus: verificationStatus ?? this.verificationStatus,
    );
  }
}

/// SQLite file shared by the UI isolate and a headless background engine.
///
/// The two isolates never exchange a `SendPort`. They open this file.
final class WorkVaultDatabase {
  WorkVaultDatabase._(this._database) {
    _ensureSchema();
  }

  final Database _database;

  /// Opens [path], creating parent directories and the schema.
  factory WorkVaultDatabase.openFile(String path) {
    final Directory parent = File(path).parent;
    parent.createSync(recursive: true);
    return WorkVaultDatabase._(sqlite3.open(path));
  }

  /// Opens a private in-memory database for tests.
  factory WorkVaultDatabase.memory() {
    return WorkVaultDatabase._(sqlite3.openInMemory());
  }

  /// Inserts or updates [record].
  ///
  /// A null [WorkVaultTaskRecord.eTag], total size, resume token, or digest
  /// keeps the value already stored. [clearResumption] drops the token.
  /// [preserveVerification] leaves the stored digest and status untouched,
  /// which progress updates use so a later byte count cannot erase a hash.
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

  /// Writes the native snapshot of [record] over the stored row.
  ///
  /// The host store is the authority for status, bytes, the entity tag, and the resume
  /// token, so a null in [record] clears the stored value instead of keeping it. The
  /// digest and [WorkVaultTaskRecord.verificationStatus] belong to this isolate and are
  /// left to [recordVerification].
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

  /// Replaces every row with [records], the tasks the host still remembers.
  ///
  /// Rows the host no longer reports are deleted, so a reload cannot leave a stale task
  /// behind. Digests already recorded for surviving tasks are kept.
  void projectAll(List<WorkVaultTaskRecord> records) {
    final List<Object?> ids = <Object?>[
      for (final WorkVaultTaskRecord record in records) record.taskId,
    ];
    if (ids.isEmpty) {
      _database.execute('DELETE FROM tasks');
    } else {
      final String slots = List<String>.filled(ids.length, '?').join(', ');
      _database.execute(
        'DELETE FROM tasks WHERE task_id NOT IN ($slots)',
        ids,
      );
    }
    for (final WorkVaultTaskRecord record in records) {
      project(record);
    }
  }

  /// Stores the result of hashing the completed file for [taskId].
  ///
  /// This never changes the status the host decided. [sha256] is the digest the row keeps:
  /// the new one when it matches, or the earlier one when [status] is
  /// [Sha256VerificationStatus.mismatch] or [Sha256VerificationStatus.missing].
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

  /// Returns the row for [taskId].
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

  /// Returns every row, ordered by task id.
  List<WorkVaultTaskRecord> getTasks() {
    final ResultSet rows = _database.select(
      'SELECT * FROM tasks ORDER BY task_id',
    );
    return <WorkVaultTaskRecord>[
      for (final Row row in rows) _read(row),
    ];
  }

  /// Stores the raw callback handle of the background handler.
  void setHandlerHandle(int handle) {
    _database.execute(
      '''
      INSERT INTO meta (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''',
      <Object?>[_handlerKey, handle.toString()],
    );
  }

  /// Raw callback handle previously stored with [setHandlerHandle].
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

  /// Closes the connection.
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
