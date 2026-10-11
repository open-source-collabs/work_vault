import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:work_vault/work_vault.dart';

import 'background.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    try {
      unawaited(WorkVault.registerBackgroundHandler(onWorkVaultBackground));
    } catch (_) {}
  }
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
  static const String _taskId = 'sample-archive';
  static const String _downloadUrl =
      'https://raw.githubusercontent.com/flutter/flutter/master/README.md';

  String _destinationPath = 'sample-archive.bin';
  String _result = 'Enqueue schedules the sample download.';
  double? _progressFraction;
  StreamSubscription<TaskProgress>? _progressSubscription;
  StreamSubscription<TaskSnapshot>? _statusSubscription;

  @override
  void initState() {
    super.initState();
    _initPath();
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _statusSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initPath() async {
    if (kIsWeb) {
      setState(() => _destinationPath = 'sample-archive.bin');
      return;
    }
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      setState(() => _destinationPath = '${dir.path}/sample-archive.bin');
    } catch (_) {
      setState(() => _destinationPath = '/tmp/sample-archive.bin');
    }
  }

  Future<void> _enqueue() async {
    try {
      await WorkVault.instance.initialize();

      _progressSubscription?.cancel();
      _progressSubscription = WorkVault.instance
          .watchProgress(_taskId)
          .listen((TaskProgress progress) {
        if (!mounted) {
          return;
        }
        setState(() {
          _progressFraction = progress.fraction;
        });
      });

      _statusSubscription?.cancel();
      _statusSubscription = WorkVault.instance
          .watchStatus(taskId: _taskId)
          .listen((TaskSnapshot snapshot) {
        if (!mounted) {
          return;
        }
        setState(() {
          _result = '${snapshot.taskId} is ${snapshot.status.name}.';
        });
      });

      final WorkTaskConfig config = WorkTaskConfig(
        taskId: _taskId,
        url: _downloadUrl,
        destinationPath: _destinationPath,
        notification: const NotificationMetadata(
          title: 'Archive',
          body: 'Saving sample-archive.bin',
          channelId: 'work.vault.downloads',
          channelName: 'Downloads',
        ),
      );

      final TaskSnapshot snapshot = await WorkVault.instance.enqueue(config);
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
          Text('Cross-Platform Download', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(_taskId, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(_downloadUrl),
          const SizedBox(height: 4),
          Text(_destinationPath, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 24),
          if (_progressFraction != null) ...<Widget>[
            LinearProgressIndicator(value: _progressFraction),
            const SizedBox(height: 8),
            Text('${((_progressFraction ?? 0) * 100).toStringAsFixed(1)}%'),
            const SizedBox(height: 16),
          ],
          FilledButton(onPressed: _enqueue, child: const Text('Enqueue')),
          const SizedBox(height: 24),
          Text(_result),
        ],
      ),
    );
  }
}
