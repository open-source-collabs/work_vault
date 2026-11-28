import 'package:material_ui/material_ui.dart';
import 'package:work_vault/work_vault.dart';

import '../format.dart';
import 'completed_file_panel.dart';

/// One task: status, live progress, the commands its status allows, and
/// failure or file details once it has finished.
class TaskTile extends StatelessWidget {
  /// Creates a tile for [snapshot].
  const TaskTile({
    super.key,
    required this.snapshot,
    required this.progress,
    required this.destinationPath,
    required this.busy,
    required this.onCommand,
  });

  /// Last known state of the task.
  final TaskSnapshot snapshot;

  /// Latest progress sample, when one has arrived.
  final TaskProgress? progress;

  /// Where the task saves its file, when the app knows.
  final String? destinationPath;

  /// Whether a command for this task is in flight.
  final bool busy;

  /// Called when the user picks pause, resume, or cancel.
  final void Function(TaskCommand command) onCommand;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TaskStatus status = snapshot.status;
    final TaskFailure? failure = snapshot.failure;
    final String? path = destinationPath;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    snapshot.taskId,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(status: status),
                _Actions(status: status, busy: busy, onCommand: onCommand),
              ],
            ),
            if (status == TaskStatus.running ||
                status == TaskStatus.paused ||
                (status == TaskStatus.enqueued && progress != null))
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: _ProgressLine(progress: progress, status: status),
              ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: _FailureDetails(failure: failure),
              ),
            if (status == TaskStatus.completed)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: path != null
                    ? CompletedFilePanel(path: path)
                    : Text(
                        'Saved outside this app, or before it recorded '
                        'destinations.',
                        style: theme.textTheme.bodySmall,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Colored label for a [TaskStatus].
class StatusChip extends StatelessWidget {
  /// Creates a chip for [status].
  const StatusChip({super.key, required this.status});

  /// Status to show.
  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // Exhaustive on purpose: a new status fails analysis until it has a look.
    final (
      IconData icon,
      Color background,
      Color foreground,
    ) = switch (status) {
      TaskStatus.enqueued => (
        Icons.schedule,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      TaskStatus.running => (
        Icons.downloading,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      TaskStatus.paused => (
        Icons.pause_circle_outline,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      TaskStatus.completed => (
        Icons.check_circle_outline,
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      TaskStatus.failed => (
        Icons.error_outline,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      TaskStatus.cancelled => (
        Icons.block,
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
    };
    return Chip(
      avatar: Icon(icon, size: 16, color: foreground),
      label: Text(status.name),
      labelStyle: TextStyle(color: foreground),
      backgroundColor: background,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.status,
    required this.busy,
    required this.onCommand,
  });

  final TaskStatus status;
  final bool busy;
  final void Function(TaskCommand command) onCommand;

  @override
  Widget build(BuildContext context) {
    if (taskStatusIsTerminal(status)) {
      return const SizedBox.shrink();
    }
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    // The vault's own transition table decides what is legal, so the buttons
    // can never offer a command the host would reject.
    bool allowed(TaskCommand command) =>
        nextTaskStatus(status, command) != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (allowed(TaskCommand.pause))
          IconButton(
            tooltip: 'Pause',
            icon: const Icon(Icons.pause),
            onPressed: () => onCommand(TaskCommand.pause),
          ),
        if (allowed(TaskCommand.resume))
          IconButton(
            tooltip: 'Resume',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => onCommand(TaskCommand.resume),
          ),
        if (allowed(TaskCommand.cancel))
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => onCommand(TaskCommand.cancel),
          ),
      ],
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.progress, required this.status});

  final TaskProgress? progress;
  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final TaskProgress? sample = progress;
    final TextStyle? caption = Theme.of(context).textTheme.bodySmall;

    if (sample == null) {
      if (status != TaskStatus.running) {
        // Nothing is moving, so an animated bar would be misleading.
        return Text('No bytes received yet', style: caption);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const LinearProgressIndicator(semanticsLabel: 'Download progress'),
          const SizedBox(height: 6),
          Text('Waiting for the first bytes…', style: caption),
        ],
      );
    }

    final int? total = sample.totalBytes;
    final String size = total == null
        ? formatBytes(sample.bytesDownloaded)
        : '${formatBytes(sample.bytesDownloaded)} of ${formatBytes(total)}';
    final List<String> parts = <String>[
      size,
      if (status == TaskStatus.running) formatSpeed(sample.bytesPerSecond),
      if (status == TaskStatus.running)
        ?formatEta(
          bytesDownloaded: sample.bytesDownloaded,
          totalBytes: total,
          bytesPerSecond: sample.bytesPerSecond,
        ),
    ];
    final double? percentage = sample.percentage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // A null value draws an indeterminate bar when the size is unknown.
        LinearProgressIndicator(
          value: sample.fraction,
          semanticsLabel: 'Download progress',
          semanticsValue: percentage == null
              ? size
              : '${percentage.toStringAsFixed(0)}%',
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(child: Text(parts.join(' · '), style: caption)),
            if (percentage != null)
              Text('${percentage.toStringAsFixed(1)}%', style: caption),
          ],
        ),
      ],
    );
  }
}

class _FailureDetails extends StatelessWidget {
  const _FailureDetails({required this.failure});

  final TaskFailure failure;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? httpStatus = failure.httpStatus;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  failure.code,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                if (httpStatus != null)
                  Text('HTTP $httpStatus', style: theme.textTheme.labelMedium),
                if (failure.retryable)
                  Text(
                    'retryable',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(failure.message, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
