import 'dart:typed_data';

import 'work_vault_database_interface.dart';

/// Opens file database on web (mapped to in-memory/web storage).
WorkVaultDatabase openWorkVaultDatabaseFile(String path) {
  return WorkVaultDatabaseWeb();
}

/// Opens in-memory database on web.
WorkVaultDatabase openWorkVaultDatabaseMemory() {
  return WorkVaultDatabaseWeb();
}

/// In-memory/Web-safe implementation of [WorkVaultDatabase].
final class WorkVaultDatabaseWeb implements WorkVaultDatabase {
  final Map<String, WorkVaultTaskRecord> _tasks =
      <String, WorkVaultTaskRecord>{};
  int? _handlerHandle;

  @override
  void upsert(
    WorkVaultTaskRecord record, {
    bool clearResumption = false,
    bool preserveVerification = false,
  }) {
    final WorkVaultTaskRecord? existing = _tasks[record.taskId];
    if (existing == null) {
      _tasks[record.taskId] = record;
      return;
    }

    final Uint8List? resumption = clearResumption
        ? null
        : (record.resumptionData ?? existing.resumptionData);
    final String? sha256 = preserveVerification
        ? existing.sha256
        : (record.sha256 ?? existing.sha256);
    final Sha256VerificationStatus verificationStatus = preserveVerification
        ? existing.verificationStatus
        : record.verificationStatus;

    _tasks[record.taskId] = WorkVaultTaskRecord(
      taskId: record.taskId,
      status: record.status,
      filePath: record.filePath,
      eTag: record.eTag ?? existing.eTag,
      downloadedBytes: record.downloadedBytes,
      totalBytes: record.totalBytes ?? existing.totalBytes,
      resumptionData: resumption,
      sha256: sha256,
      verificationStatus: verificationStatus,
    );
  }

  @override
  void project(WorkVaultTaskRecord record) {
    final WorkVaultTaskRecord? existing = _tasks[record.taskId];
    _tasks[record.taskId] = WorkVaultTaskRecord(
      taskId: record.taskId,
      status: record.status,
      filePath: record.filePath,
      eTag: record.eTag,
      downloadedBytes: record.downloadedBytes,
      totalBytes: record.totalBytes,
      resumptionData: record.resumptionData,
      sha256: existing?.sha256 ?? record.sha256,
      verificationStatus:
          existing?.verificationStatus ?? record.verificationStatus,
    );
  }

  @override
  void projectAll(List<WorkVaultTaskRecord> records) {
    final Set<String> incoming = <String>{
      for (final WorkVaultTaskRecord record in records) record.taskId,
    };
    _tasks.removeWhere((String key, _) => !incoming.contains(key));
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
    final WorkVaultTaskRecord? existing = _tasks[taskId];
    if (existing != null) {
      _tasks[taskId] = existing.copyWith(
        verificationStatus: status,
        sha256: sha256,
      );
    }
  }

  @override
  WorkVaultTaskRecord? getTask(String taskId) {
    return _tasks[taskId];
  }

  @override
  List<WorkVaultTaskRecord> getTasks() {
    final List<WorkVaultTaskRecord> list = _tasks.values.toList();
    list.sort((a, b) => a.taskId.compareTo(b.taskId));
    return list;
  }

  @override
  void setHandlerHandle(int handle) {
    _handlerHandle = handle;
  }

  @override
  int? handlerHandle() {
    return _handlerHandle;
  }

  @override
  void close() {
    // No-op for in-memory web store.
  }
}
