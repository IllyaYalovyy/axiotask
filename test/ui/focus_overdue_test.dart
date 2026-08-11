// F17 (#195): the Focus view renders an "Overdue (N)" headed bucket ABOVE the
// dated bucket. These are WIDGET tests over the real [TaskListView]: they assert
// what RENDERS — the heading text, its count, and that it sits above the overdue
// rows while the dated rows fall below — not that any method fired. The heading
// must appear ONLY in Focus and ONLY when there is at least one overdue card.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'list_harness.dart';

// list_harness pins the clock to 2026-06-15, so these fixed dates are stable.
StoredTask _task(
  String id,
  String title, {
  required String? due,
  String pos = '1',
}) => StoredTask(
  task: Task(
    id: id,
    position: pos,
    title: title,
    status: TaskStatus.needsAction,
    due: due == null ? null : '${due}T00:00:00.000Z',
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

const _myTasks = StoredTaskList(
  list: TaskList(id: 'L1', title: 'My Tasks', etag: 'e', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

double _topOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  testWidgets('Focus shows an "Overdue (N)" heading above the overdue rows', (
    tester,
  ) async {
    await pumpList(
      tester,
      viewId: 'focus',
      initial: [
        // Two overdue (before 2026-06-15) and two dated-within-window.
        _task('over1', 'Pay the invoice', due: '2026-06-10', pos: '1'),
        _task('today', 'Stand-up notes', due: '2026-06-15', pos: '2'),
        _task('over2', 'Renew the domain', due: '2026-06-13', pos: '3'),
        _task('soon', 'Ship the release', due: '2026-06-18', pos: '4'),
      ],
      lists: const [_myTasks],
      // A due sort makes the row order deterministic for the position asserts.
      sortPerView: const {'focus': 'due'},
    );

    // The heading names the overdue COUNT (2), not the total.
    final heading = find.text('Overdue (2)');
    expect(heading, findsOneWidget);

    // It sits above the overdue rows, which sit above the dated rows.
    final headingTop = _topOf(tester, heading);
    final over1Top = _topOf(tester, find.text('Pay the invoice'));
    final over2Top = _topOf(tester, find.text('Renew the domain'));
    final todayTop = _topOf(tester, find.text('Stand-up notes'));
    final soonTop = _topOf(tester, find.text('Ship the release'));

    expect(headingTop, lessThan(over1Top));
    expect(over1Top, lessThan(over2Top)); // earliest-overdue first (due sort)
    expect(over2Top, lessThan(todayTop)); // whole overdue bucket above the rest
    expect(todayTop, lessThan(soonTop));
    // All four cards still render (nothing dropped by the partition).
    expect(find.byType(TaskRow), findsNWidgets(4));
  });

  testWidgets('Focus with nothing overdue renders NO heading', (tester) async {
    await pumpList(
      tester,
      viewId: 'focus',
      initial: [
        _task('today', 'Stand-up notes', due: '2026-06-15'),
        _task('soon', 'Ship the release', due: '2026-06-18'),
      ],
      lists: const [_myTasks],
      sortPerView: const {'focus': 'due'},
    );

    expect(find.textContaining('Overdue ('), findsNothing);
    expect(find.byType(TaskRow), findsNWidgets(2));
  });

  testWidgets(
    'the heading coexists with the reorderable (manual-sort) list, drag intact',
    (tester) async {
      // Manual sort renders Focus as a ReorderableListView; the heading is a
      // non-draggable item 0. Pump it (default manual sort) with overdue rows and
      // assert it builds — a bad header slot would throw the ReorderableListView
      // key/drag asserts — and that the drag handles still ride the rows.
      await pumpList(
        tester,
        viewId: 'focus',
        initial: [
          _task('over1', 'Pay the invoice', due: '2026-06-10', pos: '1'),
          _task('today', 'Stand-up notes', due: '2026-06-15', pos: '2'),
        ],
        lists: const [_myTasks],
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Overdue (1)'), findsOneWidget);
      // A drag handle per row (manual sort), and the heading above the rows.
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
      expect(
        _topOf(tester, find.text('Overdue (1)')),
        lessThan(_topOf(tester, find.text('Pay the invoice'))),
      );
    },
  );

  testWidgets('a NON-Focus view never renders the Overdue heading', (
    tester,
  ) async {
    // The same overdue tasks in All Tasks: no partition, no heading (the
    // Overdue section is a Focus-only convenience).
    await pumpList(
      tester,
      viewId: 'all',
      initial: [
        _task('over1', 'Pay the invoice', due: '2026-06-10'),
        _task('today', 'Stand-up notes', due: '2026-06-15'),
      ],
      lists: const [_myTasks],
    );

    expect(find.textContaining('Overdue ('), findsNothing);
  });
}
