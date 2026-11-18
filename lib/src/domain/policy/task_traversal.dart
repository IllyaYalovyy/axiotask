import 'dart:collection';

import '../model/tasks.dart';

/// The tasks Previous and Next in task details lead to. Either is null at a
/// boundary of the ordering, or when the open task has no place in it.
final class TaskNeighbors {
  const TaskNeighbors({this.previous, this.next});

  static const TaskNeighbors none = TaskNeighbors();

  final TaskId? previous;
  final TaskId? next;

  @override
  bool operator ==(Object other) =>
      other is TaskNeighbors &&
      other.previous == previous &&
      other.next == next;

  @override
  int get hashCode => Object.hash(previous, next);

  @override
  String toString() => 'TaskNeighbors(previous: $previous, next: $next)';
}

/// The last ordering in which [taskId] had a place.
///
/// When the open task leaves the ordering it is walked in (it is completed
/// while completed tasks are hidden, rescheduled out of a smart view or moved
/// to another list) Previous and Next still lead to the tasks that surrounded
/// it, as long as those are still shown, instead of an index that now points
/// one task too far.
final class TaskTraversalAnchor {
  TaskTraversalAnchor({required this.taskId, required Iterable<TaskId> order})
    : order = UnmodifiableListView<TaskId>(order.toList(growable: false));

  final TaskId taskId;
  final List<TaskId> order;
}

/// The ordering task details walk for [task]: the visible collection for a
/// top-level task, and its parent's subtasks, as details lists them, for a
/// subtask.
List<TaskId> taskTraversalOrder({
  required CachedTask task,
  required Iterable<CachedTask> tasks,
  required Iterable<CachedTask> visibleTasks,
}) {
  final parentTaskId = task.parentTaskId;
  final source = parentTaskId == null
      ? visibleTasks
      : tasks.where((candidate) => candidate.parentTaskId == parentTaskId);
  return List<TaskId>.unmodifiable(source.map((candidate) => candidate.id));
}

/// Previous/Next for [selected] in the current [order], by identity.
///
/// A task without a place in [order] uses [anchor], the last ordering that
/// held it: its nearest predecessor and successor there that [order] still
/// shows. Without an applicable anchor it has no neighbours.
TaskNeighbors taskNeighbors({
  required TaskId selected,
  required List<TaskId> order,
  TaskTraversalAnchor? anchor,
}) {
  final index = order.indexOf(selected);
  if (index >= 0) {
    return TaskNeighbors(
      previous: index > 0 ? order[index - 1] : null,
      next: index < order.length - 1 ? order[index + 1] : null,
    );
  }
  if (anchor == null || anchor.taskId != selected) return TaskNeighbors.none;
  final anchored = anchor.order.indexOf(selected);
  if (anchored < 0) return TaskNeighbors.none;
  final shown = order.toSet();
  TaskId? previous;
  for (var i = anchored - 1; i >= 0 && previous == null; i -= 1) {
    if (shown.contains(anchor.order[i])) previous = anchor.order[i];
  }
  TaskId? next;
  for (var i = anchored + 1; i < anchor.order.length && next == null; i += 1) {
    if (shown.contains(anchor.order[i])) next = anchor.order[i];
  }
  return TaskNeighbors(previous: previous, next: next);
}
