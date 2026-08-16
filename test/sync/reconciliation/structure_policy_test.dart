import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/reconciliation/structure_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = TaskStructureSnapshot(
    taskListId: TaskListId(1),
    parentTaskId: null,
    previousTaskId: TaskId(10),
    siblingOrderFingerprint: 'base-order',
  );

  test('REC-008/010/012 any observed Google structure change wins', () {
    for (final remote in <TaskStructureSnapshot>[
      const TaskStructureSnapshot(
        taskListId: TaskListId(1),
        parentTaskId: TaskId(20),
        previousTaskId: null,
        siblingOrderFingerprint: 'remote-parent',
      ),
      const TaskStructureSnapshot(
        taskListId: TaskListId(2),
        parentTaskId: null,
        previousTaskId: null,
        siblingOrderFingerprint: 'remote-list',
      ),
      const TaskStructureSnapshot(
        taskListId: TaskListId(1),
        parentTaskId: null,
        previousTaskId: TaskId(11),
        siblingOrderFingerprint: 'remote-order',
      ),
    ]) {
      expect(
        reconcileTaskStructure(
          base: base,
          local: const TaskPlacement(
            taskListId: TaskListId(1),
            parentTaskId: null,
            previousTaskId: null,
          ),
          remote: remote,
        ),
        StructureWinner.google,
      );
    }
  });

  test('REC-009/013 unchanged Google structure keeps local placement', () {
    expect(
      reconcileTaskStructure(
        base: base,
        local: const TaskPlacement(
          taskListId: TaskListId(2),
          parentTaskId: null,
          previousTaskId: TaskId(30),
        ),
        remote: base,
      ),
      StructureWinner.local,
    );
  });

  test('read-back matching desired placement confirms without replay', () {
    expect(
      reconcileTaskStructure(
        base: base,
        local: const TaskPlacement(
          taskListId: TaskListId(1),
          parentTaskId: null,
          previousTaskId: TaskId(10),
        ),
        remote: base,
      ),
      StructureWinner.confirmed,
    );
  });
}
