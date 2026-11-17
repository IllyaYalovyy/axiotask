import '../model/tasks.dart';

/// How long a completion stays undoable, as in v1.5.3.
const Duration taskCompletionUndoWindow = Duration(seconds: 30);

/// One status write that a completion command makes.
final class TaskStatusChange {
  const TaskStatusChange({
    required this.taskId,
    required this.before,
    required this.after,
  });

  final TaskId taskId;
  final TaskStatus before;
  final TaskStatus after;

  @override
  bool operator ==(Object other) =>
      other is TaskStatusChange &&
      other.taskId == taskId &&
      other.before == before &&
      other.after == after;

  @override
  int get hashCode => Object.hash(taskId, before, after);

  @override
  String toString() =>
      'TaskStatusChange(${taskId.value}: ${before.name} -> ${after.name})';
}

/// The exact status writes of one completion command.
///
/// [changes] lists every task the command changes, each parent before its
/// subtasks, so Google observes a reopened parent before its reopened
/// subtasks. [cascadedTaskIds] are the subtasks changed only because their
/// parent completed.
final class TaskCompletionPlan {
  TaskCompletionPlan({
    required List<TaskStatusChange> changes,
    required Set<TaskId> cascadedTaskIds,
  }) : changes = List<TaskStatusChange>.unmodifiable(changes),
       cascadedTaskIds = Set<TaskId>.unmodifiable(cascadedTaskIds);

  final List<TaskStatusChange> changes;
  final Set<TaskId> cascadedTaskIds;

  bool get isEmpty => changes.isEmpty;

  int get cascadedCount => cascadedTaskIds.length;
}

/// Plans one completion or reopen command.
///
/// Completing an open task also completes every open descendant in the same
/// list, as Google does server-side and as v1.5.3 did locally. Already
/// completed descendants are left untouched, so Undo cannot reopen them.
/// Completing a subtask never changes its parent, and reopening never
/// cascades. A task that already has [status] yields an empty plan, so a
/// repeated command is an idempotent no-op.
TaskCompletionPlan planTaskCompletion({
  required Iterable<CachedTask> tasks,
  required TaskId taskId,
  required TaskStatus status,
}) => planCompletionOfTasks(
  tasks: tasks,
  taskIds: <TaskId>[taskId],
  status: status,
);

/// Plans the completion of several tasks as one command (bulk selection).
///
/// Each selected task follows [planTaskCompletion]; a task reached through
/// more than one selected ancestor is changed once. Selected tasks are
/// planned shallowest first (then by id), each followed by its descendants,
/// so every parent precedes its subtasks in [TaskCompletionPlan.changes].
TaskCompletionPlan planCompletionOfTasks({
  required Iterable<CachedTask> tasks,
  required Iterable<TaskId> taskIds,
  required TaskStatus status,
}) {
  final byId = <TaskId, CachedTask>{for (final task in tasks) task.id: task};
  final childrenByParent = <TaskId, List<CachedTask>>{};
  for (final task in byId.values) {
    final parent = task.parentTaskId;
    if (parent == null) continue;
    (childrenByParent[parent] ??= <CachedTask>[]).add(task);
  }
  for (final children in childrenByParent.values) {
    children.sort((left, right) => left.id.value.compareTo(right.id.value));
  }
  final selected = taskIds.toSet();
  for (final taskId in selected) {
    if (!byId.containsKey(taskId)) {
      throw ArgumentError.value(taskId, 'taskIds', 'is not a known task');
    }
  }
  int depth(TaskId id) {
    var result = 0;
    final seen = <TaskId>{id};
    for (
      var parent = byId[id]?.parentTaskId;
      parent != null && seen.add(parent);
      parent = byId[parent]?.parentTaskId
    ) {
      result += 1;
    }
    return result;
  }

  final ordered = selected.toList()
    ..sort((left, right) {
      final byDepth = depth(left).compareTo(depth(right));
      return byDepth != 0 ? byDepth : left.value.compareTo(right.value);
    });
  final changes = <TaskStatusChange>[];
  final changed = <TaskId>{};
  final cascaded = <TaskId>{};
  for (final taskId in ordered) {
    final task = byId[taskId]!;
    if (task.status == status || changed.contains(task.id)) continue;
    changes.add(
      TaskStatusChange(taskId: task.id, before: task.status, after: status),
    );
    changed.add(task.id);
    if (status != TaskStatus.completed) continue;
    final frontier = <TaskId>[task.id];
    final visited = <TaskId>{task.id};
    while (frontier.isNotEmpty) {
      final parent = frontier.removeAt(0);
      for (final child in childrenByParent[parent] ?? const <CachedTask>[]) {
        if (child.taskListId != task.taskListId || !visited.add(child.id)) {
          continue;
        }
        frontier.add(child.id);
        if (child.status == TaskStatus.completed ||
            changed.contains(child.id)) {
          continue;
        }
        changes.add(
          TaskStatusChange(
            taskId: child.id,
            before: child.status,
            after: TaskStatus.completed,
          ),
        );
        changed.add(child.id);
        if (!selected.contains(child.id)) cascaded.add(child.id);
      }
    }
  }
  return TaskCompletionPlan(changes: changes, cascadedTaskIds: cascaded);
}

/// Which recorded changes an Undo may still reverse.
final class TaskCompletionUndoPlan {
  TaskCompletionUndoPlan({
    required List<TaskStatusChange> restore,
    required List<TaskId> skipped,
  }) : restore = List<TaskStatusChange>.unmodifiable(restore),
       skipped = List<TaskId>.unmodifiable(skipped);

  /// Reverse writes (after → before), in the recorded parent-first order.
  final List<TaskStatusChange> restore;

  /// Recorded tasks that are gone or whose status changed since the command.
  final List<TaskId> skipped;
}

/// Plans an Undo of [recorded] against the [current] stored statuses.
///
/// A task is restored only while it still has the status the command wrote.
/// A task that was deleted, or whose status was changed afterwards by another
/// edit or by Google, is skipped, so Undo never overwrites a later change.
TaskCompletionUndoPlan planTaskCompletionUndo({
  required List<TaskStatusChange> recorded,
  required Map<TaskId, TaskStatus> current,
}) {
  final restore = <TaskStatusChange>[];
  final skipped = <TaskId>[];
  for (final change in recorded) {
    if (current[change.taskId] != change.after) {
      skipped.add(change.taskId);
      continue;
    }
    restore.add(
      TaskStatusChange(
        taskId: change.taskId,
        before: change.after,
        after: change.before,
      ),
    );
  }
  return TaskCompletionUndoPlan(restore: restore, skipped: skipped);
}
