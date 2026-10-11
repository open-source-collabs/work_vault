import 'dart:io';

import '../desktop/desktop_work_vault_engine.dart';
import 'engine_registry.dart';
import 'pigeon_work_vault_engine.dart';
import 'work_vault_engine.dart';

/// Platform factory on IO platforms (Mobile & Desktop).
WorkVaultEngine createPlatformWorkVaultEngine() {
  final WorkVaultEngine? registered = getRegisteredPlatformEngine();
  if (registered != null) {
    return registered;
  }

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return DesktopWorkVaultEngine();
  }

  return PigeonWorkVaultEngine();
}
