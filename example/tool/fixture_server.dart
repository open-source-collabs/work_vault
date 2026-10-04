import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Local HTTPS fixture for the Android emulator.
///
/// The emulator reaches this process at `https://10.0.2.2:<port>`. The debug
/// app trusts [certificatePem].
class FixtureServer {
  FixtureServer._(this._server, this.payload, this.sha256, this.certificatePem);

  final HttpServer _server;
  final Uint8List payload;

  /// Lowercase hex SHA-256 of [payload].
  final String sha256;

  /// PEM certificate the debug network security config trusts.
  final List<int> certificatePem;

  bool _surviveReleased = false;
  bool _dropConsumed = false;

  int get port => _server.port;

  /// Serves [payload] until [close].
  static Future<FixtureServer> bind({
    int port = 8443,
    String certificatePath = 'tool/certs/cert.pem',
    String keyPath = 'tool/certs/key.pem',
  }) async {
    final List<int> certificate = await File(certificatePath).readAsBytes();
    final List<int> key = await File(keyPath).readAsBytes();
    final SecurityContext context = SecurityContext()
      ..useCertificateChainBytes(certificate)
      ..usePrivateKeyBytes(key);
    final Uint8List payload = Uint8List(160 * 1024);
    for (var index = 0; index < payload.length; index++) {
      payload[index] = (index * 31 + 17) & 0xff;
    }
    final HttpServer server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      context,
    );
    final FixtureServer fixture = FixtureServer._(
      server,
      payload,
      crypto.sha256.convert(payload).toString(),
      certificate,
    );
    server.listen(
      fixture._handle,
      onError: (Object error, StackTrace stack) {
        stderr.writeln('Fixture connection failed: $error');
      },
    );
    return fixture;
  }

  /// Lets the survive route finish. Calls before this wait without a body.
  void releaseSurvive() {
    _surviveReleased = true;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      switch (request.uri.path) {
        case '/blob':
          await _send(request, payload, drip: false);
        case '/drip':
          await _send(request, payload, drip: true);
        case '/headless':
          await _send(request, payload, drip: true);
        case '/survive':
          await _survive(request);
        case '/slow':
          await _send(
            request,
            payload,
            drip: true,
            chunkBytes:
                int.tryParse(request.uri.queryParameters['chunk'] ?? '') ??
                4 * 1024,
            gap: Duration(
              milliseconds:
                  int.tryParse(request.uri.queryParameters['gapMs'] ?? '') ??
                  500,
            ),
          );
        case '/drop':
          await _drop(request);
        case '/short':
          await _send(
            request,
            Uint8List.sublistView(payload, 0, payload.length ~/ 2),
            drip: false,
          );
        case '/missing':
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    } on Object catch (error) {
      stderr.writeln('Fixture request failed: $error');
      try {
        await request.response.close();
      } on Object {
        // The client already went away.
      }
    }
  }

  Future<void> _survive(HttpRequest request) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!_surviveReleased && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_surviveReleased) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    await _send(
      request,
      payload,
      drip: true,
      chunkBytes: 4 * 1024,
      gap: const Duration(milliseconds: 500),
    );
  }

  Future<void> _drop(HttpRequest request) async {
    final _ByteRange? range = _range(request, payload.length);
    if (_dropConsumed || (range != null && range.start > 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _send(request, payload, drip: false);
      return;
    }
    _dropConsumed = true;
    final HttpResponse response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    response.headers.set(HttpHeaders.contentLengthHeader, payload.length);
    response.headers.set('accept-ranges', 'bytes');
    response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
    response.bufferOutput = false;
    response.add(Uint8List.sublistView(payload, 0, 24 * 1024));
    await response.flush();
    final Socket socket = await response.detachSocket();
    socket.destroy();
  }

  Future<void> _send(
    HttpRequest request,
    Uint8List body, {
    required bool drip,
    int chunkBytes = 8 * 1024,
    Duration gap = const Duration(milliseconds: 400),
  }) async {
    final Uint8List whole = body;
    final _ByteRange? range = _range(request, whole.length);
    final int start = range?.start ?? 0;
    final int end = range?.end ?? whole.length - 1;
    if (start >= whole.length) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${whole.length}',
      );
      await request.response.close();
      return;
    }
    final Uint8List slice = Uint8List.sublistView(whole, start, end + 1);
    final HttpResponse response = request.response;
    final bool partial = start > 0 || end < whole.length - 1;
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    response.headers.set(HttpHeaders.contentLengthHeader, slice.length);
    response.headers.set('accept-ranges', 'bytes');
    response.headers.set(HttpHeaders.etagHeader, '"fixture-v1"');
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${whole.length}',
      );
    }
    response.bufferOutput = false;
    if (!drip) {
      response.add(slice);
      await response.close();
      return;
    }
    for (var offset = 0; offset < slice.length; offset += chunkBytes) {
      final int next = offset + chunkBytes < slice.length
          ? offset + chunkBytes
          : slice.length;
      response.add(Uint8List.sublistView(slice, offset, next));
      await response.flush();
      if (next < slice.length) {
        await Future<void>.delayed(gap);
      }
    }
    await response.close();
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}

_ByteRange? _range(HttpRequest request, int total) {
  final String? header = request.headers.value(HttpHeaders.rangeHeader);
  if (header == null) {
    return null;
  }
  final RegExpMatch? match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
  if (match == null) {
    return null;
  }
  final int start = int.parse(match.group(1)!);
  final String endText = match.group(2)!;
  final int end = endText.isEmpty ? total - 1 : int.parse(endText);
  if (end < start) {
    return _ByteRange(start, start);
  }
  return _ByteRange(start, end >= total ? total - 1 : end);
}
