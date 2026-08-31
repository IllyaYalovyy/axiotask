// TaskDetail suite — WIDGET tests that drive the real [TaskDetail] and assert
// what RENDERS and what the fake backend HOLDS after a gesture. The backend is
// the shared in-memory [FakeBackend] (see detail_harness.dart), so the tests
// stay off drift's real event queue.
//
// Covered here: the two-level guard (invariant #1), subtask add-with-kept-focus
// + toggle + open, title/notes diff-only auto-save on blur, live-tracking
// without clobbering, delete, the task's own due surface, per-subtask due,
// hide-completed + un-complete-all, the List dropdown (#93), and links. Reorder
// lives in subtask_reorder_test.dart; prev/next, detach, empty-discard and the
// list-move repoint live in detail_workflow_test.dart.

import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/date_format.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  testWidgets('renders the task title and notes in editable fields', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      taskId: 'P',
      initial: [row('P', 'parent task', notes: 'some notes')],
    );
    expect(find.widgetWithText(TextField, 'parent task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'some notes'), findsOneWidget);
  });

  group('two-level guard (TwoLevelTree)', () {
    testWidgets('a top-level task offers the add-subtask input', (
      tester,
    ) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'parent')]);
      expect(find.widgetWithText(TextField, 'Add a subtask'), findsOneWidget);
      expect(find.byTooltip('Add subtask'), findsOneWidget);
      expect(find.text('Subtasks'), findsOneWidget);
    });

    testWidgets('a subtask panel offers NO add-subtask input (invariant #1)', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'parent'),
          row('S', 'child', parent: 'P'),
        ],
      );
      expect(find.byTooltip('Add subtask'), findsNothing);
      expect(find.text('Subtasks'), findsNothing);
      expect(find.text('Subtask'), findsOneWidget);
    });
  });

  group('subtasks', () {
    testWidgets('renders existing subtasks as a checklist under the parent', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid one', parent: 'P', position: '1'),
          row('C2', 'kid two', parent: 'P', position: '2', done: true),
        ],
      );
      expect(find.text('kid one'), findsOneWidget);
      expect(find.text('kid two'), findsOneWidget);
      final checks = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList();
      expect(checks.where((c) => c.value == true), hasLength(1));
    });

    testWidgets(
      'typing a title and pressing Enter adds a subtask, keeps focus',
      (tester) async {
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [row('P', 'parent')],
          newId: () => 'NEW',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Add a subtask').first,
          'buy milk',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settleDetail(tester);

        expect(find.text('buy milk'), findsOneWidget);
        final created = fake.tasks.firstWhere((t) => t.task.id == 'NEW');
        expect(created.task.parent, 'P', reason: 'born under the parent');
        final field = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Add a subtask'),
        );
        expect(field.controller?.text, isEmpty);
        expect(field.focusNode?.hasFocus, isTrue);
      },
    );

    testWidgets('an empty add creates nothing (non-happy path)', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'parent')],
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a subtask'),
        '   ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleDetail(tester);
      expect(fake.tasks.where((t) => t.task.parent == 'P'), isEmpty);
    });

    testWidgets('tapping a subtask checkbox toggles its completion', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid', parent: 'P'),
        ],
      );
      await tester.tap(find.byType(Checkbox));
      await settleDetail(tester);
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'C1').task.status,
        TaskStatus.completed,
      );
    });

    testWidgets('tapping a subtask title opens its own panel', (tester) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid', parent: 'P'),
        ],
        opened: opened,
      );
      await tester.tap(find.text('kid'));
      await settleDetail(tester);
      expect(opened, ['C1']);
    });
  });

  group('auto-save (diff-only, on blur)', () {
    testWidgets('an edited title saves once the field loses focus', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'old title')],
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'old title'),
        'new title',
      );
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settleDetail(tester);
      expect(fake.renamed, ['P=new title']);
    });

    testWidgets('an untouched field never queues a write (diff-only)', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'title', notes: 'notes')],
      );
      await tester.tap(find.widgetWithText(TextField, 'title'));
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settleDetail(tester);
      expect(fake.renamed, isEmpty);
      expect(fake.notesSet, isEmpty);
    });

    testWidgets('edited notes save on blur', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'title', notes: 'old')],
      );
      await tester.enterText(find.widgetWithText(TextField, 'old'), 'updated');
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settleDetail(tester);
      expect(fake.notesSet, ['P=updated']);
    });
  });

  group('live-tracking (without clobbering typing)', () {
    testWidgets('an external retitle refreshes an unfocused title field', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'v1')],
      );
      expect(find.widgetWithText(TextField, 'v1'), findsOneWidget);

      fake.pushExternal('P', 'v2');
      await settleDetail(tester);
      expect(find.widgetWithText(TextField, 'v2'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'v1'), findsNothing);
    });

    testWidgets(
      'an external retitle does NOT clobber the field being typed in',
      (tester) async {
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [row('P', 'v1')],
        );
        await tester.tap(find.widgetWithText(TextField, 'v1'));
        await tester.enterText(
          find.widgetWithText(TextField, 'v1'),
          'my draft',
        );

        fake.pushExternal('P', 'remote change');
        await settleDetail(tester);
        expect(find.widgetWithText(TextField, 'my draft'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'remote change'), findsNothing);
      },
    );
  });

  group('delete', () {
    testWidgets('the delete action removes the task, closes, offers Undo', (
      tester,
    ) async {
      final closed = <String>[];
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'doomed')],
        closed: closed,
      );
      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-delete')));
      await settleDetail(tester);
      expect(fake.deleted, hasLength(1));
      expect(closed, ['close'], reason: 'panel closes after delete');
      expect(find.text('Undo'), findsOneWidget);
    });
  });

  testWidgets('a deleted task the panel is open on shows the missing state', (
    tester,
  ) async {
    await pumpDetail(tester, taskId: 'gone', initial: [row('P', 'parent')]);
    expect(find.text('This task is no longer available.'), findsOneWidget);
  });

  group("the task's own due date", () {
    testWidgets('shows the current due date, formatted', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'dated', due: '2026-06-15T00:00:00.000Z')],
      );
      final due = tester.widget<OutlinedButton>(
        find.byKey(const Key('due-field')),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('due-field')),
          matching: find.text(formatDue('2026-06-15T00:00:00.000Z')),
        ),
        findsOneWidget,
      );
      expect(due.onPressed, isNotNull);
    });

    testWidgets('the Due field\'s "Today" sets the date via setDue', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'undated')],
      );
      await tester.tap(find.byKey(const Key('due-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quickDateKey('today')));
      await settleDetail(tester);
      expect(fake.setDueCalls, ['P=DateMove.today']);
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'P').task.due,
        isNotNull,
      );
    });

    testWidgets('Clear removes the date', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'dated', due: '2026-06-15T00:00:00.000Z')],
      );
      await tester.tap(find.byKey(const Key('due-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quickDateKey('clear')));
      await settleDetail(tester);
      expect(fake.setDueCalls, ['P=DateMove.clear']);
      expect(fake.tasks.firstWhere((t) => t.task.id == 'P').task.due, isNull);
    });

    testWidgets('"Pick a date…" opens the calendar and sets it via setDueRaw', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'dated', due: '2026-06-15T00:00:00.000Z')],
      );
      await tester.tap(find.byKey(const Key('due-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quickDateKey('pick')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      expect(fake.setDueCalls, ['P=raw:2026-06-20']);
    });
  });

  group('per-subtask due (inline)', () {
    testWidgets('shows a subtask due button labelled with the ISO date', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S', 'kid', parent: 'P', due: '2026-06-10T00:00:00.000Z'),
        ],
      );
      expect(find.byTooltip('Subtask due date: 2026-06-10'), findsOneWidget);
    });

    testWidgets('picking a subtask date sets it via setDueRaw on the subtask', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S', 'kid', parent: 'P', due: '2026-06-10T00:00:00.000Z'),
        ],
      );
      await tester.tap(find.byKey(const Key('sub-due-S')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quickDateKey('pick')));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      await tester.tap(find.text('17'));
      await tester.pumpAndSettle();
      expect(fake.setDueCalls, ['S=raw:2026-06-17']);
    });
  });

  // #220 — the section leads with a textual "x of y complete" so the user reads
  // the progress instead of estimating it from the row's bar. It counts EVERY
  // subtask, including ones the hide-completed toggle removes from view.
  group('subtask progress summary (#220)', () {
    testWidgets('states how many of the subtasks are complete', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid one', parent: 'P', position: '1', done: true),
          row('C2', 'kid two', parent: 'P', position: '2'),
          row('C3', 'kid three', parent: 'P', position: '3'),
        ],
      );
      expect(find.text('1 of 3 complete'), findsOneWidget);
    });

    testWidgets('re-counts as soon as a subtask is toggled', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid one', parent: 'P', position: '1', done: true),
          row('C2', 'kid two', parent: 'P', position: '2'),
          row('C3', 'kid three', parent: 'P', position: '3'),
        ],
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('C2')),
          matching: find.byType(Checkbox),
        ),
      );
      await settleDetail(tester);

      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'C2').task.status,
        TaskStatus.completed,
      );
      expect(find.text('2 of 3 complete'), findsOneWidget);
      expect(find.text('1 of 3 complete'), findsNothing);
    });

    testWidgets('keeps counting the completed ones while they are hidden', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid one', parent: 'P', position: '1', done: true),
          row('C2', 'kid two', parent: 'P', position: '2'),
          row('C3', 'kid three', parent: 'P', position: '3'),
        ],
      );
      await tester.tap(find.text('Hide completed'));
      await settleDetail(tester);

      expect(find.text('kid one'), findsNothing, reason: 'hidden from view');
      expect(
        find.text('1 of 3 complete'),
        findsOneWidget,
        reason: 'hidden subtasks still count toward the total',
      );
    });

    testWidgets('a task with no subtasks states no count', (tester) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'parent')]);
      expect(find.textContaining(' complete'), findsNothing);
    });
  });

  group('hide-completed / un-complete-all', () {
    testWidgets('hides completed subtasks when the toggle is on', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S1', 'open kid', parent: 'P', position: '1'),
          row('S2', 'done kid', parent: 'P', position: '2', done: true),
        ],
      );
      expect(find.text('done kid'), findsOneWidget);
      await tester.tap(find.text('Hide completed'));
      await settleDetail(tester);
      expect(find.text('done kid'), findsNothing);
      expect(find.text('open kid'), findsOneWidget);
    });

    testWidgets('no Hide-completed toggle when nothing is completed', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S1', 'open kid', parent: 'P'),
        ],
      );
      expect(find.text('Hide completed'), findsNothing);
    });

    testWidgets(
      'un-complete all reopens every completed subtask, leaving open ones',
      (tester) async {
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [
            row('P', 'parent'),
            row('S1', 'done a', parent: 'P', position: '1', done: true),
            row('S2', 'done b', parent: 'P', position: '2', done: true),
            row('S3', 'still open', parent: 'P', position: '3'),
          ],
        );
        await tester.tap(find.text('Un-complete all subtasks'));
        await settleDetail(tester);
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'S1').task.status,
          TaskStatus.needsAction,
        );
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'S2').task.status,
          TaskStatus.needsAction,
        );
        // The already-open subtask was never toggled.
        expect(
          fake.tasks.firstWhere((t) => t.task.id == 'S3').task.status,
          TaskStatus.needsAction,
        );
      },
    );

    testWidgets('no Un-complete-all action when nothing is completed', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S1', 'open kid', parent: 'P'),
        ],
      );
      expect(find.text('Un-complete all subtasks'), findsNothing);
    });
  });

  group('List dropdown (#93)', () {
    testWidgets('a top-level task shows the List dropdown at its list', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'parent', listId: 'L1')],
        lists: [list('L1', 'Work'), list('L2', 'Personal')],
      );
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const Key('list-dropdown')),
      );
      expect(dropdown.value, 'L1');
    });

    testWidgets(
      'a SUBTASK shows no List dropdown (it lives in its parent list)',
      (tester) async {
        await pumpDetail(
          tester,
          taskId: 'S',
          initial: [
            row('P', 'parent'),
            row('S', 'kid', parent: 'P'),
          ],
          lists: [list('L1', 'Work'), list('L2', 'Personal')],
        );
        expect(find.byKey(const Key('list-dropdown')), findsNothing);
      },
    );
  });

  group('links', () {
    testWidgets('a URL in the notes renders a tappable link that opens it', (
      tester,
    ) async {
      final opened = <String>[];
      final fake = FakeBackend([
        row('P', 'parent', notes: 'see https://example.com/x for more'),
      ]);
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            urlOpenerProvider.overrideWithValue((url) async => opened.add(url)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TaskDetail(taskId: 'P', onClose: () {}, onOpenTask: (_) {}),
            ),
          ),
        ),
      );
      await settleDetail(tester);
      expect(find.text('Links'), findsOneWidget);
      await tester.tap(find.byKey(const Key('link-https://example.com/x')));
      await settleDetail(tester);
      expect(opened, ['https://example.com/x']);
    });
  });

  // G9 (#208): in a narrow detail pane the subtask title is the flexible,
  // ellipsizing element — it stays on ONE line so the fixed reorder arrows and
  // due button are never pushed off the edge (a wrapping title would balloon the
  // row height and, at the extreme, overflow).
  group('narrow detail: nothing overflows (G9 #208)', () {
    testWidgets('a long subtask title stays on a single line', (tester) async {
      const longTitle =
          'A very long subtask title that would wrap onto several lines in a '
          'narrow detail pane unless it is capped to a single ellipsized line';
      // A genuinely narrow detail column, tall enough to lay the row out.
      tester.view.physicalSize = const Size(300, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fake = FakeBackend([
        row('P', 'parent'),
        row('C', longTitle, parent: 'P'),
      ]);
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TaskDetail(taskId: 'P', onClose: () {}, onOpenTask: (_) {}),
            ),
          ),
        ),
      );
      await settleDetail(tester);

      // The full title is still present (ellipsis clips paint, not the string).
      final title = find.text(longTitle);
      expect(title, findsOneWidget);
      // One line: a wrapping title in this ~90dp column would be many lines tall;
      // capped to one line it stays short.
      expect(
        tester.getSize(title).height,
        lessThan(30),
        reason: 'the subtask title must ellipsize to one line, not wrap',
      );
    });

    // The #220 summary is new text in the subtasks header, which already packs
    // the "Subtasks" label and the Hide-completed toggle onto one line. At a
    // phone-narrow pane with the system font enlarged, that section must still
    // lay out with ZERO RenderFlex overflow (the G9 #208 pattern: capture the
    // framework's overflow errors and assert none were reported).
    //
    // 360dp is a real small-phone width, and this suite declares no fonts, so
    // the test font measures roughly 1em per character — every string here is
    // WIDER than it renders in production. Zero overflow at this width is
    // therefore a strictly harder bar than the shipping app faces.
    testWidgets('the progress summary never overflows a 360dp pane at text '
        'scale 1.3', (tester) async {
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        final text = details.exceptionAsString();
        if (text.contains('overflowed')) {
          overflows.add(text);
        } else {
          previous?.call(details);
        }
      };
      addTearDown(() => FlutterError.onError = previous);

      final fake = FakeBackend([
        row('P', 'parent'),
        row('C1', 'kid one', parent: 'P', position: '1', done: true),
        row('C2', 'kid two', parent: 'P', position: '2'),
        row('C3', 'kid three', parent: 'P', position: '3'),
      ]);
      addTearDown(fake.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
          ],
          child: MaterialApp(
            home: MediaQuery.withClampedTextScaling(
              minScaleFactor: 1.3,
              maxScaleFactor: 1.3,
              child: Scaffold(
                body: TaskDetail(
                  taskId: 'P',
                  onClose: () {},
                  onOpenTask: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await settleDetail(tester);

      expect(find.text('1 of 3 complete'), findsOneWidget);
      expect(overflows, isEmpty, reason: overflows.join('\n'));
    });
  });
}
