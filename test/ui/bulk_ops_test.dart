// BulkOps (MIGRATION-PLAN §5 T7.6). Multi-select + the bulk bar, driven through
// the real [TaskListView] over the mutating [FakeCommands], so every assertion is
// about what RENDERS or what the fake HOLDS after a whole-selection op. The
// reference's `x`-key / Esc / Ctrl+M keyboard triggers die with the keyboard
// layer; selection enters via Ctrl-click and every bulk action is a tappable
// button.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];
  final twoLists = [list('L1', 'My Tasks'), list('L2', 'Errands')];

  /// Ctrl-click the row titled [title] — the desktop selection gesture. The row
  /// body has an onDoubleTap, so a single tap only resolves after the double-tap
  /// timeout; pump past it.
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    // The onTap fires only after the double-tap timeout — keep Ctrl held until
    // then so _onBodyTap reads the modifier and toggles selection.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  /// Open the bar's "⋮" — the home Duplicate and "Make subtasks of…" moved to
  /// when the bar became one row (#265).
  Future<void> openBulkOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('bulk-overflow')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('Ctrl-click selects a task and shows the bulk bar with a count', (
    tester,
  ) async {
    await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
    );
    expect(find.byType(BulkBar), findsNothing);
    await ctrlClick(tester, 'apples');
    expect(find.byType(BulkBar), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    // A second selection grows the count.
    await ctrlClick(tester, 'bread');
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('the clear-selection button dismisses the bulk bar', (
    tester,
  ) async {
    await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
    await ctrlClick(tester, 'apples');
    expect(find.byType(BulkBar), findsOneWidget);
    await tester.tap(find.byKey(const Key('bulk-clear-selection')));
    await tester.pump();
    // The bar folds its height away rather than vanishing (#265) — it is gone
    // once the collapse finishes, not on the frame the selection cleared.
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(BulkBar), findsNothing);
  });

  testWidgets('bulk Complete marks all selected tasks complete', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
      lists: oneList,
      showCompleted: true, // keep completed rows visible to assert the strike
    );
    await ctrlClick(tester, 'apples');
    await ctrlClick(tester, 'bread');
    await tester.tap(find.byKey(const Key('bulk-complete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    bool done(String id) =>
        fake.tasks.firstWhere((t) => t.task.id == id).task.status ==
        TaskStatus.completed;
    expect(done('A'), isTrue);
    expect(done('B'), isTrue);
    expect(done('C'), isFalse, reason: 'unselected task untouched');
    // Selection cleared and a count toast shown.
    expect(find.byType(BulkBar), findsNothing);
    expect(find.text('2 tasks completed'), findsOneWidget);
  });

  testWidgets('bulk Delete deletes all selected tasks', (tester) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
      lists: oneList,
    );
    await ctrlClick(tester, 'apples');
    await ctrlClick(tester, 'cheese');
    await tester.tap(find.byKey(const Key('bulk-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final titles = fake.tasks.map((t) => t.task.title).toList();
    expect(titles, ['bread']);
    expect(find.text('2 tasks deleted'), findsOneWidget);
  });

  testWidgets(
    'bulk Delete shows an Undo that restores every deleted task (F11)',
    (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'cheese');
      await tester.tap(find.byKey(const Key('bulk-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fake.tasks.map((t) => t.task.title), ['bread']);

      // One Undo restores the WHOLE selection (all N, not just the last).
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(fake.tasks.map((t) => t.task.title).toSet(), {
        'apples',
        'bread',
        'cheese',
      });
      expect(find.text('apples'), findsOneWidget);
      expect(find.text('cheese'), findsOneWidget);
    },
  );

  testWidgets(
    'bulk Delete skips a row that vanished concurrently and undoes the rest '
    '(G7 #205)',
    (tester) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread'),
          row('C', 'cheese'),
          row('D', 'dates'),
        ],
        lists: oneList,
      );
      // Select A, B, C (D is left out to prove the op is scoped).
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');
      await ctrlClick(tester, 'cheese');
      // B vanishes concurrently (a sync pull / another gesture deletes it) while
      // still in the selection — deleteTask will raise CommandError on its id.
      await fake.deleteTask('B');
      await settleList(tester);

      await tester.tap(find.byKey(const Key('bulk-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // The pre-vanished row didn't abort the op: A and C were still deleted,
      // the unselected D survives, and the toast counts only what was deleted.
      expect(fake.tasks.map((t) => t.task.title), ['dates']);
      expect(find.text('2 tasks deleted'), findsOneWidget);

      // One Undo restores exactly the two rows this op deleted — B stays gone
      // (it was never part of this op's tokens).
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fake.tasks.map((t) => t.task.title).toSet(), {
        'apples',
        'cheese',
        'dates',
      });
      expect(fake.tasks.any((t) => t.task.id == 'B'), isFalse);
    },
  );

  testWidgets('bulk Complete then Undo restores every prior state, keeping a '
      'pre-completed child completed (G7 #205)', (tester) async {
    // P has two subtasks: c1 open, c2 ALREADY completed. Q is a second
    // top-level task. Subtasks never render as rows — assert the fake's state.
    final fake = await pumpList(
      tester,
      initial: [
        row('P', 'project', position: '1'),
        row('c1', 'child-open', parent: 'P', position: '1'),
        row('c2', 'child-done', parent: 'P', done: true, position: '2'),
        row('Q', 'quest', position: '2'),
      ],
      lists: oneList,
      showCompleted: true,
    );
    await ctrlClick(tester, 'project');
    await ctrlClick(tester, 'quest');
    await tester.tap(find.byKey(const Key('bulk-complete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    TaskStatus st(String id) =>
        fake.tasks.firstWhere((t) => t.task.id == id).task.status;
    // Completing P cascades to its open child c1 (c2 was already done); Q too.
    expect(st('P'), TaskStatus.completed);
    expect(st('c1'), TaskStatus.completed);
    expect(st('c2'), TaskStatus.completed);
    expect(st('Q'), TaskStatus.completed);
    expect(find.text('2 tasks completed'), findsOneWidget);

    // One Undo reopens exactly what the op flipped: P, c1 and Q go back to
    // open — but c2, completed BEFORE the op, stays completed (F11/#184).
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(st('P'), TaskStatus.needsAction);
    expect(st('c1'), TaskStatus.needsAction);
    expect(st('Q'), TaskStatus.needsAction);
    expect(st('c2'), TaskStatus.completed, reason: 'pre-completed child kept');
  });

  testWidgets('bulk reschedule moves the whole selection to tomorrow', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
    );
    await ctrlClick(tester, 'apples');
    await ctrlClick(tester, 'bread');
    // The fake resolves the move against the clock, so run the op under it.
    // ONE "Due" button now carries the whole frozen option set (#243).
    await withClock(testClock, () async {
      await tester.tap(find.byKey(const Key('bulk-due')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });

    // testClock is 2026-06-15 → tomorrow is the 16th (canonical Z form).
    for (final id in ['A', 'B']) {
      expect(
        fake.tasks.firstWhere((t) => t.task.id == id).task.due,
        '2026-06-16T00:00:00.000Z',
      );
    }
    expect(find.text('2 tasks rescheduled'), findsOneWidget);
  });

  // A bulk reschedule runs the SAME #164 consistency rule every other date
  // surface does: setting a parent later pulls its earlier-dated subtasks up
  // with it. Until #274 the bulk path threw that away — it reported "N tasks
  // rescheduled" as a bare info toast and dropped every SetDueResult on the
  // floor, so a selection of two parents silently moved four rows with no way
  // back. The row surface and the detail panel had offered the cascade Undo
  // since #164; bulk was the one date surface that did not.
  testWidgets('a bulk reschedule that cascades offers ONE Undo for all of it', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [
        row('P', 'plan the trip', due: '2026-06-20T00:00:00.000Z'),
        row(
          'p1',
          'book flights',
          parent: 'P',
          position: '2',
          due: '2026-06-18T00:00:00.000Z',
        ),
        row('Q', 'quarterly review', position: '3', due: '2026-06-21'),
        row(
          'q1',
          'gather numbers',
          parent: 'Q',
          position: '4',
          due: '2026-06-19T00:00:00.000Z',
        ),
      ],
      lists: oneList,
    );
    await ctrlClick(tester, 'plan the trip');
    await ctrlClick(tester, 'quarterly review');
    await withClock(testClock, () async {
      await tester.tap(find.byKey(const Key('bulk-due')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(quickDateKey('week')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });

    String? due(String id) =>
        fake.tasks.firstWhere((t) => t.task.id == id).task.due;
    // testClock is 2026-06-15 → next week is the 22nd. Both parents move, and
    // both subtasks are dragged along because they sat before their parent.
    for (final id in ['P', 'p1', 'Q', 'q1']) {
      expect(due(id), '2026-06-22T00:00:00.000Z', reason: '$id moved');
    }

    // ONE Undo for the whole op — the edited rows AND everything the cascade
    // dragged with them.
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(due('P'), '2026-06-20T00:00:00.000Z');
    expect(due('p1'), '2026-06-18T00:00:00.000Z');
    expect(due('Q'), '2026-06-21');
    expect(due('q1'), '2026-06-19T00:00:00.000Z');
  });

  testWidgets('bulk Clear date removes dates and toasts "cleared"', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples', due: '2026-06-20')],
      lists: oneList,
    );
    await ctrlClick(tester, 'apples');
    await tester.tap(find.byKey(const Key('bulk-due')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(quickDateKey('clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fake.tasks.single.task.due, isNull);
    expect(find.text('1 task cleared'), findsOneWidget);
  });

  testWidgets('bulk Move sends every selected task to the chosen list', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: twoLists,
    );
    await ctrlClick(tester, 'apples');
    await ctrlClick(tester, 'bread');
    await tester.tap(find.byKey(const Key('bulk-move')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // Bulk mode shows every list; pick Errands.
    await tester.tap(find.byKey(const Key('move-picker-L2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(fake.movedToList, containsAll(['A->L2', 'B->L2']));
    expect(find.text('2 tasks moved'), findsOneWidget);
  });

  testWidgets('a plain (unmodified) tap opens the task, never selects it', (
    tester,
  ) async {
    final opened = <String>[];
    await pumpList(
      tester,
      initial: [row('A', 'apples')],
      lists: oneList,
      opened: opened,
    );
    await tester.tap(find.text('apples'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // double-tap timeout
    expect(opened, ['A']);
    expect(find.byType(BulkBar), findsNothing);
  });

  // ── the two actions the retired per-row ⋮ handed over (#245) ──────────────

  group('bulk Duplicate + Make subtasks of… (#245)', () {
    testWidgets('bulk Duplicate copies EVERY selected task', (tester) async {
      var seq = 0;
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
        newId: () => 'copy-${seq++}',
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');
      await openBulkOverflow(tester);
      await tester.tap(find.byKey(const Key('bulk-duplicate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final titles = fake.tasks.map((t) => t.task.title).toList();
      expect(titles, containsAll(['apples (copy)', 'bread (copy)']));
      expect(
        titles.where((t) => t == 'cheese (copy)'),
        isEmpty,
        reason: 'an unselected task is never duplicated',
      );
      expect(find.text('2 tasks duplicated'), findsOneWidget);
      expect(find.byType(BulkBar), findsNothing, reason: 'selection cleared');
    });

    testWidgets('bulk Make subtasks of… nests the whole selection under the '
        'picked parent', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'bread');
      await openBulkOverflow(tester);
      await tester.tap(find.byKey(const Key('bulk-demote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Only a legal host is offered: never a task that is itself selected.
      expect(find.byKey(const Key('parent-picker-C')), findsOneWidget);
      expect(find.byKey(const Key('parent-picker-A')), findsNothing);
      expect(find.byKey(const Key('parent-picker-B')), findsNothing);

      await tester.tap(find.byKey(const Key('parent-picker-C')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(fake.tasks.firstWhere((t) => t.task.id == 'A').task.parent, 'C');
      expect(fake.tasks.firstWhere((t) => t.task.id == 'B').task.parent, 'C');
      expect(find.text('2 tasks nested'), findsOneWidget);
    });

    testWidgets('a candidate that ALREADY has subtasks is still a legal host — '
        'the two-level rule caps the CHILD, not the parent', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('A', 'apples'),
        ],
        lists: oneList,
      );
      await ctrlClick(tester, 'apples');
      await openBulkOverflow(tester);
      await tester.tap(find.byKey(const Key('bulk-demote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const Key('parent-picker-P')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(fake.tasks.firstWhere((t) => t.task.id == 'A').task.parent, 'P');
    });

    testWidgets('the action is HIDDEN when a selected task has subtasks of its '
        'own — it can never become a subtask', (tester) async {
      await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('C', 'cheese'),
        ],
        lists: oneList,
      );
      await ctrlClick(tester, 'parent');
      await openBulkOverflow(tester);
      expect(find.byKey(const Key('bulk-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('bulk-demote')), findsNothing);
    });

    testWidgets('the action is HIDDEN for a selection spanning two lists — no '
        'single parent can host it', (tester) async {
      await pumpList(
        tester,
        viewId: 'all',
        initial: [
          row('A', 'apples'),
          row('X', 'elsewhere', listId: 'L2'),
          row('C', 'cheese'),
        ],
        lists: twoLists,
      );
      await ctrlClick(tester, 'apples');
      await ctrlClick(tester, 'elsewhere');
      await openBulkOverflow(tester);
      expect(find.byKey(const Key('bulk-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('bulk-demote')), findsNothing);
    });

    testWidgets('the bar keeps every action reachable on a 400dp phone at 1.3x '
        'text — one row, nothing buried', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('C', 'cheese')],
        lists: oneList,
        size: const Size(400, 900),
        textScale: 1.3,
      );
      await ctrlClick(tester, 'apples');

      expect(tester.takeException(), isNull);
      for (final k in const [
        'bulk-complete',
        'bulk-due',
        'bulk-move',
        'bulk-delete',
        'bulk-clear-selection',
        'bulk-overflow',
      ]) {
        expect(
          find.byKey(Key(k)).hitTestable(),
          findsOneWidget,
          reason: '$k must stay tappable on a narrow phone at 1.3x text',
        );
      }
      // …including the two the "⋮" holds (#265).
      await openBulkOverflow(tester);
      for (final k in const ['bulk-duplicate', 'bulk-demote']) {
        expect(
          find.byKey(Key(k)).hitTestable(),
          findsOneWidget,
          reason: '$k must stay reachable from the overflow at 1.3x text',
        );
      }
    });
  });
}
