import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine/engine_factory.dart';
import 'engine/work_vault_engine.dart';
import 'isolate/background_entry_point.dart';
import 'isolate/background_event_processor.dart';
import 'models/task_progress.dart';
import 'models/task_snapshot.dart';
import 'models/task_status.dart';
import 'models/work_task_config.dart';
import 'models/work_vault_failure.dart';
import 'task_transition.dart';

/// Schedules downloads and exposes their status and progress.
///
/// Dart is the control plane. The host process keeps running a transfer after
/// this isolate is gone, and the next [initialize] reads that state back.
/// Host callbacks are applied only after [initialize] has completed.
final class WorkVault {
  WorkVault._(this._engine);

  /// Vault bound to the platform engine.
  static final WorkVault instance = WorkVault._(createPlatformWorkVaultEngine());

  /// Remembers [handler] for a headless engine started after this UI engine is gone.
  ///
  /// [handler] must be a top-level or static function marked
  /// `@pragma('vm:entry-point')`.
  static Future<void> registerBackgroundHandler(
    WorkVaultBackgroundHandler handler,
  ) {
    return registerWorkVaultBackgroundHandler(handler);
  }

  /// Vault bound to [engine].
  ///
  /// Tests use this to supply a fake host. Application code uses [instance].
  @visibleForTesting
  factory WorkVault.forTest(WorkVaultEngine engine) = WorkVault._;

  final WorkVaultEngine _engine;
  final Map<String, TaskSnapshot> _cache = <String, TaskSnapshot>{};
  final List<_HostEvent> _pending = <_HostEvent>[];

  StreamController<TaskSnapshot>? _statusController;
  final Map<String, StreamController<TaskProgress>> _progressControllers =
      <String, StreamController<TaskProgress>>{};

  Future<void>? _initializeFuture;
  int _generation = 0;
  bool _initialized = false;
  bool _acceptingLive = false;

  /// Whether [initialize] has completed and [dispose] has not run since.
  bool get isInitialized => _initialized;

  /// Attaches the host listener and loads tasks that already exist.
  ///
  /// A second call while this vault is ready does nothing.
  Future<void> initialize() {
    if (_initialized) {
      return Future<void>.value();
    }
    return _initializeFuture ??= _start();
  }

