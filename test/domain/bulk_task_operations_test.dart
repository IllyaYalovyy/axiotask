import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/bulk_task_operations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PAR-BULK-002 command validation', () {
    test('an empty selection is rejected before repository work', () {
      final failure = validateBulkTaskCommand(
        const BulkCompleteTasksCommand(
          accountId: AccountId(1),
          taskIds: <TaskId>{},
        ),
      );

      expect(failure?.code, 'bulk_tasks.empty_selection');
    });
  });

  group('PAR-BULK-002 mixed hierarchy planning', () {
    test('one due plan deduplicates selected and cascaded resources', () {
      final plan = planBulkDueChanges(
        tasks: <CachedTask>[
          _task(1, due: TaskDate(2026, 8, 10)),
          _task(2, parent: 1, due: TaskDate(2026, 8, 5)),
          _task(3, parent: 1, due: TaskDate(2026, 8, 20)),
        ],
        selectedTaskIds: <TaskId>{const TaskId(1), const TaskId(2)},
        selectedDue: TaskDate(2026, 8, 15),
      );

      expect(plan.map((change) => change.taskId), const <TaskId>[
        TaskId(1),
        TaskId(2),
      ]);
      expect(
        plan.every((change) => change.after == TaskDate(2026, 8, 15)),
        isTrue,
      );
    });

    test('an earlier selected child pulls its unselected dated parent', () {
      final plan = planBulkDueChanges(
        tasks: <CachedTask>[
          _task(1, due: TaskDate(2026, 8, 10)),
          _task(2, parent: 1, due: TaskDate(2026, 8, 12)),
        ],
        selectedTaskIds: <TaskId>{const TaskId(2)},
        selectedDue: TaskDate(2026, 8, 5),
      );

      expect(plan.map((change) => change.taskId), const <TaskId>[
        TaskId(1),
        TaskId(2),
      ]);
    });

    test('a selected parent owns one cross-list move for its subtree', () {
      final roots = selectBulkMoveRoots(
        tasks: <CachedTask>[_task(1), _task(2, parent: 1), _task(3)],
        selectedTaskIds: <TaskId>{
          const TaskId(1),
          const TaskId(2),
          const TaskId(3),
        },
      );

      expect(roots.map((task) => task.id), const <TaskId>[
        TaskId(1),
        TaskId(3),
      ]);
    });
  });
}

CachedTask _task(int id, {int? parent, TaskDate? due}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: const TaskListId(10),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-bulk-task-$id'),
  title: 'Synthetic task $id',
  notes: null,
  status: TaskStatus.needsAction,
  due: due,
);
