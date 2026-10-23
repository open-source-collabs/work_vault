import 'work_vault_database_interface.dart';

/// Fallback stub for opening file database.
WorkVaultDatabase openWorkVaultDatabaseFile(String path) {
  throw UnsupportedError(
    'WorkVaultDatabase.openFile is not supported on this platform.',
  );
}

/// Fallback stub for opening in-memory database.
WorkVaultDatabase openWorkVaultDatabaseMemory() {
  throw UnsupportedError(
    'WorkVaultDatabase.memory is not supported on this platform.',
  );
}
