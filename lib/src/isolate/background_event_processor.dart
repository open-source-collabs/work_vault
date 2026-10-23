import 'dart:typed_data';
import 'dart:ui' show CallbackHandle, PluginUtilities;

import '../utils/file_hasher.dart';
export '../utils/file_hasher.dart' show sha256HexOfFile;

import '../persistence/work_vault_database.dart';

/// User callback invoked from the headless engine.
///
/// The function must be a top-level or static function marked
/// `@pragma('vm:entry-point')`. A closure cannot be looked up in a new engine.
typedef WorkVaultBackgroundHandler = Future<void> Function(
  WorkVaultBackgroundEvent event,
);

/// One host event delivered to Dart while the UI engine is not attached.
final class WorkVaultBackgroundEvent {
  /// Creates a background event.
  const WorkVaultBackgroundEvent({
    required this.kind,
    required this.taskId,
    required this.status,
    required this.filePath,
    required this.downloadedBytes,
    required this.databasePath,
    required this.verificationStatus,
    this.totalBytes,
    this.eTag,
    this.resumptionData,
    this.sha256,
  });

  /// `status` or `progress`.
  final String kind;

  /// Stable task identity.
  final String taskId;

  /// Lifecycle name from the host.
  final String status;

  /// Absolute destination path.
  final String filePath;

  /// Bytes the host has saved.
  final int downloadedBytes;

  /// SQLite file that now contains this row.
  final String databasePath;

  /// SHA-256 result after this event was applied.
  final Sha256VerificationStatus verificationStatus;

  /// Response size when known.
  final int? totalBytes;

  /// Entity tag when the host observed one.
  final String? eTag;

  /// Resume token when the host captured one.
  final Uint8List? resumptionData;

  /// Hex digest when a completed file was hashed.
  final String? sha256;
}

/// Applies a host payload to [WorkVaultDatabase] and invokes the saved handler.
final class BackgroundEventProcessor {
  /// Creates a processor.
  ///
  /// [invoke] defaults to the callback-handle lookup. Tests replace it.
  const BackgroundEventProcessor({this.invoke = invokeWorkVaultCallback});

  /// Looks up [handle] and calls it with the event.
  final WorkVaultCallbackInvoker invoke;

  /// Persists [raw] and runs the registered handler.
  Future<WorkVaultBackgroundEvent> apply(
    WorkVaultDatabase database,
    Map<Object?, Object?> raw,
  ) async {
    final String databasePath = raw['databasePath'] as String;
    final String kind = raw['kind'] as String? ?? 'status';
    final WorkVaultTaskRecord record = _recordFrom(raw);
    database.project(record);
    if (kind == 'status' && record.status == 'completed') {
      final _Verification result = await _verify(database, record);
      database.recordVerification(
        record.taskId,
        result.status,
        sha256: result.sha256,
      );
    }
    final WorkVaultTaskRecord stored =
        database.getTask(record.taskId) ?? record;
    final WorkVaultBackgroundEvent event = WorkVaultBackgroundEvent(
      kind: kind,
      taskId: stored.taskId,
      status: stored.status,
      filePath: stored.filePath,
      downloadedBytes: stored.downloadedBytes,
      databasePath: databasePath,
      verificationStatus: stored.verificationStatus,
      totalBytes: stored.totalBytes,
      eTag: stored.eTag,
      resumptionData: stored.resumptionData,
      sha256: stored.sha256,
    );
    final int? handle = _handle(raw) ?? database.handlerHandle();
    if (handle != null && handle != 0) {
      await invoke(handle, event);
    }
    return event;
  }
}

/// Invokes the user function identified by [handle].
typedef WorkVaultCallbackInvoker = Future<void> Function(
  int handle,
  WorkVaultBackgroundEvent event,
);

/// Resolves [handle] in this engine and awaits the user function.
Future<void> invokeWorkVaultCallback(
  int handle,
  WorkVaultBackgroundEvent event,
) async {
  final Function? callback = PluginUtilities.getCallbackFromHandle(
    CallbackHandle.fromRawHandle(handle),
  );
  if (callback == null) {
    return;
  }
  final Object? value = callback(event);
  if (value is Future<Object?>) {
    await value;
  }
}

WorkVaultTaskRecord _recordFrom(Map<Object?, Object?> raw) {
  final Object? total = raw['totalBytes'];
  final Object? resume = raw['resumptionData'];
  Uint8List? bytes;
  if (resume is Uint8List) {
    bytes = Uint8List.fromList(resume);
  } else if (resume is List<int>) {
    bytes = Uint8List.fromList(resume);
  }
  return WorkVaultTaskRecord(
    taskId: raw['taskId']! as String,
    status: raw['status']! as String,
    filePath: raw['filePath']! as String,
    eTag: raw['eTag'] as String?,
    downloadedBytes: (raw['downloadedBytes']! as num).toInt(),
    totalBytes: total is num ? total.toInt() : null,
    resumptionData: bytes,
    sha256: raw['sha256'] as String?,
    verificationStatus: Sha256VerificationStatus.pending,
  );
}

int? _handle(Map<Object?, Object?> raw) {
  final Object? value = raw['callbackHandle'];
  if (value is int) {
    return value;
  }
  return null;
}

/// Hashing result for a completed file. The host status is not part of it.
typedef _Verification = ({Sha256VerificationStatus status, String? sha256});

/// Hashes the completed file and compares it with the digest already on record.
///
/// The host decided this task is complete. This only records whether the bytes on disk
/// still match the digest the host or an earlier hash produced.
Future<_Verification> _verify(
  WorkVaultDatabase database,
  WorkVaultTaskRecord incoming,
) async {
  final String? previous =
      database.getTask(incoming.taskId)?.sha256 ?? incoming.sha256;
  final String? digest = await sha256HexOfFile(incoming.filePath);
  if (digest == null) {
    return (status: Sha256VerificationStatus.missing, sha256: previous);
  }
  if (previous != null && previous != digest) {
    return (status: Sha256VerificationStatus.mismatch, sha256: previous);
  }
  return (status: Sha256VerificationStatus.verified, sha256: digest);
}
