// The export serializer (#297) — the ONE module that turns a list or a view
// into the document the user takes out of the app.
//
// These tests assert the EXACT bytes it produces, because that document is the
// deliverable: a Markdown checklist someone pastes into a PR description, a CSV
// someone opens in a spreadsheet. The specific failures they prevent are the
// ones a "looks about right" assertion cannot catch:
//
//   • a note containing a comma or a quote silently corrupting every column
//     after it (RFC 4180 quoting);
//   • a note containing a newline splitting one task into two CSV rows;
//   • a completed task leaking into an export the user asked not to include it
//     in (and its completed subtasks with it);
//   • a subtask rendered as a top-level row (invariant #1 — subtasks are
//     strictly one level and never a row of their own);
//   • a due date exported as the raw ISO instant, or as a relative label
//     ("in 3d") that is a lie the day after the file is written.
//
// Dates come from `package:clock` (pinned with withClock), never the wall clock.

import 'package:axiotask/src/app/task_export.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed "today" so the absolute date labels are deterministic.
final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

StoredTask _task(
  String id,
  String title, {
  String listId = 'L1',
  String? due,
  String? notes,
  String? parent,
  bool completed = false,
  String? completedAt,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: '0000000000000$id',
    title: title,
    notes: notes,
    status: completed ? TaskStatus.completed : TaskStatus.needsAction,
    due: due,
    completed: completed ? (completedAt ?? '2026-06-14T10:00:00.000Z') : null,
    updated: '2026-06-01T00:00:00.000Z',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: '2026-06-01T00:00:00.000Z',
);

/// The fixture every format test reads: a dated parent carrying notes with a
/// comma, a quote AND a newline, one completed and one open subtask, a
/// completed top-level task, and an undated one whose title holds a comma.
final _milk = _task(
  '1',
  'Buy milk',
  due: '2026-09-12T00:00:00.000Z',
  notes: 'Semi-skimmed, the "blue cap" one\n2 bottles',
);
final _fridge = _task('2', 'Check the fridge', parent: '1', completed: true);
final _bags = _task('3', 'Take the bags', parent: '1');
final _bob = _task(
  '4',
  'Call Bob',
  completed: true,
  completedAt: '2026-06-14T10:00:00.000Z',
);
final _trip = _task('5', 'Plan trip, part 2', listId: 'L2');

final _all = [_milk, _fridge, _bags, _bob, _trip];
final _tops = [_milk, _bob, _trip];
const _listTitles = {'L1': 'Groceries', 'L2': 'Work, urgent'};

ExportDocument _build({
  ExportOptions options = const ExportOptions(),
  List<StoredTask>? topLevel,
  List<StoredTask>? allTasks,
  String title = 'Groceries',
}) => withClock(
  _clock,
  () => buildExport(
    title: title,
    topLevel: topLevel ?? _tops,
    allTasks: allTasks ?? _all,
    listTitles: _listTitles,
    options: options,
  ),
);

void main() {
  group('Markdown', () {
    test('renders a checklist with dates, notes and nested subtasks', () {
      final doc = _build(options: const ExportOptions(includeCompleted: true));

      expect(doc.text, '''
# Groceries

- [ ] Buy milk — Sep 12

  Semi-skimmed, the "blue cap" one
  2 bottles

  - [x] Check the fridge
  - [ ] Take the bags
- [x] Call Bob
- [ ] Plan trip, part 2
''');
    });

    test('leaves completed tasks AND completed subtasks out by default', () {
      final doc = _build();

      expect(doc.text, '''
# Groceries

- [ ] Buy milk — Sep 12

  Semi-skimmed, the "blue cap" one
  2 bottles

  - [ ] Take the bags
- [ ] Plan trip, part 2
''');
    });

    test('notes off drops the note block and keeps the list tight', () {
      final doc = _build(options: const ExportOptions(includeNotes: false));

      expect(doc.text, '''
# Groceries

- [ ] Buy milk — Sep 12
  - [ ] Take the bags
- [ ] Plan trip, part 2
''');
    });

    test('subtasks off drops the nested lines, never the parent', () {
      final doc = _build(options: const ExportOptions(includeSubtasks: false));

      expect(doc.text, '''
# Groceries

- [ ] Buy milk — Sep 12

  Semi-skimmed, the "blue cap" one
  2 bottles

- [ ] Plan trip, part 2
''');
    });

    test("a subtask's own notes are indented under the subtask", () {
      final parent = _task('9', 'Parent');
      final child = _task('10', 'Child', parent: '9', notes: 'why it matters');
      final doc = _build(topLevel: [parent], allTasks: [parent, child]);

      expect(doc.text, '''
# Groceries

- [ ] Parent
  - [ ] Child

    why it matters

''');
    });

    test('a date in another year carries the year; today reads as a date', () {
      final doc = _build(
        topLevel: [
          _task('9', 'Next year', due: '2027-01-04T00:00:00.000Z'),
          _task('8', 'Today', due: '2026-06-15T00:00:00.000Z'),
        ],
        allTasks: const [],
      );

      expect(doc.text, '''
# Groceries

- [ ] Next year — Jan 4, 2027
- [ ] Today — Jun 15
''');
    });

    test('an empty view says so instead of producing a bare heading', () {
      final doc = _build(topLevel: const [], allTasks: const []);

      expect(doc.text, '''
# Groceries

_No tasks._
''');
      expect(doc.taskCount, 0);
    });

    test('a newline inside a title never breaks the checklist line', () {
      final doc = _build(
        topLevel: [_task('9', 'Two\nlines')],
        allTasks: const [],
      );

      expect(doc.text, '''
# Groceries

- [ ] Two lines
''');
    });

    test('counts the tasks it actually wrote, subtasks included', () {
      expect(_build().taskCount, 3); // milk + bags + trip
      expect(
        _build(options: const ExportOptions(includeCompleted: true)).taskCount,
        5,
      );
      expect(
        _build(options: const ExportOptions(includeSubtasks: false)).taskCount,
        2,
      );
    });
  });

  group('CSV', () {
    test('quotes commas, quotes and newlines per RFC 4180', () {
      final doc = _build(
        options: const ExportOptions(
          format: ExportFormat.csv,
          includeCompleted: true,
        ),
      );

      expect(doc.text, '''
title,list,due,status,completed_at,notes,parent_title
Buy milk,Groceries,2026-09-12,needsAction,,"Semi-skimmed, the ""blue cap"" one
2 bottles",
Check the fridge,Groceries,,completed,2026-06-14T10:00:00.000Z,,Buy milk
Take the bags,Groceries,,needsAction,,,Buy milk
Call Bob,Groceries,,completed,2026-06-14T10:00:00.000Z,,
"Plan trip, part 2","Work, urgent",,needsAction,,,
''');
    });

    test('the header stays even when the export holds nothing', () {
      final doc = _build(
        options: const ExportOptions(format: ExportFormat.csv),
        topLevel: const [],
        allTasks: const [],
      );

      expect(
        doc.text,
        'title,list,due,status,completed_at,notes,parent_title\n',
      );
    });

    test('options blank the notes column and drop the subtask rows', () {
      final doc = _build(
        options: const ExportOptions(
          format: ExportFormat.csv,
          includeNotes: false,
          includeSubtasks: false,
        ),
      );

      expect(doc.text, '''
title,list,due,status,completed_at,notes,parent_title
Buy milk,Groceries,2026-09-12,needsAction,,,
"Plan trip, part 2","Work, urgent",,needsAction,,,
''');
    });
  });

  group('the document itself', () {
    test('is named for the view and the day, with the format extension', () {
      expect(
        _build(title: 'Groceries').fileName,
        'axiotask-groceries-20260615.md',
      );
      expect(
        _build(
          title: 'Work, urgent!',
          options: const ExportOptions(format: ExportFormat.csv),
        ).fileName,
        'axiotask-work-urgent-20260615.csv',
      );
      // A title with nothing sluggable still yields a usable filename.
      expect(_build(title: '///').fileName, 'axiotask-tasks-20260615.md');
    });

    test('carries the MIME type the share sheet needs', () {
      expect(_build().mimeType, 'text/markdown');
      expect(
        _build(options: const ExportOptions(format: ExportFormat.csv)).mimeType,
        'text/csv',
      );
    });
  });
}