  /// Schedules [config].
  ///
  /// Throws [DuplicateTask] when [WorkTaskConfig.taskId] is already known.
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) async {
    _ensureReady();
    config.validate();
    if (_cache.containsKey(config.taskId)) {
      throw DuplicateTask(config.taskId);
    }
    final TaskSnapshot snapshot = await _engine.enqueue(config);
    if (snapshot.taskId != config.taskId) {
      throw PlatformFault(
        'Host returned task "${snapshot.taskId}" for "${config.taskId}".',
      );
    }
    // A host that starts work at once can report a newer status before this call returns. The
    // snapshot it returns is older then, and must not replace what the events already said.
    if (!_cache.containsKey(snapshot.taskId)) {
      _publishStatus(snapshot);
    }
    return _cache[snapshot.taskId] ?? snapshot;
  }

  /// Pauses a running task.
  Future<void> pause(String taskId) {
    return _command(taskId, TaskCommand.pause);
  }

  /// Resumes a paused task.
  Future<void> resume(String taskId) {
    return _command(taskId, TaskCommand.resume);
  }

  /// Cancels a task that has not finished.
  Future<void> cancel(String taskId) {
    return _command(taskId, TaskCommand.cancel);
  }

  /// Progress for [taskId], replaying the cached sample to each new listener.
  Stream<TaskProgress> watchProgress(String taskId) {
    return Stream<TaskProgress>.multi((
      MultiStreamController<TaskProgress> listener,
    ) {
      final StreamController<TaskProgress> controller = _progressController(
        taskId,
      );
      final StreamSubscription<TaskProgress> subscription = controller.stream
          .listen(
            listener.add,
            onError: listener.addError,
            onDone: listener.close,
          );
      listener.onCancel = () {
        unawaited(subscription.cancel());
      };
      final TaskProgress? progress = _cache[taskId]?.progress;
      if (_initialized && progress != null) {
        listener.add(progress);
      }
    });
  }

  /// Status rows for one task, or for every task when [taskId] is omitted.
  ///
  /// Each new listener receives the cached row before later updates.
  Stream<TaskSnapshot> watchStatus({String? taskId}) {
    return Stream<TaskSnapshot>.multi((
      MultiStreamController<TaskSnapshot> listener,
    ) {
      final StreamController<TaskSnapshot> controller = _statusEvents();
      final StreamSubscription<TaskSnapshot> subscription = controller.stream
          .listen(
            (TaskSnapshot snapshot) {
              if (taskId == null || snapshot.taskId == taskId) {
                listener.add(snapshot);
              }
            },
            onError: listener.addError,
            onDone: listener.close,
          );
      listener.onCancel = () {
        unawaited(subscription.cancel());
      };
      if (!_initialized) {
        return;
      }
      if (taskId == null) {
        for (final TaskSnapshot snapshot in _cache.values) {
          listener.add(snapshot);
        }
      } else {
        final TaskSnapshot? snapshot = _cache[taskId];
        if (snapshot != null) {
          listener.add(snapshot);
        }
      }
    });
  }

  /// Cached view of [taskId], including its latest progress sample.
  TaskObservation? observationFor(String taskId) {
    final TaskSnapshot? snapshot = _cache[taskId];
    if (snapshot == null) {
      return null;
    }
    return (snapshot: snapshot, progress: snapshot.progress);
  }

  /// Reads one task from the host and refreshes the cache.
  Future<TaskSnapshot?> getTask(String taskId) async {
    _ensureReady();
    final TaskSnapshot? snapshot = await _engine.getTask(taskId);
    if (snapshot == null) {
      _cache.remove(taskId);
      return null;
    }
    _publishStatus(snapshot);
    return _cache[snapshot.taskId] ?? snapshot;
  }

  /// Reads every task from the host and replaces the cache.
  Future<List<TaskSnapshot>> getTasks({TaskStatus? status}) async {
    _ensureReady();
    final List<TaskSnapshot> tasks = await _engine.getTasks();
    _replaceCache(tasks);
    if (status == null) {
      return List<TaskSnapshot>.unmodifiable(_cache.values);
    }
    return List<TaskSnapshot>.unmodifiable(
      _cache.values.where((TaskSnapshot task) => task.status == status),
    );
  }

  /// Detaches host events and closes the streams from [watchProgress] and
  /// [watchStatus]. A later [initialize] starts a fresh session.
  Future<void> dispose() async {
    _generation += 1;
    _initialized = false;
    _acceptingLive = false;
    _initializeFuture = null;
    _pending.clear();
    _cache.clear();
    _engine.setObserver(null);
    await _closeControllers();
  }

  Future<void> _start() async {
    final int generation = _generation;
    _engine.setObserver(_EngineObserver(this));
    try {
      await _engine.initialize();
      if (generation != _generation) {
        return;
      }
      final List<TaskSnapshot> tasks = await _engine.getTasks();
      if (generation != _generation) {
        return;
      }
      _cache
        ..clear()
        ..addEntries(
          tasks.map(
            (TaskSnapshot task) =>
                MapEntry<String, TaskSnapshot>(task.taskId, task),
          ),
        );
      final List<_HostEvent> pending = List<_HostEvent>.of(_pending);
      _pending.clear();
      _acceptingLive = true;
      _initialized = true;
      for (final TaskSnapshot task in tasks) {
        _emitStatus(task);
      }
      for (final _HostEvent event in pending) {
        _apply(event);
      }
    } on Object {
      if (generation == _generation) {
        _engine.setObserver(null);
        _acceptingLive = false;
        _initialized = false;
        _initializeFuture = null;
      }
      rethrow;
    }
  }

  Future<void> _command(String taskId, TaskCommand command) async {
    _ensureReady();
    final TaskSnapshot? current =
        _cache[taskId] ?? await _engine.getTask(taskId);
    if (current == null) {
      throw TaskNotFound(taskId);
    }
    final TaskStatus? next = nextTaskStatus(current.status, command);
    if (next == null) {
      throw IllegalTaskTransition(
        taskId: taskId,
        from: current.status,
        action: command,
      );
    }
    switch (command) {
      case TaskCommand.pause:
        await _engine.pause(taskId);
      case TaskCommand.resume:
        await _engine.resume(taskId);
      case TaskCommand.cancel:
        await _engine.cancel(taskId);
    }
    _publishStatus(current.copyWith(status: next, clearFailure: true));
  }

  void _ensureReady() {
    if (!_initialized) {
      throw const WorkVaultNotInitialized();
    }
  }

  void _onProgress(TaskProgress progress) {
    if (!_acceptingLive) {
      _pending.add(_ProgressEvent(progress));
      return;
    }
    _publishProgress(progress);
  }

  void _onStatus(TaskSnapshot snapshot) {
    if (!_acceptingLive) {
      _pending.add(_StatusEvent(snapshot));
      return;
    }
    _publishStatus(snapshot);
    final TaskProgress? progress = snapshot.progress;
    if (progress != null) {
      _emitProgress(progress);
    }
  }

  void _apply(_HostEvent event) {
    switch (event) {
      case _ProgressEvent(:final TaskProgress progress):
        _publishProgress(progress);
      case _StatusEvent(:final TaskSnapshot snapshot):
        _onStatus(snapshot);
    }
  }

  void _publishStatus(TaskSnapshot snapshot) {
    final TaskSnapshot? current = _cache[snapshot.taskId];
    if (current != null &&
        taskStatusIsTerminal(current.status) &&
        snapshot.status != current.status) {
      return;
    }
    if (current == snapshot) {
      return;
    }
    _cache[snapshot.taskId] = snapshot;
    _emitStatus(snapshot);
  }

  void _publishProgress(TaskProgress progress) {
    final TaskSnapshot? current = _cache[progress.taskId];
    if (current == null || taskStatusIsTerminal(current.status)) {
      return;
    }
    if (current.progress == progress) {
      return;
    }
    _cache[progress.taskId] = current.copyWith(progress: progress);
    _emitProgress(progress);
  }

  void _replaceCache(List<TaskSnapshot> tasks) {
    final Map<String, TaskSnapshot> next = <String, TaskSnapshot>{
      for (final TaskSnapshot task in tasks) task.taskId: task,
    };
    final Set<String> removed = _cache.keys.toSet()..removeAll(next.keys);
    for (final String taskId in removed) {
      _cache.remove(taskId);
      final StreamController<TaskProgress>? controller = _progressControllers
          .remove(taskId);
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }
    for (final TaskSnapshot task in next.values) {
      final TaskSnapshot? current = _cache[task.taskId];
      _cache[task.taskId] = task;
      if (current != task) {
        _emitStatus(task);
      }
    }
  }

  void _emitStatus(TaskSnapshot snapshot) {
    final StreamController<TaskSnapshot>? controller = _statusController;
    if (controller != null && !controller.isClosed) {
      controller.add(snapshot);
    }
  }

  void _emitProgress(TaskProgress progress) {
    final StreamController<TaskProgress>? controller =
        _progressControllers[progress.taskId];
    if (controller != null && !controller.isClosed) {
      controller.add(progress);
    }
  }

  StreamController<TaskSnapshot> _statusEvents() {
    final StreamController<TaskSnapshot>? existing = _statusController;
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    return _statusController = StreamController<TaskSnapshot>.broadcast();
  }

  StreamController<TaskProgress> _progressController(String taskId) {
    final StreamController<TaskProgress>? existing =
        _progressControllers[taskId];
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    return _progressControllers[taskId] =
        StreamController<TaskProgress>.broadcast();
  }

  Future<void> _closeControllers() async {
    final StreamController<TaskSnapshot>? status = _statusController;
    _statusController = null;
    if (status != null && !status.isClosed) {
      await status.close();
    }
    final List<StreamController<TaskProgress>> progress =
        List<StreamController<TaskProgress>>.of(_progressControllers.values);
    _progressControllers.clear();
    for (final StreamController<TaskProgress> controller in progress) {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }
}

final class _EngineObserver implements WorkVaultObserver {
  _EngineObserver(this._vault);

  final WorkVault _vault;

  @override
  void onProgress(TaskProgress progress) {
    _vault._onProgress(progress);
  }

  @override
  void onStatusChanged(TaskSnapshot snapshot) {
    _vault._onStatus(snapshot);
  }
}

sealed class _HostEvent {}

final class _ProgressEvent extends _HostEvent {
  _ProgressEvent(this.progress);

  final TaskProgress progress;
}

final class _StatusEvent extends _HostEvent {
  _StatusEvent(this.snapshot);

  final TaskSnapshot snapshot;
}
