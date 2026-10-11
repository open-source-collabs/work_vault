import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

import '../engine/work_vault_engine.dart';
import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../models/work_task_config.dart';
import '../persistence/work_vault_database.dart';

/// [WorkVaultEngine] implementation for Web environments.
final class WebWorkVaultEngine implements WorkVaultEngine {
  WebWorkVaultEngine({WorkVaultDatabase? database})
      : _database = database ?? WorkVaultDatabase.memory();

  final WorkVaultDatabase _database;
  WorkVaultObserver? _observer;

  final Map<String, _WebDownloadSession> _sessions =
      <String, _WebDownloadSession>{};
  final Map<String, WorkTaskConfig> _configs = <String, WorkTaskConfig>{};

  @override
  Future<void> initialize() async {
    // Database is in-memory / web-backed.
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    _observer = observer;
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    final WorkVaultTaskRecord? existing = _database.getTask(config.taskId);
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
    _database.upsert(record);

    final TaskSnapshot initialSnapshot = TaskSnapshot(
      taskId: config.taskId,
      status: TaskStatus.enqueued,
    );

    final _WebDownloadSession session = _WebDownloadSession(
      config: config,
      database: _database,
      onProgress: (TaskProgress progress) => _observer?.onProgress(progress),
      onStatusChanged: (TaskSnapshot snapshot) =>
          _observer?.onStatusChanged(snapshot),
    );
    _sessions[config.taskId] = session;

    unawaited(session.start());

    return initialSnapshot;
  }

  @override
  Future<void> pause(String taskId) async {
    final _WebDownloadSession? session = _sessions.remove(taskId);
    if (session != null) {
      await session.pause();
    } else {
      final WorkVaultTaskRecord? record = _database.getTask(taskId);
      if (record != null) {
        _database.upsert(record.copyWith(status: TaskStatus.paused.name));
      }
    }
  }

  @override
  Future<void> resume(String taskId) async {
    final WorkVaultTaskRecord? record = _database.getTask(taskId);
    if (record == null) {
      return;
    }

    final WorkTaskConfig? config = _configs[taskId];
    if (config == null) {
      return;
    }

    final _WebDownloadSession session = _WebDownloadSession(
      config: config,
      database: _database,
      onProgress: (TaskProgress progress) => _observer?.onProgress(progress),
      onStatusChanged: (TaskSnapshot snapshot) =>
          _observer?.onStatusChanged(snapshot),
    );
    _sessions[taskId] = session;
    unawaited(session.start());
  }

  @override
  Future<void> cancel(String taskId) async {
    final _WebDownloadSession? session = _sessions.remove(taskId);
    if (session != null) {
      await session.cancel();
    } else {
      final WorkVaultTaskRecord? record = _database.getTask(taskId);
      if (record != null) {
        _database.upsert(record.copyWith(status: TaskStatus.cancelled.name));
      }
    }
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) async {
    final WorkVaultTaskRecord? record = _database.getTask(taskId);
    if (record == null) {
      return null;
    }
    return _snapshotFromRecord(record);
  }

  @override
  Future<List<TaskSnapshot>> getTasks() async {
    final List<WorkVaultTaskRecord> records = _database.getTasks();
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
}

final class _WebDownloadSession {
  _WebDownloadSession({
    required this.config,
    required this.database,
    required this.onProgress,
    required this.onStatusChanged,
  });

  final WorkTaskConfig config;
  final WorkVaultDatabase database;
  final void Function(TaskProgress progress) onProgress;
  final void Function(TaskSnapshot snapshot) onStatusChanged;

  final List<int> _buffer = <int>[];
  bool _isPaused = false;
  bool _isCancelled = false;
  web.AbortController? _abortController;

  Future<void> start() async {
    _abortController = web.AbortController();
    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.running,
        progress: TaskProgress(
          taskId: config.taskId,
          bytesDownloaded: _buffer.length,
          totalBytes: null,
          bytesPerSecond: 0,
          elapsed: Duration.zero,
          percentage: null,
        ),
      ),
    );

