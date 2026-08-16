import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/hierarchy_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const task = CachedTask(
    id: TaskId(3),
    accountId: AccountId(1),
    taskListId: TaskListId(2),
    parentTaskId: null,
    remoteId: TaskRemoteId('task'),
    title: 'Task',
    notes: null,
    status: TaskStatus.needsAction,
    due: null,
  );
  const parent = CachedTask(
    id: TaskId(4),
    accountId: AccountId(1),
    taskListId: TaskListId(2),
    parentTaskId: null,
    remoteId: TaskRemoteId('parent'),
    title: 'Parent',
    notes: null,
    status: TaskStatus.needsAction,
    due: null,
  );

  test('one-level policy accepts promote and leaf demote', () {
    expect(
      validateHierarchyChange(
        task: task,
        requestedParent: parent,
        taskHasChildren: false,
      ),
      isNull,
    );
    expect(
      validateHierarchyChange(
        task: task.copyWith(parentTaskId: const TaskId(4)),
        requestedParent: null,
        taskHasChildren: false,
      ),
      isNull,
    );
  });

  test('one-level policy rejects depth three and cross-scope parents', () {
    expect(
      validateHierarchyChange(
        task: task,
        requestedParent: parent.copyWith(parentTaskId: const TaskId(9)),
        taskHasChildren: false,
      )?.code,
      'task.unsupported_depth',
    );
    expect(
      validateHierarchyChange(
        task: task,
        requestedParent: parent.copyWith(taskListId: const TaskListId(8)),
        taskHasChildren: false,
      )?.code,
      'task.parent_cross_list',
    );
    expect(
      validateHierarchyChange(
        task: task,
        requestedParent: const CachedTask(
          id: TaskId(4),
          accountId: AccountId(8),
          taskListId: TaskListId(2),
          parentTaskId: null,
          remoteId: TaskRemoteId('parent'),
          title: 'Parent',
          notes: null,
          status: TaskStatus.needsAction,
          due: null,
        ),
        taskHasChildren: false,
      )?.code,
      'task.parent_cross_account',
    );
    expect(
      validateHierarchyChange(
        task: task,
        requestedParent: parent,
        taskHasChildren: true,
      )?.code,
      'task.subtree_would_exceed_depth',
    );
  });
}
