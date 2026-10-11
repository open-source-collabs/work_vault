import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streams [path] through SHA-256 and returns a lowercase hex digest on IO platforms.
Future<String?> sha256HexOfFile(String path) async {
  final File file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
