import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../engine/work_vault_engine.dart';
import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../models/work_task_config.dart';
import '../persistence/work_vault_database.dart';
import '../utils/checksum.dart';
import 'range_resume.dart';

/// [WorkVaultEngine] implementation for Web environments.
final class WebWorkVaultEngine implements WorkVaultEngine {
  /// Creates the engine. [database] defaults to an in-memory store.
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
    // The session stays registered so [resume] can continue from its buffer.
    final _WebDownloadSession? session = _sessions[taskId];
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
    if (record == null || record.status != TaskStatus.paused.name) {
      return;
    }

    final WorkTaskConfig? config = _configs[taskId];
    if (config == null) {
      return;
    }

    final _WebDownloadSession session = _sessions[taskId] ??=
        _WebDownloadSession(
          config: config,
          database: _database,
          onProgress: (TaskProgress progress) =>
              _observer?.onProgress(progress),
          onStatusChanged: (TaskSnapshot snapshot) =>
              _observer?.onStatusChanged(snapshot),
        );
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

  /// Response chunks received so far, kept as the browser delivered them.
  final List<Uint8List> _chunks = <Uint8List>[];

  /// Hash of [_chunks], updated as each chunk arrives.
  final StreamingSha256 _hash = StreamingSha256();

  /// Bytes held in [_chunks].
  int get _received => _hash.length;

  void _clearBuffer() {
    _chunks.clear();
    _hash.reset();
  }

  String? _eTag;
  bool _isPaused = false;
  bool _isCancelled = false;
  web.AbortController? _abortController;

