import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:work_vault/work_vault.dart';

import 'background.dart';
import 'src/app.dart';
import 'src/downloads_controller.dart';
import 'src/platform/file_info.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    // Lets a headless engine report events after this UI engine is gone.
    unawaited(
      WorkVault.registerBackgroundHandler(onWorkVaultBackground).catchError((
        Object error,
      ) {
        // Platforms without a background host have nothing to register.
        debugPrint('work_vault example: background handler skipped: $error');
      }),
    );
  }
  runApp(
    WorkVaultExampleApp(
      controller: DownloadsController(
        WorkVault.instance,
        catalog: platformDestinationCatalog(),
      ),
    ),
  );
}
