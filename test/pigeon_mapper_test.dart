import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/gen/messages.g.dart' as pigeon;
import 'package:work_vault/src/mapping/pigeon_mapper.dart';
import 'package:work_vault/work_vault.dart';

import 'support.dart';

void main() {
  test('encodes a config into the pigeon payload', () {
    final WorkTaskConfig config = sampleConfig(
      headers: const <String, String>{'Authorization': 'Bearer token'},
      retry: const RetryPolicy(
        maxAttempts: 4,
        initialBackoff: Duration(seconds: 2),
        maxBackoff: Duration(minutes: 1),
        multiplier: 3,
      ),
    );

    final pigeon.WorkTaskConfig payload = workTaskConfigToPigeon(config);

    expect(payload.taskId, 'job-1');
    expect(payload.method, pigeon.HttpMethod.get);
    expect(payload.network, pigeon.NetworkConstraint.any);
    expect(payload.headers['Authorization'], 'Bearer token');
    expect(payload.retry.initialBackoffMs, 2000);
    expect(payload.retry.maxBackoffMs, 60000);
    expect(payload.battery.requiresCharging, isFalse);
    expect(payload.notification.channelId, 'work.vault.downloads');
  });

  test('coerces an invalid progress sample', () {
    final TaskProgress progress = taskProgressFromPigeon(
      pigeon.TaskProgress(
        taskId: 'job-1',
        bytesDownloaded: -5,
        totalBytes: -1,
        bytesPerSecond: double.nan,
        elapsedMs: -4,
        percentage: 140,
      ),
    );

    expect(progress.bytesDownloaded, 0);
    expect(progress.totalBytes, isNull);
    expect(progress.bytesPerSecond, 0);
    expect(progress.elapsed, Duration.zero);
    expect(progress.percentage, isNull);
    expect(progress.fraction, isNull);
  });

  test('maps host error codes onto sealed failures', () {
    expect(
      mapPlatformFailure(
        PlatformException(code: pigeon.workVaultNotInitialized),
      ),
      isA<WorkVaultNotInitialized>(),
    );
    expect(
      mapPlatformFailure(
        PlatformException(
          code: pigeon.workVaultDuplicateTask,
          message: 'exists',
          details: <Object?, Object?>{'taskId': 'job-1'},
        ),
      ),
      isA<DuplicateTask>().having(
        (DuplicateTask error) => error.taskId,
        'taskId',
        'job-1',
      ),
    );
    expect(
      mapPlatformFailure(
        PlatformException(
          code: pigeon.workVaultIllegalTransition,
          message: 'nope',
          details: <Object?, Object?>{
            'taskId': 'job-1',
            'from': 'paused',
            'action': 'pause',
          },
        ),
      ),
      isA<IllegalTaskTransition>()
          .having(
            (IllegalTaskTransition error) => error.from,
            'from',
            TaskStatus.paused,
          )
          .having(
            (IllegalTaskTransition error) => error.action,
            'action',
            TaskCommand.pause,
          ),
    );
    expect(
      mapPlatformFailure(
        PlatformException(
          code: pigeon.workVaultTransferFailed,
          message: 'server rejected the request',
          details: <Object?, Object?>{
            'taskId': 'job-1',
            'code': 'http',
            'httpStatus': 503,
            'retryable': true,
          },
        ),
      ),
      isA<TransferFailed>()
          .having((TransferFailed error) => error.httpStatus, 'httpStatus', 503)
          .having(
            (TransferFailed error) => error.retryable,
            'retryable',
            isTrue,
          ),
    );
    expect(
      mapPlatformFailure(
        PlatformException(
          code: pigeon.workVaultUnimplemented,
          message: 'missing',
        ),
      ),
      isA<PlatformFault>().having(
        (PlatformFault error) => error.message,
        'message',
        'missing',
      ),
    );
  });
}
