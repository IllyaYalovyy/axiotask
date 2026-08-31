// BulkOps (MIGRATION-PLAN §5 T7.6). Multi-select + the bulk bar, driven through
// the real [TaskListView] over the mutating [FakeBackend], so every assertion is
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
}
