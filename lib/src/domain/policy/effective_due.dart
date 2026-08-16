import 'dart:collection';

import '../model/tasks.dart';

final class EffectiveDue {
  const EffectiveDue({
    required this.explicit,
    required this.fromChildren,
    required this.effective,
  });

  final TaskDate? explicit;
  final TaskDate? fromChildren;
  final TaskDate? effective;
}

Map<TaskId, EffectiveDue> effectiveDueDates(Iterable<CachedTask> tasks) {
  final values = tasks.toList(growable: false);
  final earliestChildDate = <TaskId, TaskDate>{};
  for (final task in values) {
    final parentId = task.parentTaskId;
    final due = task.due;
    if (parentId == null ||
        due == null ||
        task.status == TaskStatus.completed) {
      continue;
    }
    final current = earliestChildDate[parentId];
    if (current == null || compareTaskDates(due, current) < 0) {
      earliestChildDate[parentId] = due;
    }
  }

  final result = <TaskId, EffectiveDue>{};
  for (final task in values) {
    final fromChildren = task.parentTaskId == null
        ? earliestChildDate[task.id]
        : null;
    result[task.id] = EffectiveDue(
      explicit: task.due,
      fromChildren: fromChildren,
      effective: earliestTaskDate(task.due, fromChildren),
    );
  }
  return UnmodifiableMapView<TaskId, EffectiveDue>(result);
}

TaskDate? earliestTaskDate(TaskDate? left, TaskDate? right) {
  if (left == null) return right;
  if (right == null) return left;
  return compareTaskDates(left, right) <= 0 ? left : right;
}

int compareTaskDates(TaskDate left, TaskDate right) {
  final year = left.year.compareTo(right.year);
  if (year != 0) return year;
  final month = left.month.compareTo(right.month);
  if (month != 0) return month;
  return left.day.compareTo(right.day);
}

TaskDate addTaskDateDays(TaskDate value, int days) {
  final shifted = DateTime.utc(
    value.year,
    value.month,
    value.day,
  ).add(Duration(days: days));
  return TaskDate(shifted.year, shifted.month, shifted.day);
}
