import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';

void main() {
  test('every status and command has one outcome', () {
    final Map<(TaskStatus, TaskCommand), TaskStatus?> legal =
        <(TaskStatus, TaskCommand), TaskStatus?>{
          (TaskStatus.running, TaskCommand.pause): TaskStatus.paused,
          (TaskStatus.paused, TaskCommand.resume): TaskStatus.running,
          (TaskStatus.enqueued, TaskCommand.cancel): TaskStatus.cancelled,
          (TaskStatus.running, TaskCommand.cancel): TaskStatus.cancelled,
          (TaskStatus.paused, TaskCommand.cancel): TaskStatus.cancelled,
        };

    for (final TaskStatus status in TaskStatus.values) {
      for (final TaskCommand command in TaskCommand.values) {
        expect(
          nextTaskStatus(status, command),
          legal[(status, command)],
          reason: '${status.name} + ${command.name}',
        );
      }
    }
  });

  test('terminal statuses stay terminal', () {
    expect(taskStatusIsTerminal(TaskStatus.completed), isTrue);
    expect(taskStatusIsTerminal(TaskStatus.failed), isTrue);
    expect(taskStatusIsTerminal(TaskStatus.cancelled), isTrue);
    expect(taskStatusIsTerminal(TaskStatus.running), isFalse);
  });
}
