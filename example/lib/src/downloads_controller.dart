import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:work_vault/work_vault.dart';

import 'destination_catalog.dart';
import 'download_defaults.dart';

/// Status groups offered as list filters.
enum TaskFilter {
  /// Every task.
  all('All'),

  /// Enqueued or running.
  active('Active'),

  /// Paused by the caller.
  paused('Paused'),

  /// Finished successfully.
  completed('Completed'),

  /// Ended with a failure.
  failed('Failed'),

  /// Ended by the caller.
  cancelled('Cancelled');

  const TaskFilter(this.label);

  /// Chip text.
  final String label;

  /// Whether [status] belongs to this group.
  bool matches(TaskStatus status) {
    return switch (this) {
      TaskFilter.all => true,
      TaskFilter.active =>
        status == TaskStatus.enqueued || status == TaskStatus.running,
      TaskFilter.paused => status == TaskStatus.paused,
      TaskFilter.completed => status == TaskStatus.completed,
      TaskFilter.failed => status == TaskStatus.failed,
      TaskFilter.cancelled => status == TaskStatus.cancelled,
    };
  }
}

/// App-side view of every task the vault knows about.
///
/// This is the only class in the example that talks to [WorkVault]. It
/// restores tasks the host kept while the app was closed, follows status for
/// all of them, and follows progress only while a task can still change.
class DownloadsController extends ChangeNotifier {
  /// Creates a controller bound to [vault].
  ///
  /// [catalog] remembers each task's destination across restarts, and
  /// [resolveDirectory] picks the folder new downloads are saved in.
  DownloadsController(
    this._vault, {
    required this._catalog,
    this._resolveDirectory = resolveDownloadDirectory,
  });

  final WorkVault _vault;
  final DestinationCatalog _catalog;
  final Future<String> Function() _resolveDirectory;
  final Map<String, String> _destinations = <String, String>{};
  Future<void>? _pendingSave;
  String _directory = '';
  final Map<String, TaskSnapshot> _tasks = <String, TaskSnapshot>{};
  final Map<String, TaskProgress> _progress = <String, TaskProgress>{};
  final Map<String, StreamSubscription<TaskProgress>> _progressSubscriptions =
      <String, StreamSubscription<TaskProgress>>{};
  final Set<String> _busy = <String>{};
  StreamSubscription<TaskSnapshot>? _statusSubscription;

  bool _loading = true;
  bool _disposed = false;
  String? _startupError;
  TaskFilter _filter = TaskFilter.all;

  /// True until [start] has finished, successfully or not.
  bool get isLoading => _loading;

  /// Why [start] failed, or null when the vault is ready.
  String? get startupError => _startupError;

  /// Active list filter.
  TaskFilter get filter => _filter;

  /// Whether any task is known, regardless of [filter].
  bool get hasTasks => _tasks.isNotEmpty;

  /// Tasks matching [filter]: unfinished first, then by task id.
  List<TaskSnapshot> get tasks {
    final List<TaskSnapshot> visible = <TaskSnapshot>[
      for (final TaskSnapshot task in _tasks.values)
        if (_filter.matches(task.status)) task,
    ];
    visible.sort((TaskSnapshot a, TaskSnapshot b) {
      final int byState = _rank(a.status).compareTo(_rank(b.status));
      return byState != 0 ? byState : a.taskId.compareTo(b.taskId);
    });
    return visible;
  }

  /// Number of known tasks in [filter].
  int countFor(TaskFilter filter) {
    return _tasks.values
        .where((TaskSnapshot task) => filter.matches(task.status))
        .length;
  }

  /// Latest progress sample for [taskId], from a live event or the snapshot.
  TaskProgress? progressFor(String taskId) => _progress[taskId];

  /// Where [taskId] saves its file, when this app enqueued it.
  String? destinationFor(String taskId) => _destinations[taskId];

  /// Folder new downloads are saved in. Empty on web and before [start].
  String get downloadDirectory => _directory;

  /// Whether a command for [taskId] is in flight.
  bool isBusy(String taskId) => _busy.contains(taskId);

  /// Shows only tasks in [filter].
  void setFilter(TaskFilter filter) {
    if (filter == _filter) {
      return;
    }
    _filter = filter;
    _notify();
  }

