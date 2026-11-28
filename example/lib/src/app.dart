import 'package:material_ui/material_ui.dart';

import 'downloads_controller.dart';
import 'screens/downloads_screen.dart';

const Color _seed = Color(0xFF0F6E56);

/// Example app that shows the public work_vault API.
class WorkVaultExampleApp extends StatelessWidget {
  /// Creates the app around [controller].
  const WorkVaultExampleApp({super.key, required this.controller});

  /// Task state shared by every screen.
  final DownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'work_vault',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      home: DownloadsScreen(controller: controller),
    );
  }
}