  /// Starts the transfer, or continues it from the buffered prefix.
  Future<void> start({bool allowRestart = true}) async {
    _isPaused = false;
    _abortController = web.AbortController();
    final WorkVaultTaskRecord? existing = database.getTask(config.taskId);
    final int? totalBytes = existing?.totalBytes;
    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.running.name,
        filePath: config.destinationPath,
        downloadedBytes: _received,
        totalBytes: totalBytes,
        eTag: _eTag,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );
    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.running,
        progress: TaskProgress(
          taskId: config.taskId,
          bytesDownloaded: _received,
          totalBytes: null,
          bytesPerSecond: 0,
          elapsed: Duration.zero,
          percentage: null,
        ),
      ),
    );

    try {
      final int offset = _received;
      final web.Headers requestHeaders = web.Headers();
      final Map<String, String> headers = <String, String>{
        ...wireHeaders(config.headers),
        ...resumeRequestHeaders(offset, eTag: _eTag),
      };
      // A tearoff of the JS interop `append` does not compile for the web.
      // ignore: unnecessary_lambdas
      headers.forEach((String name, String value) {
        requestHeaders.append(name, value);
      });

      final web.RequestInit init = web.RequestInit(
        method: 'GET',
        headers: requestHeaders,
        signal: _abortController!.signal,
      );

      final web.Response response = await web.window
          .fetch(config.url.toJS, init)
          .toDart;

      if (response.status == 416 && offset > 0 && allowRestart) {
        // The server no longer has the range we hold: start over once.
        _clearBuffer();
        _eTag = null;
        await start(allowRestart: false);
        return;
      }

      if (!response.ok) {
        _fail(
          code: 'http_${response.status}',
          message: 'HTTP error ${response.status}: ${response.statusText}',
          httpStatus: response.status,
        );
        return;
      }

      // 206 continues the buffered prefix. Any other success replaces it.
      final bool continued = response.status == 206 && offset > 0;
      if (!continued) {
        _clearBuffer();
      }
      _eTag = response.headers.get('etag') ?? (continued ? _eTag : null);

      final String? lengthHeader = response.headers.get('content-length');
      final int? bodyLength = lengthHeader != null
          ? int.tryParse(lengthHeader)
          : null;
      final int? totalBytes = continued
          ? parseContentRangeTotal(response.headers.get('content-range')) ??
                (bodyLength != null ? offset + bodyLength : null)
          : bodyLength;

      final web.ReadableStream? body = response.body;
      if (body == null) {
        _fail(code: 'no_body', message: 'Response body is empty');
        return;
      }

      final web.ReadableStreamDefaultReader reader =
          body.getReader() as web.ReadableStreamDefaultReader;
      final Stopwatch stopwatch = Stopwatch()..start();
      int lastReportTimeMs = 0;
      int lastReportedBytes = _received;

      while (!_isPaused && !_isCancelled) {
        final web.ReadableStreamReadResult chunkResult = await reader
            .read()
            .toDart;

        if (chunkResult.done) {
          break;
        }

        final JSUint8Array chunk = chunkResult.value as JSUint8Array;
        final Uint8List chunkBytes = chunk.toDart;
        _chunks.add(chunkBytes);
        _hash.add(chunkBytes);

        final int nowMs = stopwatch.elapsedMilliseconds;
        if (nowMs - lastReportTimeMs >= 200 || _received == totalBytes) {
          final int deltaBytes = _received - lastReportedBytes;
          final int deltaTimeMs = nowMs - lastReportTimeMs;
          final double speed = deltaTimeMs > 0
              ? (deltaBytes * 1000.0) / deltaTimeMs
              : 0.0;
          final double? pct = (totalBytes != null && totalBytes > 0)
              ? (_received / totalBytes) * 100.0
              : null;

          onProgress(
            TaskProgress(
              taskId: config.taskId,
              bytesDownloaded: _received,
              totalBytes: totalBytes,
              bytesPerSecond: speed,
              elapsed: Duration(milliseconds: nowMs),
              percentage: pct,
            ),
          );

          lastReportTimeMs = nowMs;
          lastReportedBytes = _received;
        }
      }

      if (!_isPaused && !_isCancelled) {
        final int length = _received;
        final String sha256Digest = _hash.close();
        final String? expectedSha256 = config.resolvedExpectedSha256;
        if (expectedSha256 != null && expectedSha256 != sha256Digest) {
          // The bytes are not what the caller asked for: do not save them.
          _clearBuffer();
          _fail(
            code: checksumFailureCode,
            message: 'SHA-256 of the file does not match the expected digest.',
            downloadedBytes: length,
            sha256: sha256Digest,
            verificationStatus: Sha256VerificationStatus.mismatch,
          );
          return;
        }

        database.upsert(
          WorkVaultTaskRecord(
            taskId: config.taskId,
            status: TaskStatus.completed.name,
            filePath: config.destinationPath,
            downloadedBytes: length,
            totalBytes: totalBytes ?? length,
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
              bytesDownloaded: length,
              totalBytes: totalBytes ?? length,
              bytesPerSecond: 0,
              elapsed: Duration(milliseconds: stopwatch.elapsedMilliseconds),
              percentage: 100,
            ),
          ),
        );

        // Trigger browser save
        _triggerBrowserDownload(config.destinationPath, _chunks);
        _clearBuffer();
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
        downloadedBytes: _received,
        eTag: _eTag,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );
    onStatusChanged(
      TaskSnapshot(taskId: config.taskId, status: TaskStatus.paused),
    );
  }

  Future<void> cancel() async {
    _isCancelled = true;
    _abortController?.abort();
    _clearBuffer();
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
      TaskSnapshot(taskId: config.taskId, status: TaskStatus.cancelled),
    );
  }

  void _fail({
    required String code,
    required String message,
    int? httpStatus,
    int downloadedBytes = 0,
    String? sha256,
    Sha256VerificationStatus verificationStatus =
        Sha256VerificationStatus.pending,
  }) {
    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.failed.name,
        filePath: config.destinationPath,
        downloadedBytes: downloadedBytes,
        sha256: sha256,
        verificationStatus: verificationStatus,
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

  void _triggerBrowserDownload(String destinationPath, List<Uint8List> chunks) {
    try {
      final String filename = destinationPath.split('/').last.split(r'\').last;
      // The Blob joins the chunks itself, so they are never copied into one
      // Dart buffer.
      final web.Blob blob = web.Blob(
        <web.BlobPart>[
          for (final Uint8List chunk in chunks) chunk.toJS as web.BlobPart,
        ].toJS,
      );
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
