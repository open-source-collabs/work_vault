import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import '../engine/engine_registry.dart';
import 'web_work_vault_engine.dart';

/// Web platform plugin registration for work_vault.
final class WorkVaultWeb {
  /// Registers the Web engine with the Flutter web plugin registrar.
  static void registerWith(Registrar registrar) {
    registerPlatformEngine(WebWorkVaultEngine());
  }
}