  /// Initializes the vault and loads the tasks it already holds.
  ///
  /// Safe to call again after a failure; it retries.
  Future<void> start() async {
    _loading = true;
    _startupError = null;
    _notify();
    try {
      _directory = await _resolveDirectory();
      await _loadDestinations();
      await _vault.initialize();
      // Subscribe before reading, so an event that lands during the read is
      // not lost. The read result is the vault's fresh cache either way.
      _statusSubscription ??= _vault.watchStatus().listen(_apply);
      await _sync();
    } on WorkVaultFailure catch (error) {
      _startupError = error.message;
    } on Object catch (error) {
      // For example a MissingPluginException on a platform without a host.
      _startupError = error.toString();
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Schedules [config] and shows it right away.
  ///
  /// Throws the [WorkVaultFailure] from [WorkVault.enqueue], for example
  /// [InvalidWorkConfig] or [DuplicateTask].
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    final TaskSnapshot snapshot = await _vault.enqueue(config);
    _destinations[snapshot.taskId] = config.destinationPath;
    // A host that starts work at once may already have reported a newer
    // status through the stream; the returned snapshot must not undo it.
    if (!_tasks.containsKey(snapshot.taskId)) {
      _apply(snapshot);
    } else {
      _notify();
    }
    await _saveDestinations();
    return snapshot;
  }

  /// Reads every task from the host again.
  ///
  /// Status events keep the list current while the app runs. This is a
  /// manual resync, also used when the app returns to the foreground. It
  /// returns the failure message, or null on success.
  Future<String?> refresh() async {
    if (_loading || _startupError != null) {
      return null;
    }
    try {
      await _sync();
      _notify();
      return null;
    } on WorkVaultFailure catch (error) {
      return error.message;
    }
  }

  /// Whether a task that can still write is saving to [destinationPath].
  bool isDestinationInUse(String destinationPath) {
    return _destinations.entries.any((MapEntry<String, String> entry) {
      final TaskSnapshot? task = _tasks[entry.key];
      return entry.value == destinationPath &&
          task != null &&
          !taskStatusIsTerminal(task.status);
    });
  }

  /// Replaces the view with the host's task list.
  Future<void> _sync() async {
    final List<TaskSnapshot> current = await _vault.getTasks();
    final Set<String> ids = <String>{
      for (final TaskSnapshot task in current) task.taskId,
    };
    for (final String gone in _tasks.keys.toList()) {
      if (!ids.contains(gone)) {
        _forget(gone);
      }
    }
    for (final TaskSnapshot snapshot in current) {
      _apply(snapshot, notify: false);
    }
    // Drop destinations of tasks the host no longer remembers, so the
    // catalog does not grow without bound.
    final int before = _destinations.length;
    _destinations.removeWhere((String id, String _) => !ids.contains(id));
    if (_destinations.length != before) {
      await _saveDestinations();
    }
  }

  void _forget(String taskId) {
    _tasks.remove(taskId);
    _progress.remove(taskId);
    unawaited(_progressSubscriptions.remove(taskId)?.cancel());
  }

  Future<void> _loadDestinations() async {
    try {
      _destinations.addAll(await _catalog.load(_directory));
    } on Object catch (error) {
      // A lost catalog only hides file details; downloads still work.
      debugPrint('work_vault example: could not read destinations: $error');
    }
  }

  /// Queues a write of the current destinations.
  ///
  /// Writes run one at a time, each with a snapshot of the map, so two quick
  /// enqueues cannot race on the catalog file.
  Future<void> _saveDestinations() {
    final Map<String, String> snapshot = Map<String, String>.of(_destinations);
    Future<void> write() async {
      try {
        await _catalog.save(_directory, snapshot);
      } on Object catch (error) {
        debugPrint('work_vault example: could not save destinations: $error');
      }
    }

    final Future<void>? previous = _pendingSave;
    final Future<void> next = previous == null
        ? write()
        : previous.then((_) => write());
    _pendingSave = next;
    return next;
  }

  /// Sends [command] for [taskId].
  ///
  /// Returns the failure message, or null on success. The new status arrives
  /// through the status stream, not from this call.
  Future<String?> run(String taskId, TaskCommand command) async {
    if (!_busy.add(taskId)) {
      return null;
    }
    _notify();
    try {
      await switch (command) {
        TaskCommand.pause => _vault.pause(taskId),
        TaskCommand.resume => _vault.resume(taskId),
        TaskCommand.cancel => _vault.cancel(taskId),
      };
      return null;
    } on WorkVaultFailure catch (error) {
      return error.message;
    } finally {
      _busy.remove(taskId);
      _notify();
    }
  }

  void _apply(TaskSnapshot snapshot, {bool notify = true}) {
    final String id = snapshot.taskId;
    _tasks[id] = snapshot;
    final TaskProgress? progress = snapshot.progress;
    if (progress != null) {
      _progress[id] = progress;
    }
    if (taskStatusIsTerminal(snapshot.status)) {
      unawaited(_progressSubscriptions.remove(id)?.cancel());
    } else {
      _progressSubscriptions[id] ??= _vault.watchProgress(id).listen((
        TaskProgress progress,
      ) {
        _progress[id] = progress;
        _notify();
      });
    }
    if (notify) {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static int _rank(TaskStatus status) {
    return switch (status) {
      TaskStatus.running => 0,
      TaskStatus.enqueued => 1,
      TaskStatus.paused => 2,
      TaskStatus.failed => 3,
      TaskStatus.completed => 4,
      TaskStatus.cancelled => 5,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_statusSubscription?.cancel());
    for (final StreamSubscription<TaskProgress> subscription
        in _progressSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _progressSubscriptions.clear();
    // WorkVault.instance is shared by the whole process, so it is not
    // disposed here.
    super.dispose();
  }
}
