// The duplicate rule, as established from v1.5.3
// (0b81e18693ad1a108c2b3e8113217f7eb11a5a80): lib/src/ui/task_actions.dart
// `duplicateTask` calls `createTask(listId: task.listId, parentId:
// task.task.parent, title: '<title> (copy)')`, and that create writes no
// notes, no due date, status needsAction and no subtasks; its
// test/ui/detail_actions_test.dart pins the title, list and parent.
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/task_duplication.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CachedTask source({
    TaskId? parent,
    TaskStatus status = TaskStatus.needsAction,
  }) => CachedTask(
    id: const TaskId(5),
    accountId: const AccountId(1),
    taskListId: const TaskListId(3),
    parentTaskId: parent,
    remoteId: const TaskRemoteId('remote-source'),
    title: 'apples',
    notes: 'source notes',
    status: status,
    due: TaskDate(2026, 11, 20),
    webViewLink: Uri.parse('https://tasks.google.com/task/remote-source'),
  );

  test('a top-level task is copied as "<title> (copy)" in the same list', () {
    final plan = planTaskDuplicate(source());

    expect(plan.sourceTaskId, const TaskId(5));
    expect(plan.title, 'apples (copy)');
    expect(plan.taskListId, const TaskListId(3));
    expect(plan.parentTaskId, isNull);
  });

  test('a subtask stays under the same parent', () {
    expect(
      planTaskDuplicate(source(parent: const TaskId(4))).parentTaskId,
      const TaskId(4),
    );
  });

  test('notes, due date and completion are not copied', () {
    final plan = planTaskDuplicate(source(status: TaskStatus.completed));

    expect(plan.notes, isNull);
    expect(plan.due, isNull);
    expect(plan.status, TaskStatus.needsAction);
  });

  test('the copy is an ordinary create carrying no source identity', () {
    final create = planTaskDuplicate(source(parent: const TaskId(4)))
        .toCreateCommand(const AccountId(1));

    expect(create.accountId, const AccountId(1));
    expect(create.taskListId, const TaskListId(3));
    expect(create.parentTaskId, const TaskId(4));
    expect(create.title, 'apples (copy)');
    expect(create.notes, isNull);
    expect(create.due, isNull);
    expect(create.status, TaskStatus.needsAction);
  });

  test('a copy of a copy appends the suffix again', () {
    final copy = source().copyWith(title: planTaskDuplicate(source()).title);

    expect(planTaskDuplicate(copy).title, 'apples (copy) (copy)');
  });
}
