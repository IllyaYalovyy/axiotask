import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const account = AccountId(1);
  const list = TaskListId(2);
  const task = TaskId(3);

  test('empty and Unicode task content is valid', () {
    expect(
      validateTaskCommand(
        const CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: '',
          notes: '日本語 🌍\nsecond line',
        ),
      ),
      isNull,
    );
    expect(
      validateTaskCommand(
        const SetTaskNotesCommand(accountId: account, taskId: task, notes: ''),
      ),
      isNull,
    );
  });

  test('title and notes limits reject only over-bound content', () {
    expect(
      validateTaskCommand(
        CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: 't' * 1024,
          notes: 'n' * 8192,
        ),
      ),
      isNull,
    );
    expect(
      validateTaskCommand(
        CreateTaskCommand(
          accountId: account,
          taskListId: list,
          title: 't' * 1025,
        ),
      )?.code,
      'task.title_too_long',
    );
    expect(
      validateTaskCommand(
        SetTaskNotesCommand(
          accountId: account,
          taskId: task,
          notes: 'n' * 8193,
        ),
      )?.code,
      'task.notes_too_long',
    );
  });

  test('content commands carry typed date and completion values', () {
    final due = TaskDate(2026, 8, 20);
    expect(
      SetTaskDueCommand(accountId: account, taskId: task, due: due).due,
      due,
    );
    expect(
      const SetTaskCompletionCommand(
        accountId: account,
        taskId: task,
        status: TaskStatus.completed,
      ).status,
      TaskStatus.completed,
    );
  });
}
