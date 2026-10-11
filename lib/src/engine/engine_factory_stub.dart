import 'pigeon_work_vault_engine.dart';
import 'work_vault_engine.dart';

/// Fallback factory for platform engine.
WorkVaultEngine createPlatformWorkVaultEngine() {
  return PigeonWorkVaultEngine();
}
