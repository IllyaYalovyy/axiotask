import 'package:axiotask/src/app/desktop_task_drag.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final first = _task(11, 'First');
  final second = _task(12, 'Second');
  final third = _task(13, 'Third');
  final tasks = <CachedTask>[first, second, third];

  test('PAR-DESKTOP-003 row drops reuse canonical previous anchors', () {
    final before = DesktopTaskDragAdapter.reorder(
      payload: DesktopTaskDragPayload.fromTask(third),
      target: first,
      placement: DesktopTaskDropPlacement.before,
      canonicalSiblings: tasks,
      manualOrderEnabled: true,
    );
    final after = DesktopTaskDragAdapter.reorder(
      payload: DesktopTaskDragPayload.fromTask(first),
      target: second,
      placement: DesktopTaskDropPlacement.after,
      canonicalSiblings: tasks,
      manualOrderEnabled: true,
    );

    expect(
      before,
      const DesktopTaskDropIntent.reorder(
        taskId: TaskId(13),
        destinationTaskListId: TaskListId(7),
        parentTaskId: null,
        previousTaskId: null,
      ),
    );
    expect(
      after,
      const DesktopTaskDropIntent.reorder(
        taskId: TaskId(11),
        destinationTaskListId: TaskListId(7),
        parentTaskId: null,
        previousTaskId: TaskId(12),
      ),
    );
  });

  test('invalid, sorted, cross-scope, and no-op row targets are rejected', () {
    final payload = DesktopTaskDragPayload.fromTask(second);

    expect(
      DesktopTaskDragAdapter.reorder(
        payload: payload,
        target: first,
        placement: DesktopTaskDropPlacement.before,
        canonicalSiblings: tasks,
        manualOrderEnabled: false,
      ),
      isNull,
    );
    expect(
      DesktopTaskDragAdapter.reorder(
        payload: payload,
        target: _task(20, 'Other', taskListId: 8),
        placement: DesktopTaskDropPlacement.before,
        canonicalSiblings: tasks,
        manualOrderEnabled: true,
      ),
      isNull,
    );
    expect(
      DesktopTaskDragAdapter.reorder(
        payload: payload,
        target: second,
        placement: DesktopTaskDropPlacement.after,
        canonicalSiblings: tasks,
        manualOrderEnabled: true,
      ),
      isNull,
    );
    expect(
      DesktopTaskDragAdapter.reorder(
        payload: payload,
        target: first,
        placement: DesktopTaskDropPlacement.after,
        canonicalSiblings: tasks,
        manualOrderEnabled: true,
      ),
      isNull,
      reason: 'dropping second after first preserves canonical order',
    );
  });

  test('list drops move by stable identity and reject the source list', () {
    final payload = DesktopTaskDragPayload.fromTask(first);

    expect(
      DesktopTaskDragAdapter.moveToList(
        payload: payload,
        destinationTaskListId: const TaskListId(8),
      ),
      const DesktopTaskDropIntent.reorder(
        taskId: TaskId(11),
        destinationTaskListId: TaskListId(8),
        parentTaskId: null,
        previousTaskId: null,
      ),
    );
    expect(
      DesktopTaskDragAdapter.moveToList(
        payload: payload,
        destinationTaskListId: const TaskListId(7),
      ),
      isNull,
    );
  });

  test('autoscroll adapter is bounded and idle away from edges', () {
    expect(
      DesktopDragAutoscroll.targetOffset(
        currentOffset: 100,
        minOffset: 0,
        maxOffset: 500,
        pointerY: 10,
        viewportHeight: 200,
      ),
      36,
    );
    expect(
      DesktopDragAutoscroll.targetOffset(
        currentOffset: 100,
        minOffset: 0,
        maxOffset: 500,
        pointerY: 190,
        viewportHeight: 200,
      ),
      164,
    );
    expect(
      DesktopDragAutoscroll.targetOffset(
        currentOffset: 100,
        minOffset: 0,
        maxOffset: 500,
        pointerY: 100,
        viewportHeight: 400,
      ),
      isNull,
    );
  });
}

CachedTask _task(int id, String title, {int taskListId = 7}) => CachedTask(
  id: TaskId(id),
  accountId: AccountId(1),
  taskListId: TaskListId(taskListId),
  parentTaskId: null,
  remoteId: null,
  title: title,
  notes: null,
  status: TaskStatus.needsAction,
  due: null,
);
