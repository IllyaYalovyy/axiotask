import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/date_workflow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PAR-TASK-007 local calendar shortcuts', () {
    test('today, tomorrow, and next week use the injected local date', () {
      final today = TaskDate(2026, 8, 15);

      expect(resolveDateShortcut(today, DateShortcut.today), today);
      expect(
        resolveDateShortcut(today, DateShortcut.tomorrow),
        TaskDate(2026, 8, 16),
      );
      expect(
        resolveDateShortcut(today, DateShortcut.nextWeek),
        TaskDate(2026, 8, 22),
      );
      expect(resolveDateShortcut(today, DateShortcut.clear), isNull);
    });

    test('next month clamps at the last local calendar day', () {
      expect(
        resolveDateShortcut(TaskDate(2027, 1, 31), DateShortcut.nextMonth),
        TaskDate(2027, 2, 28),
      );
      expect(
        resolveDateShortcut(TaskDate(2028, 1, 31), DateShortcut.nextMonth),
        TaskDate(2028, 2, 29),
      );
      expect(
        resolveDateShortcut(TaskDate(2026, 12, 31), DateShortcut.nextMonth),
        TaskDate(2027, 1, 31),
      );
    });
  });

  group('PAR-TASK-006 due consistency cascade', () {
    test('a later parent moves only earlier explicitly dated children', () {
      final result = planDueCascade(
        tasks: <CachedTask>[
          _task(1, due: TaskDate(2026, 8, 10)),
          _task(2, parent: 1, due: TaskDate(2026, 8, 5)),
          _task(3, parent: 1, due: TaskDate(2026, 8, 20)),
          _task(4, parent: 1),
          _task(
            5,
            parent: 1,
            due: TaskDate(2026, 8, 1),
            status: TaskStatus.completed,
          ),
        ],
        editedTaskId: const TaskId(1),
        selectedDue: TaskDate(2026, 8, 15),
      );

      expect(result.cascadedParent, isFalse);
      expect(result.changes, <DueDateChange>[
        DueDateChange(
          taskId: const TaskId(1),
          before: TaskDate(2026, 8, 10),
          after: TaskDate(2026, 8, 15),
        ),
        DueDateChange(
          taskId: const TaskId(2),
          before: TaskDate(2026, 8, 5),
          after: TaskDate(2026, 8, 15),
        ),
        DueDateChange(
          taskId: const TaskId(5),
          before: TaskDate(2026, 8, 1),
          after: TaskDate(2026, 8, 15),
        ),
      ]);
    });

    test('an earlier child pulls its already dated parent earlier', () {
      final result = planDueCascade(
        tasks: <CachedTask>[
          _task(1, due: TaskDate(2026, 8, 10)),
          _task(2, parent: 1, due: TaskDate(2026, 8, 12)),
          _task(3, parent: 1, due: TaskDate(2026, 8, 25)),
        ],
        editedTaskId: const TaskId(2),
        selectedDue: TaskDate(2026, 8, 5),
      );

      expect(result.cascadedParent, isTrue);
      expect(result.changes.map((change) => change.taskId), const <TaskId>[
        TaskId(2),
        TaskId(1),
      ]);
      expect(result.changes.last.after, TaskDate(2026, 8, 5));
    });

    test('clear and an undated parent never cascade', () {
      final tasks = <CachedTask>[
        _task(1),
        _task(2, parent: 1, due: TaskDate(2026, 8, 12)),
      ];

      expect(
        planDueCascade(
          tasks: tasks,
          editedTaskId: const TaskId(2),
          selectedDue: null,
        ).changes,
        <DueDateChange>[
          DueDateChange(
            taskId: const TaskId(2),
            before: TaskDate(2026, 8, 12),
            after: null,
          ),
        ],
      );
      expect(
        planDueCascade(
          tasks: tasks,
          editedTaskId: const TaskId(2),
          selectedDue: TaskDate(2026, 8, 1),
        ).cascadedCount,
        0,
      );
    });

    test('selecting the existing date with no cascade is a no-op', () {
      final plan = planDueCascade(
        tasks: <CachedTask>[_task(1, due: TaskDate(2026, 8, 15))],
        editedTaskId: const TaskId(1),
        selectedDue: TaskDate(2026, 8, 15),
      );

      expect(plan.changes, isEmpty);
      expect(plan.cascadedCount, 0);
    });
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
  remoteId: TaskRemoteId('synthetic-date-task-$id'),
  title: 'Synthetic task $id',
  notes: null,
  status: status,
  due: due,
);
