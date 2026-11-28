/// Where the app remembers each task's destination file.
///
/// [TaskSnapshot] carries transfer state only, so an app that wants to show a
/// file after a restart keeps its own record of where each task saves to.
abstract interface class DestinationCatalog {
  /// Reads every stored `taskId -> destinationPath` entry from [directory].
  Future<Map<String, String>> load(String directory);

  /// Replaces the stored entries in [directory] with [entries].
  Future<void> save(String directory, Map<String, String> entries);
}

/// Catalog that lives only as long as the process. Used on web and in tests.
final class MemoryDestinationCatalog implements DestinationCatalog {
  /// Creates a catalog holding [initial].
  MemoryDestinationCatalog([Map<String, String>? initial])
    : _entries = <String, String>{...?initial};

  final Map<String, String> _entries;

  /// Current entries, for tests.
  Map<String, String> get entries => Map<String, String>.unmodifiable(_entries);

  @override
  Future<Map<String, String>> load(String directory) async {
    return Map<String, String>.of(_entries);
  }

  @override
  Future<void> save(String directory, Map<String, String> entries) async {
    _entries
      ..clear()
      ..addAll(entries);
  }
}
