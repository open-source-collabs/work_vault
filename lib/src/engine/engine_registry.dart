import 'work_vault_engine.dart';

WorkVaultEngine? _registeredEngine;

/// Registers the engine provided by a platform plugin.
void registerPlatformEngine(WorkVaultEngine engine) {
  _registeredEngine = engine;
}

/// Returns the explicitly registered platform engine, if any.
WorkVaultEngine? getRegisteredPlatformEngine() => _registeredEngine;
