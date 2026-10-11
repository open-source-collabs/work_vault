import '../web/web_work_vault_engine.dart';
import 'engine_registry.dart';
import 'work_vault_engine.dart';

/// Platform factory on Web.
WorkVaultEngine createPlatformWorkVaultEngine() {
  final WorkVaultEngine? registered = getRegisteredPlatformEngine();
  if (registered != null) {
    return registered;
  }
  return WebWorkVaultEngine();
}
