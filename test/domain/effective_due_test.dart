import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/effective_due.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'earliest unfinished direct child date becomes the parent effective date',
    () {
      final tasks = <CachedTask>[
        _task(1, due: TaskDate(2026, 8, 20)),
        _task(2, parent: 1, due: TaskDate(2026, 8, 18)),
        _task(3, parent: 1, due: TaskDate(2026, 8, 16)),
        _task(
          4,
          parent: 1,
          due: TaskDate(2026, 8, 15),
          status: TaskStatus.completed,
        ),
      ];

      final dates = effectiveDueDates(tasks);

      expect(dates[const TaskId(1)]!.explicit, TaskDate(2026, 8, 20));
      expect(dates[const TaskId(1)]!.fromChildren, TaskDate(2026, 8, 16));
      expect(dates[const TaskId(1)]!.effective, TaskDate(2026, 8, 16));
      expect(dates[const TaskId(2)]!.effective, TaskDate(2026, 8, 18));
    },
  );

  test('completed and undated children do not schedule an undated parent', () {
    final tasks = <CachedTask>[
      _task(1),
      _task(2, parent: 1),
      _task(
        3,
        parent: 1,
        due: TaskDate(2026, 8, 15),
        status: TaskStatus.completed,
      ),
    ];

    expect(effectiveDueDates(tasks)[const TaskId(1)]!.effective, isNull);
  });
}

CachedTask _task(
  int id, {
  int? parent,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: const TaskListId(10),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-task-$id'),
  title: 'Task $id',
  notes: null,
  status: status,
  due: due,
);
