import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine/work_vault_engine.dart';
import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../models/work_task_config.dart';
import '../persistence/work_vault_database.dart';
import 'desktop_download_worker.dart';

/// [WorkVaultEngine] implementation for desktop platforms (Windows, Linux, macOS).
final class DesktopWorkVaultEngine implements WorkVaultEngine {
  DesktopWorkVaultEngine({
    WorkVaultDatabase? database,
    this.httpClientFactory,
  }) : _databaseOverride = database;

  final WorkVaultDatabase? _databaseOverride;
  final HttpClient Function()? httpClientFactory;
  WorkVaultDatabase? _database;
  WorkVaultObserver? _observer;

  final Map<String, DesktopDownloadWorker> _activeWorkers =
      <String, DesktopDownloadWorker>{};
  final Map<String, WorkTaskConfig> _configs = <String, WorkTaskConfig>{};

  WorkVaultDatabase get _db {
    final WorkVaultDatabase? db = _database;
    if (db == null) {
      throw StateError('DesktopWorkVaultEngine has not been initialized.');
    }
    return db;
  }

  @override
  Future<void> initialize() async {
    if (_database != null) {
      return;
    }

    if (_databaseOverride != null) {
      _database = _databaseOverride;
      return;
    }

    final String dbDir = _defaultDatabaseDirectory();
    final Directory dir = Directory(dbDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final String dbPath = p.join(dbDir, 'work_vault.db');
    _database = WorkVaultDatabase.openFile(dbPath);
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    _observer = observer;
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    final WorkVaultTaskRecord? existing = _db.getTask(config.taskId);
    if (existing != null &&
        (existing.status == TaskStatus.running.name ||
            existing.status == TaskStatus.enqueued.name)) {
      return _snapshotFromRecord(existing);
    }

    _configs[config.taskId] = config;

    final WorkVaultTaskRecord record = WorkVaultTaskRecord(
      taskId: config.taskId,
      status: TaskStatus.enqueued.name,
      filePath: config.destinationPath,
      downloadedBytes: 0,
      verificationStatus: Sha256VerificationStatus.pending,
    );
    _db.upsert(record);

    final TaskSnapshot initialSnapshot = TaskSnapshot(
      taskId: config.taskId,
      status: TaskStatus.enqueued,
    );

    final DesktopDownloadWorker worker = DesktopDownloadWorker(
      config: config,
      database: _db,
      onProgress: (TaskProgress progress) {
        _observer?.onProgress(progress);
      },
      onStatusChanged: (TaskSnapshot snapshot) {
        _observer?.onStatusChanged(snapshot);
      },
      httpClientFactory: httpClientFactory,
    );
    _activeWorkers[config.taskId] = worker;

    // Start worker asynchronously
    unawaited(worker.start());

    return initialSnapshot;
  }

  @override
  Future<void> pause(String taskId) async {
    final DesktopDownloadWorker? worker = _activeWorkers.remove(taskId);
    if (worker != null) {
      await worker.pause();
    } else {
      final WorkVaultTaskRecord? record = _db.getTask(taskId);
      if (record != null) {
        _db.upsert(record.copyWith(status: TaskStatus.paused.name));
      }
    }
  }

  @override
  Future<void> resume(String taskId) async {
    final WorkVaultTaskRecord? record = _db.getTask(taskId);
    if (record == null) {
      return;
    }

    final WorkTaskConfig? config = _configs[taskId];
    if (config == null) {
      // Reconstruct basic config from record if available
      return;
    }

    final DesktopDownloadWorker worker = DesktopDownloadWorker(
      config: config,
      database: _db,
      onProgress: (TaskProgress progress) {
        _observer?.onProgress(progress);
      },
      onStatusChanged: (TaskSnapshot snapshot) {
        _observer?.onStatusChanged(snapshot);
      },
      httpClientFactory: httpClientFactory,
    );
    _activeWorkers[taskId] = worker;
    unawaited(worker.start());
  }

  @override
  Future<void> cancel(String taskId) async {
    final DesktopDownloadWorker? worker = _activeWorkers.remove(taskId);
    if (worker != null) {
      await worker.cancel();
    } else {
      final WorkVaultTaskRecord? record = _db.getTask(taskId);
      if (record != null) {
        _db.upsert(record.copyWith(status: TaskStatus.cancelled.name));
      }
    }
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) async {
    final WorkVaultTaskRecord? record = _db.getTask(taskId);
    if (record == null) {
      return null;
    }
    return _snapshotFromRecord(record);
  }

  @override
  Future<List<TaskSnapshot>> getTasks() async {
    final List<WorkVaultTaskRecord> records = _db.getTasks();
    return records.map(_snapshotFromRecord).toList();
  }

  TaskSnapshot _snapshotFromRecord(WorkVaultTaskRecord record) {
    final TaskStatus status = TaskStatus.values.byName(record.status);
    final double? pct = (record.totalBytes != null && record.totalBytes! > 0)
        ? (record.downloadedBytes / record.totalBytes!) * 100.0
        : null;

    final TaskProgress progress = TaskProgress(
      taskId: record.taskId,
      bytesDownloaded: record.downloadedBytes,
      totalBytes: record.totalBytes,
      bytesPerSecond: 0,
      elapsed: Duration.zero,
      percentage: pct,
    );

    return TaskSnapshot(
      taskId: record.taskId,
      status: status,
      progress: progress,
      failure: status == TaskStatus.failed
          ? TaskFailure(
              taskId: record.taskId,
              code: 'failed',
              message: 'Transfer failed',
              httpStatus: null,
              retryable: false,
            )
          : null,
    );
  }

  String _defaultDatabaseDirectory() {
    if (Platform.isWindows) {
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'work_vault');
      }
    } else if (Platform.isLinux) {
      final String? xdgData = Platform.environment['XDG_DATA_HOME'];
      if (xdgData != null && xdgData.isNotEmpty) {
        return p.join(xdgData, 'work_vault');
      }
      final String? home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, '.local', 'share', 'work_vault');
      }
    } else if (Platform.isMacOS) {
      final String? home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, 'Library', 'Application Support', 'work_vault');
      }
    }
    return Directory.systemTemp.path;
  }
}
