import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/subtask_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports completed and total direct children only', () {
    final progress = projectDirectChildProgress(
      parentTaskId: const TaskId(10),
      tasks: <CachedTask>[
        _task(10),
        _task(11, parent: 10, status: TaskStatus.completed),
        _task(12, parent: 10),
        _task(13, parent: 12, status: TaskStatus.completed),
        _task(14, parent: 99, status: TaskStatus.completed),
      ],
    );

    expect(progress.completed, 1);
    expect(progress.total, 2);
    expect(progress.fraction, 0.5);
    expect(progress.label, '1 of 2 subtasks complete');
  });

  test('empty direct-child progress is explicit and has no fraction', () {
    const progress = DirectChildProgress(completed: 0, total: 0);

    expect(progress.fraction, isNull);
    expect(progress.label, 'No subtasks');
  });
}

CachedTask _task(
  int id, {
  int? parent,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: const TaskListId(7),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: null,
  title: 'Synthetic task',
  notes: null,
  status: status,
  due: null,
);
