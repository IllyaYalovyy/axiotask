import 'dart:convert';

import 'package:axiotask/src/domain/export/view_export.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/export_parsers.dart';

void main() {
  final today = TaskDate(2026, 11, 15);

  ViewExportDocument export(
    List<CachedTask> tasks, {
    TaskView view = const TaskListView(TaskListId(10)),
    String title = 'Groceries',
    ViewPreferences preferences = const ViewPreferences.defaults(),
    ViewExportFormat format = ViewExportFormat.csv,
    Set<TaskListId>? excluded,
  }) {
    final rows = projectTaskView(
      tasks: tasks,
      view: view,
      preferences: preferences,
      excludedTaskLists: excluded ?? <TaskListId>{},
      today: today,
    ).rows.map((row) => row.task).toList();
    return buildViewExport(
      title: title,
      rows: rows,
      tasks: tasks,
      taskLists: _lists,
      showCompleted: preferences.showCompleted,
      format: format,
      today: today,
    );
  }

  group('CSV', () {
    test('has the fixed v1.5.3 header, LF endings and no byte-order mark', () {
      final document = export(<CachedTask>[_task(1, 'Milk')]);

      expect(document.text, startsWith(viewExportCsvHeader.join(',')));
      expect(
        viewExportCsvHeader.join(','),
        'title,list,due,status,completed_at,notes,parent_title',
      );
      expect(document.text.codeUnitAt(0), isNot(0xFEFF));
      expect(
        utf8.encode(document.text).take(3),
        isNot(<int>[0xEF, 0xBB, 0xBF]),
      );
      expect(document.text, isNot(contains('\r')));
      expect(document.text, endsWith('\n'));
      expect(document.mimeType, 'text/csv');
      expect(document.fileName, 'axiotask-groceries-20261115.csv');
    });

    test('round-trips commas, quotes, multiline notes and Unicode', () {
      const title = 'Eggs, "free range", 12 — ½ dozen';
      const notes =
          'Line one, with comma\n"Quoted" line\r\nПривет мир 你好 🥚 é\n\nlast';
      final tasks = <CachedTask>[
        _task(1, title, notes: notes, due: TaskDate(2026, 12, 1)),
        _task(2, 'Ünïcødé child 🧪', parent: 1, notes: 'a,b'),
        _task(3, 'Plain'),
      ];

      final records = parseCsv(export(tasks).text);

      expect(records.first, viewExportCsvHeader);
      expect(records.skip(1).toList(), <List<String>>[
        <String>[
          title,
          'Shopping, "home"',
          '2026-12-01',
          'needsAction',
          '',
          notes,
          '',
        ],
        <String>[
          'Ünïcødé child 🧪',
          'Shopping, "home"',
          '',
          'needsAction',
          '',
          'a,b',
          title,
        ],
        <String>['Plain', 'Shopping, "home"', '', 'needsAction', '', '', ''],
      ]);
      // Every record has exactly the header's width.
      for (final record in records) {
        expect(record, hasLength(viewExportCsvHeader.length));
      }
    });

    test('writes each task\'s own date and status, never an inherited one', () {
      final tasks = <CachedTask>[
        _task(1, 'Parent'),
        _task(2, 'Dated child', parent: 1, due: TaskDate(2026, 11, 20)),
        _task(3, 'Done', status: TaskStatus.completed),
      ];

      final records = parseCsv(
        export(
          tasks,
          preferences: const ViewPreferences(
            sort: ViewSort.manual,
            showCompleted: true,
          ),
        ).text,
      ).skip(1);

      expect(
        records.map((r) => (r[0], r[2], r[3], r[6])),
        <(String, String, String, String)>[
          ('Parent', '', 'needsAction', ''),
          ('Dated child', '2026-11-20', 'needsAction', 'Parent'),
          ('Done', '', 'completed', ''),
        ],
      );
    });

    test('completed_at is the stored instant of a completed task only', () {
      final tasks = <CachedTask>[
        _task(
          1,
          'Completed with instant',
          status: TaskStatus.completed,
          // A non-UTC instant is still written in UTC.
          completedAt: DateTime.utc(2026, 6, 14, 10).toLocal(),
        ),
        _task(
          2,
          'Reopened, stale instant',
          completedAt: DateTime.utc(2026, 6, 1, 8, 30),
        ),
        _task(3, 'Completed locally', status: TaskStatus.completed),
      ];

      final records = parseCsv(
        export(
          tasks,
          preferences: const ViewPreferences(
            sort: ViewSort.manual,
            showCompleted: true,
          ),
        ).text,
      ).skip(1);

      expect(records.map((r) => (r[0], r[3], r[4])), <(String, String, String)>[
        ('Reopened, stale instant', 'needsAction', ''),
        ('Completed with instant', 'completed', '2026-06-14T10:00:00.000Z'),
        ('Completed locally', 'completed', ''),
      ]);
    });

    test('an empty view is the header alone', () {
      final document = export(const <CachedTask>[]);

      expect(document.text, '${viewExportCsvHeader.join(',')}\n');
      expect(parseCsv(document.text), <List<String>>[viewExportCsvHeader]);
      expect(document.taskCount, 0);
    });
  });

  group('Markdown', () {
    test('is a GFM checklist with one nested subtask level and notes', () {
      final tasks = <CachedTask>[
        _task(
          1,
          'Parent',
          notes: 'First line\nSecond line',
          due: TaskDate(2026, 11, 20),
        ),
        _task(2, 'Child', parent: 1, notes: 'Child note'),
        _task(3, 'Next year', due: TaskDate(2027, 1, 2)),
      ];

      final document = export(tasks, format: ViewExportFormat.markdown);

      expect(document.text, '''
# Groceries

- [ ] Parent — Nov 20

  First line
  Second line

  - [ ] Child

    Child note

- [ ] Next year — Jan 2, 2027
''');
      expect(document.fileName, 'axiotask-groceries-20261115.md');
      expect(document.mimeType, 'text/markdown');
      expect(document.taskCount, 3);
    });

    test('escapes markup in titles and notes so the text reads back exactly', () {
      const title =
          r'*Bold* _it_ `code` [link](http://x) <b>&amp; ~~s~~ |c| !img \ end';
      const noteLines = <String>[
        '# not a heading',
        '- [ ] not a task',
        '+ not a bullet',
        '> not a quote',
        '1. not ordered',
        '2) not ordered either',
        '---',
        '=== ',
        '```',
        '<script>alert(1)</script>',
        'Unicode: Привет 你好 🥚',
      ];
      final tasks = <CachedTask>[
        _task(1, title, notes: noteLines.join('\n')),
        _task(2, '- [x] fake checked child', parent: 1),
        _task(3, 'Multi\nline\ttitle'),
      ];

      final document = export(
        tasks,
        title: '# My *list*',
        format: ViewExportFormat.markdown,
      );
      final parsed = parseMarkdownExport(document.text);

      expect(parsed.heading, '# My *list*');
      expect(
        parsed.items.map((item) => (item.depth, item.checked, item.title)),
        <(int, bool, String)>[
          (0, false, title),
          (1, false, '- [x] fake checked child'),
          (0, false, 'Multi line title'),
        ],
      );
      expect(
        parsed.items.first.notes,
        noteLines.map((line) => line.trim()).toList(),
      );
      // No markup character survives unescaped in any written line of text.
      for (final line in document.text.split('\n').skip(1)) {
        final text = line.replaceFirst(RegExp(r'^ *- \[[ x]\] '), '');
        expect(unescapedMarkup.hasMatch(text), isFalse, reason: line);
      }
      // Escaped block markers never start a line after indentation.
      for (final line in document.text.split('\n').skip(1)) {
        expect(
          line.trimLeft(),
          isNot(matches(RegExp(r'^(#|>|\+ |\d+[.)]|---|===|```)'))),
          reason: line,
        );
      }
    });

    test('an empty view says so instead of a bare heading', () {
      final document = export(
        const <CachedTask>[],
        format: ViewExportFormat.markdown,
      );

      expect(document.text, '# Groceries\n\n_No tasks._\n');
      expect(parseMarkdownExport(document.text).declaredEmpty, isTrue);
    });

    test('completed tasks are checked boxes', () {
      final document = export(
        <CachedTask>[_task(1, 'Done', status: TaskStatus.completed)],
        format: ViewExportFormat.markdown,
        preferences: const ViewPreferences(
          sort: ViewSort.manual,
          showCompleted: true,
        ),
      );

      expect(parseMarkdownExport(document.text).items.single.checked, isTrue);
    });
  });

  group('scope', () {
    final account = <CachedTask>[
      _task(1, 'Bread', due: TaskDate(2026, 11, 16)),
      _task(2, 'Apples', notes: 'red'),
      _task(3, 'Open child', parent: 2),
      _task(4, 'Done child', parent: 2, status: TaskStatus.completed),
      _task(5, 'Done top', status: TaskStatus.completed),
      _task(
        6,
        'Work report',
        list: 20,
        due: TaskDate(2026, 11, 14),
        notes: 'secret work note',
      ),
      _task(7, 'Hidden list task', list: 30, due: TaskDate(2026, 11, 15)),
      _task(8, 'Unscheduled other', list: 20),
    ];

    List<(String, String)> titles(ViewExportDocument document) =>
        parseCsv(document.text)
            .skip(1)
            .map((record) => (record[0], record[6]))
            .toList();

    test('a list exports its displayed rows in display order', () {
      final manual = export(account);
      expect(titles(manual), <(String, String)>[
        ('Bread', ''),
        ('Apples', ''),
        ('Open child', 'Apples'),
      ]);

      final byTitle = export(
        account,
        preferences: const ViewPreferences(
          sort: ViewSort.title,
          showCompleted: false,
        ),
      );
      expect(titles(byTitle).map((entry) => entry.$1), <String>[
        'Apples',
        'Open child',
        'Bread',
      ]);
    });

    test('the completed filter includes completed rows and subtasks only when shown', () {
      final shown = export(
        account,
        preferences: const ViewPreferences(
          sort: ViewSort.manual,
          showCompleted: true,
        ),
      );
      expect(titles(shown), <(String, String)>[
        ('Bread', ''),
        ('Apples', ''),
        ('Open child', 'Apples'),
        ('Done child', 'Apples'),
        ('Done top', ''),
      ]);
      expect(shown.taskCount, 5);
    });

    test(
      'a smart view spans lists, honours exclusions and names each list',
      () {
        final focus = export(
          account,
          view: const SmartTaskView(SmartView.focus),
          title: 'Focus',
          excluded: <TaskListId>{const TaskListId(30)},
        );
        final records = parseCsv(focus.text).skip(1).toList();

        expect(records.map((r) => (r[0], r[1])), <(String, String)>[
          ('Work report', 'Work'),
          ('Bread', 'Shopping, "home"'),
        ]);
        expect(focus.fileName, 'axiotask-focus-20261115.csv');
      },
    );

    test('nothing outside the displayed scope leaks into either format', () {
      for (final format in ViewExportFormat.values) {
        final document = export(account, format: format);
        for (final hidden in <String>[
          'Work report',
          'secret work note',
          'Hidden list task',
          'Unscheduled other',
          'Done child',
          'Done top',
          'Work',
          'Hidden',
          'synthetic-task',
          'synthetic-list',
          'TaskId',
        ]) {
          expect(
            document.text,
            isNot(contains(hidden)),
            reason: '$format: $hidden',
          );
        }
      }
    });

    test('subtasks of rows that are not displayed are not exported', () {
      // A smart view showing only the child's parent's sibling.
      final missed = export(
        account,
        view: const SmartTaskView(SmartView.missed),
        title: 'Missed',
      );
      expect(titles(missed), <(String, String)>[('Work report', '')]);
    });
  });

  test(
    'file names are filesystem-safe and fall back for unsluggable titles',
    () {
      expect(
        viewExportFileName(
          'Groceries / Week #3!',
          ViewExportFormat.markdown,
          today,
        ),
        'axiotask-groceries-week-3-20261115.md',
      );
      expect(
        viewExportFileName('🛒🥚', ViewExportFormat.csv, TaskDate(2026, 1, 5)),
        'axiotask-tasks-20260105.csv',
      );
      expect(
        viewExportFileName('a' * 80, ViewExportFormat.csv, today),
        'axiotask-${'a' * 40}-20261115.csv',
      );
    },
  );
}

const _lists = <CachedTaskList>[
  CachedTaskList(
    id: TaskListId(10),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-10'),
    title: 'Shopping, "home"',
  ),
  CachedTaskList(
    id: TaskListId(20),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-20'),
    title: 'Work',
  ),
  CachedTaskList(
    id: TaskListId(30),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-30'),
    title: 'Hidden',
  ),
];

CachedTask _task(
  int id,
  String title, {
  int list = 10,
  int? parent,
  String? notes,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
  DateTime? completedAt,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-task-$id'),
  title: title,
  notes: notes,
  status: status,
  due: due,
  completedAt: completedAt,
);
