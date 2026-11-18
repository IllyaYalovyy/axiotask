import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/task_traversal.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = TaskId(1);
const _b = TaskId(2);
const _c = TaskId(3);
const _d = TaskId(4);

CachedTask _task(int id, {int? parent}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: const TaskListId(7),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: null,
  title: 'Task $id',
  notes: null,
  status: TaskStatus.needsAction,
  due: null,
);

void main() {
  group('taskNeighbors', () {
    test('walks the order by identity and stops at both boundaries', () {
      const order = <TaskId>[_a, _b, _c];
      expect(
        taskNeighbors(selected: _a, order: order),
        const TaskNeighbors(next: _b),
      );
      expect(
        taskNeighbors(selected: _b, order: order),
        const TaskNeighbors(previous: _a, next: _c),
      );
      expect(
        taskNeighbors(selected: _c, order: order),
        const TaskNeighbors(previous: _b),
      );
    });

    test('a single-task order and an empty order have no neighbours', () {
      expect(
        taskNeighbors(selected: _a, order: const <TaskId>[_a]),
        TaskNeighbors.none,
      );
      expect(
        taskNeighbors(selected: _a, order: const <TaskId>[]),
        TaskNeighbors.none,
      );
    });

    test('a reordered collection is walked in its current order', () {
      expect(
        taskNeighbors(selected: _b, order: const <TaskId>[_c, _a, _b]),
        const TaskNeighbors(previous: _a),
      );
    });

    test('a task that left the order leads to its surviving neighbours, '
        'never one task too far', () {
      final anchor = TaskTraversalAnchor(
        taskId: _b,
        order: const <TaskId>[_a, _b, _c, _d],
      );
      // B was completed while completed tasks are hidden.
      expect(
        taskNeighbors(
          selected: _b,
          order: const <TaskId>[_a, _c, _d],
          anchor: anchor,
        ),
        const TaskNeighbors(previous: _a, next: _c),
      );
      // Its successor was then deleted as well.
      expect(
        taskNeighbors(
          selected: _b,
          order: const <TaskId>[_a, _d],
          anchor: anchor,
        ),
        const TaskNeighbors(previous: _a, next: _d),
      );
      // Everything around it is gone.
      expect(
        taskNeighbors(selected: _b, order: const <TaskId>[], anchor: anchor),
        TaskNeighbors.none,
      );
    });

    test('an anchor recorded for another task is ignored', () {
      expect(
        taskNeighbors(
          selected: _b,
          order: const <TaskId>[_a, _c],
          anchor: TaskTraversalAnchor(
            taskId: _c,
            order: const <TaskId>[_a, _b, _c],
          ),
        ),
        TaskNeighbors.none,
      );
    });

    test('the anchor snapshots its order', () {
      final source = <TaskId>[_a, _b];
      final anchor = TaskTraversalAnchor(taskId: _a, order: source);
      source.add(_c);
      expect(anchor.order, const <TaskId>[_a, _b]);
      expect(() => anchor.order.add(_d), throwsUnsupportedError);
    });
  });

  group('taskTraversalOrder', () {
    final parent = _task(1);
    final firstChild = _task(2, parent: 1);
    final other = _task(3);
    final secondChild = _task(4, parent: 1);
    final otherChild = _task(5, parent: 3);
    final all = <CachedTask>[
      parent,
      firstChild,
      other,
      secondChild,
      otherChild,
    ];

    test('a top-level task walks the visible collection as given', () {
      expect(
        taskTraversalOrder(
          task: other,
          tasks: all,
          visibleTasks: <CachedTask>[other, parent],
        ),
        const <TaskId>[TaskId(3), TaskId(1)],
      );
    });

    test('a subtask walks its own parent\'s subtasks only', () {
      expect(
        taskTraversalOrder(
          task: secondChild,
          tasks: all,
          visibleTasks: <CachedTask>[parent, other],
        ),
        const <TaskId>[TaskId(2), TaskId(4)],
      );
    });
  });
}
