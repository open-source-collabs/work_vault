import '../destination_catalog.dart';

/// Whether this platform can inspect a downloaded file.
const bool supportsFileInfo = false;

/// The browser owns the saved file, so its size is not available.
Future<int?> fileSize(String path) async => null;

/// The browser owns the saved file, so it cannot be hashed here.
Future<String?> sha256OfFile(String path) async => null;

/// On web the destination is a file name, not a path.
String joinDownloadPath(String directory, String fileName) => fileName;

/// The browser has no app file system, so destinations last for the session.
DestinationCatalog platformDestinationCatalog() => MemoryDestinationCatalog();
