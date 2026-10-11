import 'dart:typed_data';

import 'work_vault_database_stub.dart'
    if (dart.library.io) 'work_vault_database_io.dart'
    if (dart.library.js_interop) 'work_vault_database_web.dart';

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

/// Storage interface shared by vault isolates and engines.
abstract interface class WorkVaultDatabase {
  /// Opens [path], creating parent directories and the schema.
  factory WorkVaultDatabase.openFile(String path) =>
      openWorkVaultDatabaseFile(path);

  /// Opens a private in-memory database for tests.
  factory WorkVaultDatabase.memory() => openWorkVaultDatabaseMemory();

  /// Inserts or updates [record].
  void upsert(
    WorkVaultTaskRecord record, {
    bool clearResumption = false,
    bool preserveVerification = false,
  });

  /// Writes the native snapshot of [record] over the stored row.
  void project(WorkVaultTaskRecord record);

  /// Replaces every row with [records], the tasks the host still remembers.
  void projectAll(List<WorkVaultTaskRecord> records);

  /// Stores the result of hashing the completed file for [taskId].
  void recordVerification(
    String taskId,
    Sha256VerificationStatus status, {
    String? sha256,
  });

  /// Returns the row for [taskId].
  WorkVaultTaskRecord? getTask(String taskId);

  /// Returns every row, ordered by task id.
  List<WorkVaultTaskRecord> getTasks();

  /// Stores the raw callback handle of the background handler.
  void setHandlerHandle(int handle);

  /// Raw callback handle previously stored with [setHandlerHandle].
  int? handlerHandle();

  /// Closes the connection.
  void close();
}
