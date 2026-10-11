import '../engine/engine_registry.dart';
import 'desktop_work_vault_engine.dart';

/// macOS platform plugin registration for work_vault.
final class WorkVaultMacOS {
  /// Registers the desktop engine for macOS.
  static void registerWith() {
    registerPlatformEngine(DesktopWorkVaultEngine());
  }
}
