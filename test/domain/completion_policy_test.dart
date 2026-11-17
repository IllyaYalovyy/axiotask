import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/completion_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const account = AccountId(1);
  const list = TaskListId(1);
  const otherList = TaskListId(2);

  CachedTask task(
    int id, {
    int? parent,
    TaskStatus status = TaskStatus.needsAction,
    TaskListId taskListId = list,
  }) => CachedTask(
    id: TaskId(id),
    accountId: account,
    taskListId: taskListId,
    parentTaskId: parent == null ? null : TaskId(parent),
    remoteId: TaskRemoteId('synthetic-$id'),
    title: 'Task $id',
    notes: null,
    status: status,
    due: null,
  );

  TaskStatusChange complete(int id) => TaskStatusChange(
    taskId: TaskId(id),
    before: TaskStatus.needsAction,
    after: TaskStatus.completed,
  );

  // 1 parent: 2 open child, 3 completed child, 4 open child; 5 unrelated;
  // 6 parent: 7 open child.
  final tasks = <CachedTask>[
    task(1),
    task(2, parent: 1),
    task(3, parent: 1, status: TaskStatus.completed),
    task(4, parent: 1),
    task(5),
    task(6),
    task(7, parent: 6),
  ];

  test('the Undo window is the v1.5.3 thirty seconds', () {
    expect(taskCompletionUndoWindow, const Duration(seconds: 30));
  });

  test('completing a parent completes exactly its open subtasks', () {
    final plan = planTaskCompletion(
      tasks: tasks,
      taskId: const TaskId(1),
      status: TaskStatus.completed,
    );

    expect(plan.changes, <TaskStatusChange>[
      complete(1),
      complete(2),
      complete(4),
    ]);
    expect(plan.cascadedTaskIds, <TaskId>{const TaskId(2), const TaskId(4)});
    expect(plan.cascadedCount, 2);
  });

  test('completing a subtask never completes its parent', () {
    final plan = planTaskCompletion(
      tasks: tasks,
      taskId: const TaskId(2),
      status: TaskStatus.completed,
    );

    expect(plan.changes, <TaskStatusChange>[complete(2)]);
    expect(plan.cascadedTaskIds, isEmpty);
  });

  test('reopening never cascades', () {
    final completed = <CachedTask>[
      task(1, status: TaskStatus.completed),
      task(2, parent: 1, status: TaskStatus.completed),
    ];
    final plan = planTaskCompletion(
      tasks: completed,
      taskId: const TaskId(1),
      status: TaskStatus.needsAction,
    );

    expect(plan.changes, <TaskStatusChange>[
      const TaskStatusChange(
        taskId: TaskId(1),
        before: TaskStatus.completed,
        after: TaskStatus.needsAction,
      ),
    ]);
  });

  test('a task already in the requested status is an idempotent no-op', () {
    final plan = planTaskCompletion(
      tasks: <CachedTask>[
        task(1, status: TaskStatus.completed),
        task(2, parent: 1),
      ],
      taskId: const TaskId(1),
      status: TaskStatus.completed,
    );

    expect(plan.isEmpty, isTrue);
  });

  test('the cascade stays within the parent list', () {
    final plan = planTaskCompletion(
      tasks: <CachedTask>[
        task(1),
        task(2, parent: 1, taskListId: otherList),
      ],
      taskId: const TaskId(1),
      status: TaskStatus.completed,
    );

    expect(plan.changes, <TaskStatusChange>[complete(1)]);
  });

  test('bulk plans parents first and changes shared subtasks once', () {
    final plan = planCompletionOfTasks(
      tasks: tasks,
      // A selected subtask listed before its selected parent.
      taskIds: <TaskId>[const TaskId(4), const TaskId(6), const TaskId(1)],
      status: TaskStatus.completed,
    );

    expect(plan.changes, <TaskStatusChange>[
      complete(1),
      complete(2),
      complete(4),
      complete(6),
      complete(7),
    ]);
    expect(plan.cascadedTaskIds, <TaskId>{
      const TaskId(2),
      const TaskId(7),
    }, reason: 'a selected subtask is not reported as cascaded');
  });

  test('an unknown task is rejected', () {
    expect(
      () => planTaskCompletion(
        tasks: tasks,
        taskId: const TaskId(99),
        status: TaskStatus.completed,
      ),
      throwsArgumentError,
    );
  });

  test('Undo reverses only tasks that still have the written status', () {
    final recorded = <TaskStatusChange>[complete(1), complete(2), complete(4)];
    final plan = planTaskCompletionUndo(
      recorded: recorded,
      current: <TaskId, TaskStatus>{
        const TaskId(1): TaskStatus.completed,
        // Reopened by a later edit or by Google.
        const TaskId(2): TaskStatus.needsAction,
        // Task 4 was deleted.
      },
    );

    expect(plan.restore, <TaskStatusChange>[
      const TaskStatusChange(
        taskId: TaskId(1),
        before: TaskStatus.completed,
        after: TaskStatus.needsAction,
      ),
    ]);
    expect(plan.skipped, <TaskId>[const TaskId(2), const TaskId(4)]);
  });
}
