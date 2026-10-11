import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/task_failure.dart';
import '../models/task_progress.dart';
import '../models/task_snapshot.dart';
import '../models/task_status.dart';
import '../models/work_task_config.dart';
import '../persistence/work_vault_database.dart';

/// Worker that performs one resumable HTTP GET download on desktop (Windows/Linux/macOS).
final class DesktopDownloadWorker {
  DesktopDownloadWorker({
    required this.config,
    required this.database,
    required this.onProgress,
    required this.onStatusChanged,
    this.httpClientFactory,
  });

  final WorkTaskConfig config;
  final WorkVaultDatabase database;
  final void Function(TaskProgress progress) onProgress;
  final void Function(TaskSnapshot snapshot) onStatusChanged;
  final HttpClient Function()? httpClientFactory;

  HttpClient? _client;
  StreamSubscription<List<int>>? _streamSubscription;
  RandomAccessFile? _raf;
  bool _isPaused = false;
  bool _isCancelled = false;
  bool _isCompleted = false;

  /// Starts or resumes the download.
  Future<void> start() async {
    final File destinationFile = File(config.destinationPath);
    if (!destinationFile.parent.existsSync()) {
      destinationFile.parent.createSync(recursive: true);
    }

    final int downloadedBytes = destinationFile.existsSync()
        ? destinationFile.lengthSync()
        : 0;

    final WorkVaultTaskRecord? existingRecord = database.getTask(config.taskId);
    final String? eTag = existingRecord?.eTag;
    final int? totalBytes = existingRecord?.totalBytes;

    database.upsert(
      WorkVaultTaskRecord(
        taskId: config.taskId,
        status: TaskStatus.running.name,
        filePath: config.destinationPath,
        eTag: eTag,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );

    onStatusChanged(
      TaskSnapshot(
        taskId: config.taskId,
        status: TaskStatus.running,
        progress: TaskProgress(
          taskId: config.taskId,
          bytesDownloaded: downloadedBytes,
          totalBytes: totalBytes,
          bytesPerSecond: 0,
          elapsed: Duration.zero,
          percentage: totalBytes != null && totalBytes > 0
              ? (downloadedBytes / totalBytes) * 100
              : null,
        ),
      ),
    );

    int attempt = 0;
    while (attempt < config.retry.maxAttempts &&
        !_isPaused &&
        !_isCancelled &&
        !_isCompleted) {
      attempt++;
      try {
        await _performDownload(destinationFile, downloadedBytes, eTag);
        return;
      } catch (error) {
        if (_isPaused || _isCancelled || _isCompleted) {
          return;
        }
        if (attempt >= config.retry.maxAttempts) {
          _fail(
            code: 'transfer_failed',
            message: 'Download failed after $attempt attempts: $error',
            retryable: false,
          );
          return;
        }

        final int backoffMs = (config.retry.initialBackoff.inMilliseconds *
                attempt *
                config.retry.multiplier)
            .toInt()
            .clamp(0, config.retry.maxBackoff.inMilliseconds);
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
      }
    }
  }

  Future<void> _performDownload(
    File destinationFile,
    int initialBytes,
    String? initialEtag,
  ) async {
    _client = httpClientFactory?.call() ?? HttpClient();
    _client!.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
    final HttpClientRequest request = await _client!.getUrl(Uri.parse(config.url));

    for (final MapEntry<String, String> header in config.headers.entries) {
      request.headers.set(header.key, header.value);
    }

    if (initialBytes > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$initialBytes-');
      if (initialEtag != null) {
        request.headers.set(HttpHeaders.ifRangeHeader, initialEtag);
      }
    }

    final HttpClientResponse response = await request.close();
    final int statusCode = response.statusCode;

    if (statusCode != HttpStatus.ok && statusCode != HttpStatus.partialContent) {
      final bool retryable = statusCode >= 500 && statusCode < 600;
      _fail(
        code: 'http_$statusCode',
        message: 'HTTP server returned status $statusCode',
        httpStatus: statusCode,
        retryable: retryable,
      );
      return;
    }

    final String? responseEtag = response.headers.value(HttpHeaders.etagHeader);
    int downloadedBytes = initialBytes;
    int? totalBytes;

    if (statusCode == HttpStatus.partialContent) {
      _raf = destinationFile.openSync(mode: FileMode.append);
      final String? contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null && contentRange.contains('/')) {
        final String totalPart = contentRange.split('/').last;
        totalBytes = int.tryParse(totalPart);
      } else if (response.contentLength >= 0) {
        totalBytes = downloadedBytes + response.contentLength;
      }
    } else {
      _raf = destinationFile.openSync(mode: FileMode.write);
      downloadedBytes = 0;
      if (response.contentLength >= 0) {
        totalBytes = response.contentLength;
      }
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    int lastReportedBytes = downloadedBytes;
    int lastReportTimeMs = 0;

    final Completer<void> completer = Completer<void>();

    _streamSubscription = response.listen(
      (List<int> chunk) {
        if (_isPaused || _isCancelled) {
          return;
        }

        _raf?.writeFromSync(chunk);
        downloadedBytes += chunk.length;

        final int nowMs = stopwatch.elapsedMilliseconds;
        if (nowMs - lastReportTimeMs >= 200 || downloadedBytes == totalBytes) {
          final int deltaBytes = downloadedBytes - lastReportedBytes;
          final int deltaTimeMs = nowMs - lastReportTimeMs;
          final double speed = deltaTimeMs > 0 ? (deltaBytes * 1000.0) / deltaTimeMs : 0.0;

          final double? pct = (totalBytes != null && totalBytes > 0)
              ? (downloadedBytes / totalBytes) * 100.0
              : null;

          final TaskProgress progress = TaskProgress(
            taskId: config.taskId,
            bytesDownloaded: downloadedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
            elapsed: Duration(milliseconds: nowMs),
            percentage: pct,
          );

          onProgress(progress);
          lastReportedBytes = downloadedBytes;
          lastReportTimeMs = nowMs;

          database.upsert(
            WorkVaultTaskRecord(
              taskId: config.taskId,
              status: TaskStatus.running.name,
              filePath: config.destinationPath,
              eTag: responseEtag ?? initialEtag,
              downloadedBytes: downloadedBytes,
              totalBytes: totalBytes,
              verificationStatus: Sha256VerificationStatus.pending,
            ),
            preserveVerification: true,
          );
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () async {
        if (!_isPaused && !_isCancelled) {
          _isCompleted = true;
          try {
            _raf?.closeSync();
            _raf = null;

            final String fileSha256 = await _computeSha256(destinationFile);
            database.upsert(
              WorkVaultTaskRecord(
                taskId: config.taskId,
                status: TaskStatus.completed.name,
                filePath: config.destinationPath,
                eTag: responseEtag ?? initialEtag,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes ?? downloadedBytes,
                sha256: fileSha256,
                verificationStatus: Sha256VerificationStatus.verified,
              ),
            );

            onStatusChanged(
              TaskSnapshot(
                taskId: config.taskId,
                status: TaskStatus.completed,
                progress: TaskProgress(
                  taskId: config.taskId,
                  bytesDownloaded: downloadedBytes,
                  totalBytes: totalBytes ?? downloadedBytes,
                  bytesPerSecond: 0,
                  elapsed: Duration(milliseconds: stopwatch.elapsedMilliseconds),
                  percentage: 100,
                ),
              ),
            );
          } finally {
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        } else {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  /// Requests pausing of the download.
  Future<void> pause() async {
    _isPaused = true;
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _client?.close(force: true);
    _client = null;

    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;

    final WorkVaultTaskRecord? current = database.getTask(config.taskId);
    if (current != null) {
      final Uint8List resumeToken = Uint8List.fromList(
        <int>[...current.downloadedBytes.toString().codeUnits],
      );
      database.upsert(
        current.copyWith(
          status: TaskStatus.paused.name,
          resumptionData: resumeToken,
        ),
      );
      onStatusChanged(
        TaskSnapshot(
          taskId: config.taskId,
          status: TaskStatus.paused,
          progress: TaskProgress(
            taskId: config.taskId,
            bytesDownloaded: current.downloadedBytes,
            totalBytes: current.totalBytes,
            bytesPerSecond: 0,
            elapsed: Duration.zero,
            percentage: current.totalBytes != null && current.totalBytes! > 0
                ? (current.downloadedBytes / current.totalBytes!) * 100
                : null,
          ),
        ),
      );
    }
  }

  /// Cancels the download.
  Future<void> cancel() async {
    _isCancelled = true;
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _client?.close(force: true);
    _client = null;

    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;

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

  void _fail({
    required String code,
    required String message,
    int? httpStatus,
    required bool retryable,
  }) {
    try {
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;

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
          retryable: retryable,
        ),
      ),
    );
  }

  Future<String> _computeSha256(File file) async {
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
