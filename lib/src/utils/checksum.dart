import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Local request header that carries an expected SHA-256 digest as hex.
///
/// The Android host reads it from the task headers. Every engine strips it,
/// together with [expectedMd5Header], before a request is sent.
const String expectedSha256Header = 'X-Work-Vault-Sha256';

/// Local request header that carries an expected MD5 digest as hex.
///
/// Only the Android host checks it. It is stripped like [expectedSha256Header].
const String expectedMd5Header = 'X-Work-Vault-Md5';

/// Failure code for a completed file whose digest does not match.
const String checksumFailureCode = 'checksum';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Lowercase [value] without surrounding whitespace, or null when it is not
/// 64 hex characters.
String? normalizeSha256Hex(String? value) {
  if (value == null) {
    return null;
  }
  final String hex = value.trim().toLowerCase();
  return _sha256Hex.hasMatch(hex) ? hex : null;
}

/// Value of the header called [name] in [headers], ignoring the name's case.
String? headerValue(Map<String, String> headers, String name) {
  final String lower = name.toLowerCase();
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) {
      return entry.value;
    }
  }
  return null;
}

/// [headers] without the local checksum headers, which must not reach a server.
Map<String, String> wireHeaders(Map<String, String> headers) {
  final String sha = expectedSha256Header.toLowerCase();
  final String md5 = expectedMd5Header.toLowerCase();
  return <String, String>{
    for (final MapEntry<String, String> entry in headers.entries)
      if (entry.key.toLowerCase() != sha && entry.key.toLowerCase() != md5)
        entry.key: entry.value,
  };
}

/// SHA-256 fed one chunk at a time, so the whole input is never needed at once.
final class StreamingSha256 {
  /// Starts an empty hash.
  StreamingSha256() {
    reset();
  }

  late _DigestSink _sink;
  late ByteConversionSink _input;

  /// Bytes added since the last [reset].
  int get length => _length;
  int _length = 0;

  /// Discards everything added so far.
  void reset() {
    _sink = _DigestSink();
    _input = sha256.startChunkedConversion(_sink);
    _length = 0;
  }

  /// Adds [chunk] to the hash.
  void add(Uint8List chunk) {
    _input.add(chunk);
    _length += chunk.length;
  }

  /// Finishes the hash and returns it as lowercase hex.
  ///
  /// The hash cannot be added to afterwards until [reset] is called.
  String close() {
    _input.close();
    return _sink.value.toString();
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) {
    _value = data;
  }

  @override
  void close() {}
}
