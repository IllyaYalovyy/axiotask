import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/effective_due.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/policy/subtask_progress.dart';
import 'package:axiotask/src/domain/policy/task_row_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = TaskDate(2026, 11, 15);

  group('describeDue', () {
    final cases = <(TaskDate, String, String, DueUrgency)>[
      (TaskDate(2026, 11, 10), '5d overdue', '5 days ago', DueUrgency.overdue),
      (TaskDate(2026, 11, 13), '2d overdue', '2 days ago', DueUrgency.overdue),
      (TaskDate(2026, 11, 14), 'yesterday', 'yesterday', DueUrgency.overdue),
      (TaskDate(2026, 11, 15), 'today', 'today', DueUrgency.today),
      (TaskDate(2026, 11, 16), 'tomorrow', 'tomorrow', DueUrgency.later),
      (TaskDate(2026, 11, 18), 'in 3d', 'in 3 days', DueUrgency.later),
      (TaskDate(2026, 11, 21), 'in 6d', 'in 6 days', DueUrgency.later),
      (TaskDate(2026, 11, 22), 'Nov 22', 'Nov 22', DueUrgency.later),
      (TaskDate(2026, 12, 3), 'Dec 3', 'Dec 3', DueUrgency.later),
      (TaskDate(2027, 1, 2), 'Jan 2, 2027', 'Jan 2, 2027', DueUrgency.later),
      (
        TaskDate(2025, 11, 1),
        '379d overdue',
        '379 days ago',
        DueUrgency.overdue,
      ),
    ];
    for (final (date, text, spoken, urgency) in cases) {
      test('$date relative to $today', () {
        expect(
          describeDue(date, today),
          DueDescription(
            date: date,
            text: text,
            spoken: spoken,
            urgency: urgency,
          ),
        );
      });
    }

    test('counts calendar days across month, year and leap boundaries', () {
      expect(
        describeDue(TaskDate(2028, 3, 1), TaskDate(2028, 2, 28)).text,
        'in 2d',
      );
      expect(
        describeDue(TaskDate(2027, 1, 1), TaskDate(2026, 12, 31)).text,
        'tomorrow',
      );
      expect(
        describeDue(TaskDate(2026, 12, 31), TaskDate(2027, 1, 1)).text,
        'yesterday',
      );
    });
  });

  group('projectTaskRowMetadata', () {
    const inbox = TaskListId(7);
    const errands = TaskListId(8);
    final titles = <TaskListId, String>{inbox: 'Inbox', errands: 'Errands'};
    final tasks = <CachedTask>[
      _task(1, 'Pay rent', due: TaskDate(2026, 11, 13), notes: 'Bank'),
      _task(2, 'Plan trip', due: TaskDate(2026, 11, 20)),
      _task(3, 'Book hotel', parent: 2, status: TaskStatus.completed),
      _task(4, 'Book train', parent: 2, due: TaskDate(2026, 11, 16)),
      _task(5, 'Read book', list: errands, notes: '  \n '),
      _task(6, 'Pack', due: TaskDate(2026, 11, 18)),
      _task(7, 'Pack bag', parent: 6, due: TaskDate(2026, 11, 25)),
    ];
    final dates = effectiveDueDates(tasks);
    TaskRowMetadata project(int id, TaskView view) => projectTaskRowMetadata(
      task: tasks.singleWhere((task) => task.id == TaskId(id)),
      effectiveDue: dates[TaskId(id)]!,
      tasks: tasks,
      view: view,
      listTitles: titles,
      today: today,
    );

    test('a smart view names the list; a list does not', () {
      final smart = project(1, const SmartTaskView(SmartView.all));
      expect(smart.hasNotes, isTrue);
      expect(smart.ownDue?.text, '2d overdue');
      expect(smart.subtaskDue, isNull);
      expect(smart.progress, isNull);
      expect(smart.listTitle, 'Inbox');
      expect(smart.spokenLabel, 'Has notes, Due 2 days ago, In Inbox');

      final list = project(1, const TaskListView(inbox));
      expect(list.listTitle, isNull);
      expect(list.spokenLabel, 'Has notes, Due 2 days ago');
    });

    test('an earlier open subtask date and direct progress are shown', () {
      final value = project(2, const SmartTaskView(SmartView.focus));
      expect(value.ownDue?.text, 'in 5d');
      expect(value.subtaskDue?.text, 'tomorrow');
      expect(value.progress, const DirectChildProgress(completed: 1, total: 2));
      expect(
        value.spokenLabel,
        'Due in 5 days, Subtask due tomorrow, '
        '1 of 2 subtasks complete, In Inbox',
      );
    });

    test('a later subtask date is not repeated beside the own date', () {
      final value = project(6, const TaskListView(inbox));
      expect(value.ownDue?.text, 'in 3d');
      expect(value.subtaskDue, isNull);
      expect(value.spokenLabel, 'Due in 3 days, 0 of 1 subtask complete');
    });

    test('blank notes and no dates read as undated without notes', () {
      final value = project(5, const SmartTaskView(SmartView.unscheduled));
      expect(value.hasNotes, isFalse);
      expect(value.isUndated, isTrue);
      expect(value.spokenLabel, 'No due date, In Errands');
    });
  });
}

CachedTask _task(
  int id,
  String title, {
  TaskListId list = const TaskListId(7),
  int? parent,
  TaskDate? due,
  String? notes,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: list,
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: null,
  title: title,
  notes: notes,
  status: status,
  due: due,
);