    try {
      final web.RequestInit init = web.RequestInit(
        method: 'GET',
        signal: _abortController!.signal,
      );

      final web.Response response =
          await web.window.fetch(config.url.toJS, init).toDart;

      if (!response.ok) {
        _fail(
          code: 'http_${response.status}',
          message: 'HTTP error ${response.status}: ${response.statusText}',
          httpStatus: response.status,
        );
        return;
      }

      final String? lengthHeader = response.headers.get('content-length');
      final int? totalBytes =
          lengthHeader != null ? int.tryParse(lengthHeader) : null;

      final web.ReadableStream? body = response.body;
      if (body == null) {
        _fail(code: 'no_body', message: 'Response body is empty');
        return;
      }

      final web.ReadableStreamDefaultReader reader =
          body.getReader() as web.ReadableStreamDefaultReader;
      final Stopwatch stopwatch = Stopwatch()..start();
      int lastReportTimeMs = 0;
      int lastReportedBytes = 0;

      while (!_isPaused && !_isCancelled) {
        final web.ReadableStreamReadResult chunkResult =
            await reader.read().toDart;

        if (chunkResult.done) {
          break;
        }

        final JSUint8Array chunk = chunkResult.value as JSUint8Array;
        final Uint8List chunkBytes = chunk.toDart;
        _buffer.addAll(chunkBytes);

        final int nowMs = stopwatch.elapsedMilliseconds;
        if (nowMs - lastReportTimeMs >= 200 || _buffer.length == totalBytes) {
          final int deltaBytes = _buffer.length - lastReportedBytes;
          final int deltaTimeMs = nowMs - lastReportTimeMs;
          final double speed =
              deltaTimeMs > 0 ? (deltaBytes * 1000.0) / deltaTimeMs : 0.0;
          final double? pct = (totalBytes != null && totalBytes > 0)
              ? (_buffer.length / totalBytes) * 100.0
              : null;

          onProgress(
            TaskProgress(
              taskId: config.taskId,
              bytesDownloaded: _buffer.length,
              totalBytes: totalBytes,
              bytesPerSecond: speed,
              elapsed: Duration(milliseconds: nowMs),
              percentage: pct,
            ),
          );

          lastReportTimeMs = nowMs;
          lastReportedBytes = _buffer.length;
        }
      }

      if (!_isPaused && !_isCancelled) {
        final Uint8List allBytes = Uint8List.fromList(_buffer);
        final String sha256Digest = sha256.convert(allBytes).toString();

        database.upsert(
          WorkVaultTaskRecord(
            taskId: config.taskId,
            status: TaskStatus.completed.name,
            filePath: config.destinationPath,
            downloadedBytes: allBytes.length,
            totalBytes: totalBytes ?? allBytes.length,
            sha256: sha256Digest,
            verificationStatus: Sha256VerificationStatus.verified,
          ),
        );

        onStatusChanged(
          TaskSnapshot(
            taskId: config.taskId,
            status: TaskStatus.completed,
            progress: TaskProgress(
              taskId: config.taskId,
              bytesDownloaded: allBytes.length,
              totalBytes: totalBytes ?? allBytes.length,
              bytesPerSecond: 0,
              elapsed: Duration(milliseconds: stopwatch.elapsedMilliseconds),
              percentage: 100,
            ),
          ),
        );

        // Trigger browser save
        _triggerBrowserDownload(config.destinationPath, allBytes);
      }
    } catch (error) {
      if (!_isPaused && !_isCancelled) {
        _fail(code: 'network_error', message: error.toString());
      }
    }
  }

  Future<void> pause() async {
    _isPaused = true;
    _abortController?.abort();
    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.paused.name,
        filePath: config.destinationPath,
        downloadedBytes: _buffer.length,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );
    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.paused,
      ),
    );
  }

  Future<void> cancel() async {
    _isCancelled = true;
    _abortController?.abort();
    _buffer.clear();
    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.cancelled.name,
        filePath: config.destinationPath,
        downloadedBytes: 0,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
      clearResumption: true,
    );
    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.cancelled,
      ),
    );
  }

  void _fail({required String code, required String message, int? httpStatus}) {
    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.failed.name,
        filePath: config.destinationPath,
        downloadedBytes: 0,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );
    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.failed,
        failure: TaskFailure(
          taskId: config.taskId,
          code: code,
          message: message,
          httpStatus: httpStatus,
          retryable: false,
        ),
      ),
    );
  }

  void _triggerBrowserDownload(String destinationPath, Uint8List bytes) {
    try {
      final String filename = destinationPath.split('/').last.split(r'\').last;
      final web.Blob blob = web.Blob(<web.BlobPart>[bytes.toJS as web.BlobPart].toJS);
      final String url = web.URL.createObjectURL(blob);
      final web.HTMLAnchorElement anchor =
          web.document.createElement('a') as web.HTMLAnchorElement;
      anchor.href = url;
      anchor.download = filename.isEmpty ? 'download.bin' : filename;
      web.document.body?.appendChild(anchor);
      anchor.click();
      anchor.remove();
      web.URL.revokeObjectURL(url);
    } catch (_) {}
  }
}
