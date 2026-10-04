import 'dart:async';

import 'package:flutter/material.dart';
import 'package:work_vault/work_vault.dart';

import 'background.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(WorkVault.registerBackgroundHandler(onWorkVaultBackground));
  runApp(const WorkVaultExampleApp());
}

/// Host app that shows the public control-plane API.
class WorkVaultExampleApp extends StatelessWidget {
  /// Creates the example app.
  const WorkVaultExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'work_vault',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F6E56)),
        useMaterial3: true,
      ),
      home: const VaultScreen(),
    );
  }
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  static const WorkTaskConfig _config = WorkTaskConfig(
    taskId: 'sample-archive',
    url: 'https://example.com/archive.bin',
    destinationPath: '/data/user/0/archive.bin',
    notification: NotificationMetadata(
      title: 'Archive',
      body: 'Saving archive.bin',
      channelId: 'work.vault.downloads',
      channelName: 'Downloads',
    ),
  );

  String _result = 'Enqueue schedules the sample download.';

  Future<void> _enqueue() async {
    try {
      await WorkVault.instance.initialize();
      final TaskSnapshot snapshot = await WorkVault.instance.enqueue(_config);
      if (!mounted) {
        return;
      }
      setState(
        () => _result = '${snapshot.taskId} is ${snapshot.status.name}.',
      );
    } on WorkVaultFailure catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _result = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('work_vault')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Text('Sample download', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(_config.taskId, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(_config.url),
          const SizedBox(height: 4),
          Text(_config.destinationPath),
          const SizedBox(height: 24),
          FilledButton(onPressed: _enqueue, child: const Text('Enqueue')),
          const SizedBox(height: 24),
          Text(_result),
        ],
      ),
    );
  }
}
