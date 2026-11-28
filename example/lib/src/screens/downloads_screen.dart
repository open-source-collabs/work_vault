import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:work_vault/work_vault.dart';

import '../download_defaults.dart';
import '../downloads_controller.dart';
import '../widgets/new_download_sheet.dart';
import '../widgets/task_tile.dart';

/// Every task the vault knows about, with filters and a new-download action.
class DownloadsScreen extends StatefulWidget {
  /// Creates the screen for [controller].
  const DownloadsScreen({super.key, required this.controller});

  /// Source of tasks and commands.
  final DownloadsController controller;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  DownloadsController get _controller => widget.controller;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.start());
    // The host keeps working while the app is in the background; read its
    // state again when the user comes back.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_controller.refresh()),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final String? failure = await _controller.refresh();
    if (failure != null && mounted) {
      _showMessage(failure);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addSample() async {
    try {
      await _controller.enqueue(
        sampleConfig(_controller.downloadDirectory, DateTime.now()),
      );
    } on WorkVaultFailure catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    }
  }

  Future<void> _newDownload() async {
    final TaskSnapshot? snapshot = await showNewDownloadSheet(
      context,
      _controller,
    );
    if (snapshot != null && mounted) {
      _showMessage('${snapshot.taskId} is ${snapshot.status.name}.');
    }
  }

  Future<void> _command(String taskId, TaskCommand command) async {
    if (command == TaskCommand.cancel && !await _confirmCancel(taskId)) {
      return;
    }
    final String? failure = await _controller.run(taskId, command);
    if (failure != null && mounted) {
      _showMessage(failure);
    }
  }

  Future<bool> _confirmCancel(String taskId) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Cancel download?'),
        content: Text(
          '$taskId stops and cannot be resumed. A cancelled task stays in '
          'the list.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel download'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? child) {
        final bool ready =
            !_controller.isLoading && _controller.startupError == null;
        return Scaffold(
          appBar: AppBar(
            title: const Text('work_vault'),
            actions: <Widget>[
              if (ready)
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => unawaited(_refresh()),
                ),
            ],
          ),
          floatingActionButton: ready
              ? FloatingActionButton.extended(
                  onPressed: _newDownload,
                  icon: const Icon(Icons.add),
                  label: const Text('New download'),
                )
              : null,
          body: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? startupError = _controller.startupError;
    if (startupError != null) {
      return _Message(
        icon: Icons.cloud_off,
        title: 'The download host is not available',
        body: startupError,
        action: FilledButton.icon(
          onPressed: () => unawaited(_controller.start()),
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }
    if (!_controller.hasTasks) {
      return _Message(
        icon: Icons.download_for_offline_outlined,
        title: 'No downloads yet',
        body:
            'Downloads keep running in the background and are listed here '
            'again when the app restarts.',
        action: FilledButton.icon(
          onPressed: _addSample,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Add sample download'),
        ),
      );
    }

    final List<TaskSnapshot> tasks = _controller.tasks;
    return Column(
      children: <Widget>[
        _FilterBar(controller: _controller),
        Expanded(
          child: tasks.isEmpty
              ? _Message(
                  icon: Icons.filter_list_off,
                  title: 'No ${_controller.filter.label.toLowerCase()} tasks',
                  body: 'Pick another filter to see the rest.',
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    // Leaves room above the floating action button.
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: tasks.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final TaskSnapshot task = tasks[index];
                      return TaskTile(
                        key: ValueKey<String>(task.taskId),
                        snapshot: task,
                        progress: _controller.progressFor(task.taskId),
                        destinationPath: _controller.destinationFor(
                          task.taskId,
                        ),
                        busy: _controller.isBusy(task.taskId),
                        onCommand: (TaskCommand command) =>
                            unawaited(_command(task.taskId, command)),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.controller});

  final DownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          for (final TaskFilter filter in TaskFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text('${filter.label} ${controller.countFor(filter)}'),
                selected: controller.filter == filter,
                showCheckmark: false,
                onSelected: (_) => controller.setFilter(filter),
              ),
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget? action = this.action;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 24),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
