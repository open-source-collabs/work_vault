import 'package:flutter/services.dart';

import '../mapping/pigeon_mapper.dart';
import '../models/task_snapshot.dart';
import '../models/work_task_config.dart';
import 'work_vault_engine.dart';
import '../gen/messages.g.dart' as pigeon;

/// [WorkVaultEngine] backed by the generated Pigeon host API.
final class PigeonWorkVaultEngine implements WorkVaultEngine {
  /// Creates an engine that talks to [api].
  PigeonWorkVaultEngine({pigeon.WorkVaultHostApi? api})
    : _api = api ?? pigeon.WorkVaultHostApi();

  final pigeon.WorkVaultHostApi _api;

  @override
  Future<void> initialize() {
    return _guard(_api.initialize);
  }

  @override
  void setObserver(WorkVaultObserver? observer) {
    pigeon.WorkVaultFlutterApi.setUp(
      observer == null ? null : _PigeonCallbacks(observer),
    );
  }

  @override
  Future<TaskSnapshot> enqueue(WorkTaskConfig config) {
    return _guard(() async {
      return taskSnapshotFromPigeon(
        await _api.enqueue(workTaskConfigToPigeon(config)),
      );
    });
  }

  @override
  Future<void> pause(String taskId) {
    return _guard(() => _api.pause(taskId));
  }

  @override
  Future<void> resume(String taskId) {
    return _guard(() => _api.resume(taskId));
  }

  @override
  Future<void> cancel(String taskId) {
    return _guard(() => _api.cancel(taskId));
  }

  @override
  Future<TaskSnapshot?> getTask(String taskId) {
    return _guard(() async {
      final pigeon.TaskSnapshot? snapshot = await _api.getTask(taskId);
      return snapshot == null ? null : taskSnapshotFromPigeon(snapshot);
    });
  }

  @override
  Future<List<TaskSnapshot>> getTasks() {
    return _guard(() async {
      final List<pigeon.TaskSnapshot> tasks = await _api.getTasks();
      return <TaskSnapshot>[
        for (final pigeon.TaskSnapshot task in tasks)
          taskSnapshotFromPigeon(task),
      ];
    });
  }
}

Future<T> _guard<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on PlatformException catch (error) {
    throw mapPlatformFailure(error);
  }
}

final class _PigeonCallbacks implements pigeon.WorkVaultFlutterApi {
  _PigeonCallbacks(this._observer);

  final WorkVaultObserver _observer;

  @override
  void onProgress(pigeon.TaskProgress progress) {
    _observer.onProgress(taskProgressFromPigeon(progress));
  }

  @override
  void onStatusChanged(pigeon.TaskSnapshot snapshot) {
    _observer.onStatusChanged(taskSnapshotFromPigeon(snapshot));
  }
}
