import 'dart:async';
import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../persistence/work_vault_database.dart';
import 'background_event_processor.dart';

/// Method channel shared by the UI engine and a headless background engine.
const String workVaultBackgroundChannel = 'com.workvault.work_vault/background';

/// Library URI the host passes to `DartEntrypoint` / `FlutterEngine.run`.
const String workVaultBackgroundLibrary =
    'package:work_vault/src/isolate/background_entry_point.dart';

/// Entrypoint function name. The host looks this up in [workVaultBackgroundLibrary].
const String workVaultBackgroundEntrypoint = 'workVaultBackgroundMain';

/// Headless entry point.
///
/// The host starts a `FlutterEngine` with this function when a background
/// worker or `URLSession` wakes the process and no UI engine is attached.
/// Events arrive on [workVaultBackgroundChannel]. There is no
/// `IsolateNameServer` port.
@pragma('vm:entry-point')
void workVaultBackgroundMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel(workVaultBackgroundChannel);
  final _HeadlessBackgroundBinding binding = _HeadlessBackgroundBinding();
  channel.setMethodCallHandler(binding.handle);
  unawaited(channel.invokeMethod<void>('ready'));
}

/// Persists [handler] and tells the host its callback handle.
///
/// [handler] must be a top-level or static function marked
/// `@pragma('vm:entry-point')`. The handle is an integer into the app
/// snapshot, so a later headless engine can call the same function.
Future<void> registerWorkVaultBackgroundHandler(
  WorkVaultBackgroundHandler handler,
) async {
  final CallbackHandle? handle = PluginUtilities.getCallbackHandle(handler);
  if (handle == null) {
    throw ArgumentError(
      'The background handler must be a top-level or static function marked @pragma(\'vm:entry-point\').',
    );
  }
  const MethodChannel channel = MethodChannel(workVaultBackgroundChannel);
  final String? path = await channel.invokeMethod<String>('databasePath');
  if (path == null || path.isEmpty) {
    throw StateError('The host did not provide a work_vault database path.');
  }
  final WorkVaultDatabase database = WorkVaultDatabase.openFile(path);
  try {
    database.setHandlerHandle(handle.toRawHandle());
  } finally {
    database.close();
  }
  await channel.invokeMethod<void>('registerHandler', handle.toRawHandle());
}

final class _HeadlessBackgroundBinding {
  final BackgroundEventProcessor _processor = const BackgroundEventProcessor();
  WorkVaultDatabase? _database;

  Future<void> handle(MethodCall call) async {
    switch (call.method) {
      case 'dispatch':
        final Object? arguments = call.arguments;
        if (arguments is! Map) {
          throw ArgumentError('dispatch payload must be a map.');
        }
        final Map<Object?, Object?> raw = Map<Object?, Object?>.from(
          arguments,
        );
        final WorkVaultDatabase database = _open(raw['databasePath']);
        await _processor.apply(database, raw);
      case 'shutdown':
        _database?.close();
        _database = null;
      default:
        throw MissingPluginException();
    }
  }

  WorkVaultDatabase _open(Object? path) {
    final WorkVaultDatabase? existing = _database;
    if (existing != null) {
      return existing;
    }
    if (path is! String || path.isEmpty) {
      throw ArgumentError('dispatch payload is missing databasePath.');
    }
    final WorkVaultDatabase database = WorkVaultDatabase.openFile(path);
    _database = database;
    return database;
  }
}
