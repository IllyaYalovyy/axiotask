import 'dart:collection';

import '../model/preferences.dart';
import '../model/tasks.dart';
import 'effective_due.dart';

enum SmartView { focus, upcoming, missed, unscheduled, all }

extension SmartViewDetails on SmartView {
  ViewKey get key => ViewKey(name);

  String get title => switch (this) {
    SmartView.focus => 'Focus',
    SmartView.upcoming => 'Upcoming',
    SmartView.missed => 'Missed',
    SmartView.unscheduled => 'Unscheduled',
    SmartView.all => 'All',
  };
}

sealed class TaskView {
  const TaskView();

  ViewKey get key;
}

final class SmartTaskView extends TaskView {
  const SmartTaskView(this.smartView);

  final SmartView smartView;

  @override
  ViewKey get key => smartView.key;

  @override
  bool operator ==(Object other) =>
      other is SmartTaskView && other.smartView == smartView;

  @override
  int get hashCode => smartView.hashCode;
}

final class TaskListView extends TaskView {
  const TaskListView(this.taskListId);

  final TaskListId taskListId;

  @override
  ViewKey get key => ViewKey('list:${taskListId.value}');

  @override
  bool operator ==(Object other) =>
      other is TaskListView && other.taskListId == taskListId;

  @override
  int get hashCode => taskListId.hashCode;
}

final class TaskViewRow {
  const TaskViewRow({required this.task, required this.effectiveDue});

  final CachedTask task;
  final EffectiveDue effectiveDue;
}

final class TaskViewProjection {
  TaskViewProjection({required this.view, required List<TaskViewRow> rows})
    : rows = UnmodifiableListView<TaskViewRow>(rows);

  final TaskView view;
  final List<TaskViewRow> rows;

  int get count => rows.length;
}

TaskViewProjection projectTaskView({
  required Iterable<CachedTask> tasks,
  required TaskView view,
  required ViewPreferences preferences,
  required Set<TaskListId> excludedTaskLists,
  required TaskDate today,
}) {
  final taskValues = tasks.toList(growable: false);
  final dates = effectiveDueDates(taskValues);
  final indexed = <({TaskViewRow row, int index})>[];
  for (var index = 0; index < taskValues.length; index += 1) {
    final task = taskValues[index];
    if (task.parentTaskId != null ||
        (!preferences.showCompleted && task.status == TaskStatus.completed) ||
        !_isMember(task, dates[task.id]!, view, excludedTaskLists, today)) {
      continue;
    }
    indexed.add((
      row: TaskViewRow(task: task, effectiveDue: dates[task.id]!),
      index: index,
    ));
  }

  indexed.sort((left, right) {
    if (left.row.task.status != right.row.task.status) {
      return left.row.task.status == TaskStatus.completed ? 1 : -1;
    }
    if (view case SmartTaskView(smartView: SmartView.focus)) {
      final leftOverdue = _isBefore(left.row.effectiveDue.effective, today);
      final rightOverdue = _isBefore(right.row.effectiveDue.effective, today);
      if (leftOverdue != rightOverdue) return leftOverdue ? -1 : 1;
    }
    final compared = _compareRows(left, right, preferences.sort, view);
    return compared == 0 ? left.index.compareTo(right.index) : compared;
  });

  return TaskViewProjection(
    view: view,
    rows: indexed.map((value) => value.row).toList(growable: false),
  );
}

bool _isMember(
  CachedTask task,
  EffectiveDue due,
  TaskView view,
  Set<TaskListId> excludedTaskLists,
  TaskDate today,
) {
  if (view case TaskListView(:final taskListId)) {
    return task.taskListId == taskListId;
  }
  final smartView = (view as SmartTaskView).smartView;
  if (excludedTaskLists.contains(task.taskListId)) return false;
  final effective = due.effective;
  return switch (smartView) {
    SmartView.focus =>
      effective != null &&
          compareTaskDates(effective, addTaskDateDays(today, 7)) < 0,
    SmartView.upcoming =>
      effective != null &&
          compareTaskDates(effective, today) > 0 &&
          compareTaskDates(effective, addTaskDateDays(today, 14)) <= 0,
    SmartView.missed =>
      effective != null && compareTaskDates(effective, today) < 0,
    SmartView.unscheduled => effective == null,
    SmartView.all => true,
  };
}

int _compareRows(
  ({TaskViewRow row, int index}) left,
  ({TaskViewRow row, int index}) right,
  ViewSort sort,
  TaskView view,
) {
  if (sort == ViewSort.manual &&
      view is SmartTaskView &&
      view.smartView == SmartView.missed) {
    return _compareNullableDates(
      left.row.effectiveDue.effective,
      right.row.effectiveDue.effective,
    );
  }
  return switch (sort) {
    ViewSort.manual => 0,
    ViewSort.effectiveDue => _compareNullableDates(
      left.row.effectiveDue.effective,
      right.row.effectiveDue.effective,
    ),
    ViewSort.title => left.row.task.title.toLowerCase().compareTo(
      right.row.task.title.toLowerCase(),
    ),
    ViewSort.created => right.index.compareTo(left.index),
  };
}

int _compareNullableDates(TaskDate? left, TaskDate? right) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  return compareTaskDates(left, right);
}

bool _isBefore(TaskDate? value, TaskDate boundary) =>
    value != null && compareTaskDates(value, boundary) < 0;
