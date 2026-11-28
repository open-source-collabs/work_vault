import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../destination_catalog.dart';

/// Whether this platform can inspect a downloaded file.
const bool supportsFileInfo = true;

/// Size of the file at [path] in bytes, or null when it is not on disk.
Future<int?> fileSize(String path) async {
  final FileStat stat = await FileStat.stat(path);
  if (stat.type != FileSystemEntityType.file) {
    return null;
  }
  return stat.size;
}

/// Lowercase hex SHA-256 of the file at [path], or null when it is not on disk.
///
/// The file is streamed, so large downloads are not loaded into memory.
Future<String?> sha256OfFile(String path) async {
  final File file = File(path);
  if (!await file.exists()) {
    return null;
  }
  final Digest digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Absolute destination for [fileName] inside [directory].
String joinDownloadPath(String directory, String fileName) {
  return '$directory${Platform.pathSeparator}$fileName';
}

/// Catalog stored as a small JSON file next to the downloads.
DestinationCatalog platformDestinationCatalog() =>
    const _FileDestinationCatalog();

final class _FileDestinationCatalog implements DestinationCatalog {
  const _FileDestinationCatalog();

  static const String _fileName = '.work_vault_example_destinations.json';

  File _file(String directory) =>
      File('$directory${Platform.pathSeparator}$_fileName');

  @override
  Future<Map<String, String>> load(String directory) async {
    final File file = _file(directory);
    if (!await file.exists()) {
      return <String, String>{};
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      // A damaged catalog only hides file details; start over.
      return <String, String>{};
    }
    if (decoded is! Map<String, Object?>) {
      return <String, String>{};
    }
    return <String, String>{
      for (final MapEntry<String, Object?> entry in decoded.entries)
        if (entry.value is String) entry.key: entry.value! as String,
    };
  }

  @override
  Future<void> save(String directory, Map<String, String> entries) async {
    final File file = _file(directory);
    await file.parent.create(recursive: true);
    // Write a sibling file, then rename over the old one, so a crash mid-write
    // never leaves a truncated catalog.
    final File temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(entries), flush: true);
    await temp.rename(file.path);
  }
}
