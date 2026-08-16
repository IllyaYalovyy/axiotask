import 'dart:collection';

import '../model/tasks.dart';
import 'effective_due.dart';

enum DateShortcut { today, tomorrow, nextWeek, nextMonth, clear }

TaskDate? resolveDateShortcut(TaskDate today, DateShortcut shortcut) =>
    switch (shortcut) {
      DateShortcut.today => today,
      DateShortcut.tomorrow => addTaskDateDays(today, 1),
      DateShortcut.nextWeek => addTaskDateDays(today, 7),
      DateShortcut.nextMonth => _addMonthClamped(today),
      DateShortcut.clear => null,
    };

final class DueDateChange {
  const DueDateChange({
    required this.taskId,
    required this.before,
    required this.after,
  });

  final TaskId taskId;
  final TaskDate? before;
  final TaskDate? after;

  @override
  bool operator ==(Object other) =>
      other is DueDateChange &&
      taskId == other.taskId &&
      before == other.before &&
      after == other.after;

  @override
  int get hashCode => Object.hash(taskId, before, after);
}

final class DueCascadePlan {
  DueCascadePlan({
    required List<DueDateChange> changes,
    required this.cascadedParent,
  }) : changes = UnmodifiableListView<DueDateChange>(changes);

  final List<DueDateChange> changes;
  final bool cascadedParent;

  int get cascadedCount => changes.isEmpty ? 0 : changes.length - 1;
}

/// Plans the complete local due-date acknowledgement before persistence.
///
/// The edited row wins. A dated parent is pulled earlier when its child is set
/// earlier; dated direct children are pushed later when their parent is set
/// later. Clearing and undated related rows do not manufacture other dates.
DueCascadePlan planDueCascade({
  required Iterable<CachedTask> tasks,
  required TaskId editedTaskId,
  required TaskDate? selectedDue,
}) {
  final values = tasks.toList(growable: false);
  final edited = values.where((task) => task.id == editedTaskId).firstOrNull;
  if (edited == null) {
    throw ArgumentError.value(editedTaskId, 'editedTaskId', 'was not found');
  }
  final changes = <DueDateChange>[
    DueDateChange(taskId: edited.id, before: edited.due, after: selectedDue),
  ];
  var cascadedParent = false;
  if (selectedDue == null) {
    return DueCascadePlan(changes: changes, cascadedParent: cascadedParent);
  }

  final parentId = edited.parentTaskId;
  if (parentId != null) {
    final parent = values.where((task) => task.id == parentId).firstOrNull;
    final parentDue = parent?.due;
    if (parent != null &&
        parentDue != null &&
        compareTaskDates(selectedDue, parentDue) < 0) {
      changes.add(
        DueDateChange(taskId: parent.id, before: parentDue, after: selectedDue),
      );
      cascadedParent = true;
    }
  } else {
    for (final child in values.where(
      (task) => task.parentTaskId == edited.id,
    )) {
      final childDue = child.due;
      if (childDue != null && compareTaskDates(childDue, selectedDue) < 0) {
        changes.add(
          DueDateChange(taskId: child.id, before: childDue, after: selectedDue),
        );
      }
    }
  }
  if (changes.length == 1 && changes.single.before == changes.single.after) {
    changes.clear();
  }
  return DueCascadePlan(changes: changes, cascadedParent: cascadedParent);
}

TaskDate _addMonthClamped(TaskDate value) {
  final monthIndex = value.month;
  final year = value.year + monthIndex ~/ 12;
  final month = monthIndex % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  return TaskDate(year, month, value.day.clamp(1, lastDay));
}
