import 'desktop_work_vault_engine.dart';
import '../engine/engine_registry.dart';

/// Linux platform plugin registration for work_vault.
final class WorkVaultLinux {
  /// Registers the Linux desktop engine.
  static void registerWith() {
    registerPlatformEngine(DesktopWorkVaultEngine());
  }
}
