import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = TaskDate(2026, 8, 15);

  test('smart-view boundaries use local calendar dates and included lists', () {
    final tasks = <CachedTask>[
      _task(1, due: TaskDate(2026, 8, 14)),
      _task(2, due: TaskDate(2026, 8, 15)),
      _task(3, due: TaskDate(2026, 8, 21)),
      _task(4, due: TaskDate(2026, 8, 22)),
      _task(5, due: TaskDate(2026, 8, 29)),
      _task(6, due: TaskDate(2026, 8, 30)),
      _task(7),
      _task(8, list: 20, due: TaskDate(2026, 8, 15)),
    ];
    final excluded = <TaskListId>{const TaskListId(20)};

    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.focus),
          preferences: const ViewPreferences.defaults(),
          excludedTaskLists: excluded,
          today: today,
        ),
      ),
      <int>[1, 2, 3],
    );
    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.upcoming),
          preferences: const ViewPreferences.defaults(),
          excludedTaskLists: excluded,
          today: today,
        ),
      ),
      <int>[3, 4, 5],
    );
    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.missed),
          preferences: const ViewPreferences.defaults(),
          excludedTaskLists: excluded,
          today: today,
        ),
      ),
      <int>[1],
    );
    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.unscheduled),
          preferences: const ViewPreferences.defaults(),
          excludedTaskLists: excluded,
          today: today,
        ),
      ),
      <int>[7],
    );
  });

  test(
    'effective child date controls membership without showing the child',
    () {
      final tasks = <CachedTask>[
        _task(1),
        _task(2, parent: 1, due: TaskDate(2026, 8, 16)),
        _task(3),
        _task(
          4,
          parent: 3,
          due: TaskDate(2026, 8, 16),
          status: TaskStatus.completed,
        ),
      ];

      final focus = projectTaskView(
        tasks: tasks,
        view: const SmartTaskView(SmartView.focus),
        preferences: const ViewPreferences.defaults(),
        excludedTaskLists: const <TaskListId>{},
        today: today,
      );
      final unscheduled = projectTaskView(
        tasks: tasks,
        view: const SmartTaskView(SmartView.unscheduled),
        preferences: const ViewPreferences.defaults(),
        excludedTaskLists: const <TaskListId>{},
        today: today,
      );

      expect(_ids(focus), <int>[1]);
      expect(
        focus.rows.single.effectiveDue.fromChildren,
        TaskDate(2026, 8, 16),
      );
      expect(_ids(unscheduled), <int>[3]);
    },
  );

  test('completion filtering and counts use the exact same projection', () {
    final tasks = <CachedTask>[
      _task(1, due: today),
      _task(2, due: today, status: TaskStatus.completed),
      _task(3, parent: 1, due: today),
    ];

    final hidden = projectTaskView(
      tasks: tasks,
      view: const SmartTaskView(SmartView.focus),
      preferences: const ViewPreferences.defaults(),
      excludedTaskLists: const <TaskListId>{},
      today: today,
    );
    final shown = projectTaskView(
      tasks: tasks,
      view: const SmartTaskView(SmartView.focus),
      preferences: const ViewPreferences(
        sort: ViewSort.manual,
        showCompleted: true,
      ),
      excludedTaskLists: const <TaskListId>{},
      today: today,
    );

    expect(hidden.count, hidden.rows.length);
    expect(shown.count, shown.rows.length);
    expect(_ids(hidden), <int>[1]);
    expect(_ids(shown), <int>[1, 2]);
  });

  test('sort modes are stable and completed rows stay at the bottom', () {
    final tasks = <CachedTask>[
      _task(1, title: 'same', due: TaskDate(2026, 8, 18)),
      _task(2, title: 'Alpha'),
      _task(3, title: 'same', due: TaskDate(2026, 8, 16)),
      _task(4, title: 'Beta', status: TaskStatus.completed),
    ];
    TaskViewProjection projection(ViewSort sort) => projectTaskView(
      tasks: tasks,
      view: const SmartTaskView(SmartView.all),
      preferences: ViewPreferences(sort: sort, showCompleted: true),
      excludedTaskLists: const <TaskListId>{},
      today: today,
    );

    expect(_ids(projection(ViewSort.manual)), <int>[1, 2, 3, 4]);
    expect(_ids(projection(ViewSort.effectiveDue)), <int>[3, 1, 2, 4]);
    expect(_ids(projection(ViewSort.title)), <int>[2, 1, 3, 4]);
    expect(_ids(projection(ViewSort.created)), <int>[3, 2, 1, 4]);
  });

  test('missed is oldest first and focus keeps overdue rows first', () {
    final tasks = <CachedTask>[
      _task(1, title: 'Today A', due: today),
      _task(2, title: 'Yesterday', due: TaskDate(2026, 8, 14)),
      _task(3, title: 'Oldest', due: TaskDate(2026, 8, 10)),
      _task(4, title: 'Today Z', due: today),
    ];

    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.missed),
          preferences: const ViewPreferences.defaults(),
          excludedTaskLists: const <TaskListId>{},
          today: today,
        ),
      ),
      <int>[3, 2],
    );
    expect(
      _ids(
        projectTaskView(
          tasks: tasks,
          view: const SmartTaskView(SmartView.focus),
          preferences: const ViewPreferences(
            sort: ViewSort.title,
            showCompleted: false,
          ),
          excludedTaskLists: const <TaskListId>{},
          today: today,
        ),
      ),
      <int>[3, 2, 1, 4],
    );
  });

  test('focus keeps completed rows below every active date group', () {
    final projection = projectTaskView(
      tasks: <CachedTask>[
        _task(1, due: TaskDate(2026, 8, 14), status: TaskStatus.completed),
        _task(2, due: TaskDate(2026, 8, 16)),
      ],
      view: const SmartTaskView(SmartView.focus),
      preferences: const ViewPreferences(
        sort: ViewSort.manual,
        showCompleted: true,
      ),
      excludedTaskLists: const <TaskListId>{},
      today: today,
    );

    expect(_ids(projection), <int>[2, 1]);
  });

  test(
    'per-list views ignore smart exclusion but retain top-level filtering',
    () {
      final tasks = <CachedTask>[
        _task(1, list: 20),
        _task(2, list: 20, parent: 1),
        _task(3, list: 10),
      ];
      final projection = projectTaskView(
        tasks: tasks,
        view: const TaskListView(TaskListId(20)),
        preferences: const ViewPreferences.defaults(),
        excludedTaskLists: <TaskListId>{const TaskListId(20)},
        today: today,
      );

      expect(_ids(projection), <int>[1]);
    },
  );
}

List<int> _ids(TaskViewProjection projection) =>
    projection.rows.map((row) => row.task.id.value).toList();

CachedTask _task(
  int id, {
  int list = 10,
  int? parent,
  String? title,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-task-$id'),
  title: title ?? 'Task $id',
  notes: null,
  status: status,
  due: due,
);
