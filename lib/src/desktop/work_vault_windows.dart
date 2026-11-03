import '../engine/engine_registry.dart';
import 'desktop_work_vault_engine.dart';

/// Windows platform plugin registration for work_vault.
final class WorkVaultWindows {
  /// Registers the Windows desktop engine.
  static void registerWith() {
    registerPlatformEngine(DesktopWorkVaultEngine());
  }
}
