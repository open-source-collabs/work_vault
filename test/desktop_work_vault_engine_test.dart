import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/desktop/desktop_work_vault_engine.dart';
import 'package:work_vault/src/engine/work_vault_engine.dart';
import 'package:work_vault/src/models/task_progress.dart';
import 'package:work_vault/src/models/task_snapshot.dart';
import 'package:work_vault/src/models/task_status.dart';
import 'package:work_vault/src/models/work_task_config.dart';
import 'package:work_vault/src/persistence/work_vault_database.dart';

import 'support.dart';

void main() {
  late Directory tempDir;
  late WorkVaultDatabase database;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('work_vault_desktop_test_');
    database = WorkVaultDatabase.memory();
  });

  tearDown(() async {
    database.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('enqueues and completes download with chunked streaming and SHA-256 verification', () async {
    final List<int> payload = utf8.encode('Hello, desktop download world! This is a test chunk.');
    final FakeHttpClient fakeClient = FakeHttpClient(
      onGetUrl: (Uri uri) {
        return FakeHttpClientRequest(
          response: FakeHttpClientResponse(
            statusCode: HttpStatus.ok,
            contentLength: payload.length,
            stream: Stream<List<int>>.fromIterable(<List<int>>[
              payload.sublist(0, 20),
              payload.sublist(20),
            ]),
          ),
        );
      },
    );

    final DesktopWorkVaultEngine engine = DesktopWorkVaultEngine(
      database: database,
      httpClientFactory: () => fakeClient,
    );
    await engine.initialize();

    final String destinationPath = '${tempDir.path}/download.bin';
    final Completer<void> completedCompleter = Completer<void>();
    final List<TaskProgress> progressSamples = <TaskProgress>[];

    engine.setObserver(_TestObserver(
      onProgressCallback: (TaskProgress p) => progressSamples.add(p),
      onStatusCallback: (TaskSnapshot s) {
        if (s.status == TaskStatus.completed) {
          if (!completedCompleter.isCompleted) {
            completedCompleter.complete();
          }
        }
      },
    ));

    final WorkTaskConfig config = sampleConfig(
      taskId: 'desktop-task-1',
      url: 'https://example.com/file.bin',
      destinationPath: destinationPath,
    );

    final TaskSnapshot initial = await engine.enqueue(config);
    expect(initial.status, TaskStatus.enqueued);

    await completedCompleter.future.timeout(const Duration(seconds: 3));

    final File downloaded = File(destinationPath);
    expect(downloaded.existsSync(), isTrue);
    expect(downloaded.readAsStringSync(), 'Hello, desktop download world! This is a test chunk.');

    final WorkVaultTaskRecord? stored = database.getTask('desktop-task-1');
    expect(stored, isNotNull);
    expect(stored?.status, TaskStatus.completed.name);
    expect(stored?.verificationStatus, Sha256VerificationStatus.verified);
    expect(stored?.sha256, isNotNull);
  });

  test('resumes partial download using Range header and appends chunks', () async {
    final String destinationPath = '${tempDir.path}/resumed.bin';
    final File existing = File(destinationPath);
    existing.writeAsStringSync('Part1_');

    String? capturedRangeHeader;

    final FakeHttpClient fakeClient = FakeHttpClient(
      onGetUrl: (Uri uri) {
        final FakeHttpClientRequest request = FakeHttpClientRequest();
        request.onClose = () {
          capturedRangeHeader = request.headers.value(HttpHeaders.rangeHeader);
          return FakeHttpClientResponse(
            statusCode: HttpStatus.partialContent,
            contentLength: 6,
            headersMap: <String, String>{
              HttpHeaders.contentRangeHeader: 'bytes 6-11/12',
            },
            stream: Stream<List<int>>.value(utf8.encode('Part2!')),
          );
        };
        return request;
      },
    );

    final DesktopWorkVaultEngine engine = DesktopWorkVaultEngine(
      database: database,
      httpClientFactory: () => fakeClient,
    );
    await engine.initialize();

    final Completer<void> completedCompleter = Completer<void>();
    engine.setObserver(_TestObserver(
      onStatusCallback: (TaskSnapshot s) {
        if (s.status == TaskStatus.completed) {
          if (!completedCompleter.isCompleted) {
            completedCompleter.complete();
          }
        }
      },
    ));

    final WorkTaskConfig config = sampleConfig(
      taskId: 'resumed-task',
      url: 'https://example.com/resumed.bin',
      destinationPath: destinationPath,
    );

    await engine.enqueue(config);
    await completedCompleter.future.timeout(const Duration(seconds: 3));

    expect(capturedRangeHeader, 'bytes=6-');
    expect(existing.readAsStringSync(), 'Part1_Part2!');

    final WorkVaultTaskRecord? stored = database.getTask('resumed-task');
    expect(stored?.verificationStatus, Sha256VerificationStatus.verified);
  });

  test('cancels a task and updates database', () async {
    final String destinationPath = '${tempDir.path}/cancelled.bin';
    final DesktopWorkVaultEngine engine = DesktopWorkVaultEngine(
      database: database,
      httpClientFactory: () => FakeHttpClient(
        onGetUrl: (Uri uri) => FakeHttpClientRequest(
          response: FakeHttpClientResponse(
            statusCode: HttpStatus.ok,
            stream: Stream<List<int>>.periodic(
              const Duration(milliseconds: 100),
              (int i) => <int>[i],
            ),
          ),
        ),
      ),
    );
    await engine.initialize();

    final WorkTaskConfig config = sampleConfig(
      taskId: 'cancel-task',
      destinationPath: destinationPath,
    );

    await engine.enqueue(config);
    await engine.cancel('cancel-task');

    final TaskSnapshot? snapshot = await engine.getTask('cancel-task');
    expect(snapshot?.status, TaskStatus.cancelled);
  });

  test('pauses a task and records paused status in database', () async {
    final String destinationPath = '${tempDir.path}/paused.bin';
    final DesktopWorkVaultEngine engine = DesktopWorkVaultEngine(
      database: database,
      httpClientFactory: () => FakeHttpClient(
        onGetUrl: (Uri uri) => FakeHttpClientRequest(
          response: FakeHttpClientResponse(
            statusCode: HttpStatus.ok,
            stream: Stream<List<int>>.periodic(
              const Duration(milliseconds: 100),
              (int i) => <int>[i],
            ),
          ),
        ),
      ),
    );
    await engine.initialize();

    final WorkTaskConfig config = sampleConfig(
      taskId: 'pause-task',
      destinationPath: destinationPath,
    );

    await engine.enqueue(config);
    await engine.pause('pause-task');

    final TaskSnapshot? snapshot = await engine.getTask('pause-task');
    expect(snapshot?.status, TaskStatus.paused);
  });
}

class _TestObserver implements WorkVaultObserver {
  _TestObserver({this.onProgressCallback, this.onStatusCallback});

  final void Function(TaskProgress)? onProgressCallback;
  final void Function(TaskSnapshot)? onStatusCallback;

  @override
  void onProgress(TaskProgress progress) {
    onProgressCallback?.call(progress);
  }

  @override
  void onStatusChanged(TaskSnapshot snapshot) {
    onStatusCallback?.call(snapshot);
  }
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient({this.onGetUrl});

  final FakeHttpClientRequest Function(Uri uri)? onGetUrl;

  @override
  bool Function(X509Certificate cert, String host, int port)? badCertificateCallback;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (onGetUrl != null) {
      return onGetUrl!(url);
    }
    return FakeHttpClientRequest();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest({this.response, this.onClose});

  final FakeHttpClientResponse? response;
  FakeHttpClientResponse Function()? onClose;
  final FakeHttpHeaders _headers = FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async {
    if (onClose != null) {
      return onClose!();
    }
    return response ?? FakeHttpClientResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeHttpClientResponse({
    this.statusCode = HttpStatus.ok,
    this.contentLength = 0,
    this.headersMap = const <String, String>{},
    Stream<List<int>>? stream,
  }) : _stream = stream ?? const Stream<List<int>>.empty();

  @override
  final int statusCode;

  @override
  final int contentLength;

  final Map<String, String> headersMap;
  final Stream<List<int>> _stream;

  @override
  HttpHeaders get headers => FakeHttpHeaders(headersMap);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpHeaders implements HttpHeaders {
  FakeHttpHeaders([Map<String, String>? initial])
      : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) {
    return _values[name.toLowerCase()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
