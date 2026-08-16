import '../model/tasks.dart';
import 'date_workflow.dart';
import 'effective_due.dart';

List<DueDateChange> planBulkDueChanges({
  required Iterable<CachedTask> tasks,
  required Set<TaskId> selectedTaskIds,
  required TaskDate? selectedDue,
}) {
  final values = tasks.toList(growable: false);
  final byId = <TaskId, CachedTask>{for (final task in values) task.id: task};
  if (!selectedTaskIds.every(byId.containsKey)) {
    throw ArgumentError('Every selected task must be present.');
  }
  final selected = selectedTaskIds.toList(growable: false)
    ..sort((left, right) => left.value.compareTo(right.value));
  final desired = <TaskId, TaskDate?>{
    for (final task in values) task.id: task.due,
  };
  for (final taskId in selected) {
    desired[taskId] = selectedDue;
  }
  if (selectedDue != null) {
    for (final taskId in selected) {
      final task = byId[taskId]!;
      final parentId = task.parentTaskId;
      if (parentId != null) {
        final parentDue = desired[parentId];
        if (parentDue != null && compareTaskDates(selectedDue, parentDue) < 0) {
          desired[parentId] = selectedDue;
        }
        continue;
      }
      for (final child in values.where(
        (candidate) => candidate.parentTaskId == task.id,
      )) {
        final childDue = desired[child.id];
        if (childDue != null && compareTaskDates(childDue, selectedDue) < 0) {
          desired[child.id] = selectedDue;
        }
      }
    }
  }
  final changes = <DueDateChange>[
    for (final task in values)
      if (task.due != desired[task.id])
        DueDateChange(
          taskId: task.id,
          before: task.due,
          after: desired[task.id],
        ),
  ]..sort((left, right) => left.taskId.value.compareTo(right.taskId.value));
  return List<DueDateChange>.unmodifiable(changes);
}

List<CachedTask> selectBulkMoveRoots({
  required Iterable<CachedTask> tasks,
  required Set<TaskId> selectedTaskIds,
}) {
  final values = tasks.toList(growable: false);
  final byId = <TaskId, CachedTask>{for (final task in values) task.id: task};
  if (!selectedTaskIds.every(byId.containsKey)) {
    throw ArgumentError('Every selected task must be present.');
  }
  final roots = <CachedTask>[];
  for (final taskId in selectedTaskIds) {
    final task = byId[taskId]!;
    if (task.parentTaskId == null ||
        !selectedTaskIds.contains(task.parentTaskId)) {
      roots.add(task);
    }
  }
  roots.sort((left, right) => left.id.value.compareTo(right.id.value));
  return List<CachedTask>.unmodifiable(roots);
}
