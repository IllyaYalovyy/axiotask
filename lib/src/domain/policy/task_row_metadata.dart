import '../model/tasks.dart';
import 'effective_due.dart';
import 'smart_views.dart';
import 'subtask_progress.dart';
import 'task_date_format.dart';

/// How pressing a due date is, relative to the local calendar day.
enum DueUrgency { overdue, today, later }

/// A due date in the words a task row shows and the words a screen reader
/// says. [text] is compact for the eye ("3d overdue", "in 2d"); [spoken] is
/// a phrase ("3 days ago", "in 2 days"), never a glyph.
final class DueDescription {
  const DueDescription({
    required this.date,
    required this.text,
    required this.spoken,
    required this.urgency,
  });

  final TaskDate date;
  final String text;
  final String spoken;
  final DueUrgency urgency;

  @override
  bool operator ==(Object other) =>
      other is DueDescription &&
      date == other.date &&
      text == other.text &&
      spoken == other.spoken &&
      urgency == other.urgency;

  @override
  int get hashCode => Object.hash(date, text, spoken, urgency);
}

/// Describes [due] relative to [today], as v1.5.3's task rows did: the
/// nearest week is relative ("yesterday", "today", "tomorrow", "in 3d",
/// "5d overdue") and anything further is an absolute day ("Dec 2", with the
/// year when it is not [today]'s).
DueDescription describeDue(TaskDate due, TaskDate today) {
  final days = _daysBetween(today, due);
  final absolute = formatAbsoluteTaskDate(due, today);
  final (String text, String spoken) = switch (days) {
    < -1 => ('${-days}d overdue', '${-days} days ago'),
    -1 => ('yesterday', 'yesterday'),
    0 => ('today', 'today'),
    1 => ('tomorrow', 'tomorrow'),
    < 7 => ('in ${days}d', 'in $days days'),
    _ => (absolute, absolute),
  };
  return DueDescription(
    date: due,
    text: text,
    spoken: spoken,
    urgency: days < 0
        ? DueUrgency.overdue
        : days == 0
        ? DueUrgency.today
        : DueUrgency.later,
  );
}

int _daysBetween(TaskDate from, TaskDate to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The facts a task row shows beneath its title, derived from cached state
/// only: notes, due information, subtask progress and, in a view that spans
/// lists, the list the task lives in.
final class TaskRowMetadata {
  const TaskRowMetadata({
    required this.hasNotes,
    required this.ownDue,
    required this.subtaskDue,
    required this.progress,
    required this.listTitle,
  });

  final bool hasNotes;

  /// The task's own due date, if it has one.
  final DueDescription? ownDue;

  /// The earliest open subtask's date when it is earlier than the task's own
  /// (or the task has none): the date that places the task in date views.
  /// It is read-only on the row because it belongs to the subtask.
  final DueDescription? subtaskDue;

  /// Direct subtask progress, or null when the task has no subtasks.
  final DirectChildProgress? progress;

  /// The task's list in a smart view (which spans lists); null in a list.
  final String? listTitle;

  bool get isUndated => ownDue == null && subtaskDue == null;

  /// Each fact as a short phrase for assistive technology, in display order.
  List<String> get spokenParts => <String>[
    if (hasNotes) 'Has notes',
    if (ownDue case final due?) 'Due ${due.spoken}',
    if (subtaskDue case final due?) 'Subtask due ${due.spoken}',
    if (isUndated) 'No due date',
    if (progress case final value?) value.label,
    if (listTitle case final title?) 'In $title',
  ];

  String get spokenLabel => spokenParts.join(', ');

  @override
  bool operator ==(Object other) =>
      other is TaskRowMetadata &&
      hasNotes == other.hasNotes &&
      ownDue == other.ownDue &&
      subtaskDue == other.subtaskDue &&
      progress == other.progress &&
      listTitle == other.listTitle;

  @override
  int get hashCode =>
      Object.hash(hasNotes, ownDue, subtaskDue, progress, listTitle);
}

/// Projects the row metadata of [task], whose effective due date is
/// [effectiveDue], among [tasks] (the cached account, for subtasks) in
/// [view]. [listTitles] names the lists a smart view row can belong to.
TaskRowMetadata projectTaskRowMetadata({
  required CachedTask task,
  required EffectiveDue effectiveDue,
  required Iterable<CachedTask> tasks,
  required TaskView view,
  required Map<TaskListId, String> listTitles,
  required TaskDate today,
}) {
  final progress = projectDirectChildProgress(
    parentTaskId: task.id,
    tasks: tasks,
  );
  final own = effectiveDue.explicit;
  final fromChildren = effectiveDue.fromChildren;
  return TaskRowMetadata(
    hasNotes: task.notes?.trim().isNotEmpty ?? false,
    ownDue: own == null ? null : describeDue(own, today),
    subtaskDue:
        fromChildren == null ||
            (own != null && compareTaskDates(fromChildren, own) >= 0)
        ? null
        : describeDue(fromChildren, today),
    progress: progress.total == 0 ? null : progress,
    listTitle: view is SmartTaskView ? listTitles[task.taskListId] : null,
  );
}
