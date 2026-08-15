import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('list commands retain explicit account and stable local identity', () {
    const create = CreateTaskListCommand(
      accountId: AccountId(7),
      title: 'Synthetic list',
    );
    const rename = RenameTaskListCommand(
      accountId: AccountId(7),
      taskListId: TaskListId(11),
      title: 'Renamed synthetic list',
    );

    expect(create.accountId, const AccountId(7));
    expect(rename.accountId, const AccountId(7));
    expect(rename.taskListId, const TaskListId(11));
    expect(validateTaskListCommand(create), isNull);
    expect(validateTaskListCommand(rename), isNull);
  });

  test('list title validation matches the admitted Google field bound', () {
    expect(
      validateTaskListCommand(
        CreateTaskListCommand(
          accountId: const AccountId(1),
          title: List<String>.filled(1024, 'x').join(),
        ),
      ),
      isNull,
    );

    final failure = validateTaskListCommand(
      CreateTaskListCommand(
        accountId: const AccountId(1),
        title: List<String>.filled(1025, 'x').join(),
      ),
    );
    expect(failure?.code, 'task_list.title_too_long');
  });
}
