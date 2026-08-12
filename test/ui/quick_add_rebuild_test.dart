// F20 (#199) quick-add rebuild scoping — the typing half of the pull-storm
// family. A keystroke in the always-visible quick-add bar must repaint ONLY the
// bar (its live date preview), never re-run the whole list build
// (visibleTasksForView + the per-row effective-due/subtask-count sweep). The
// proxy for "the list rebuilt" is widget identity: when TaskListView.build does
// NOT re-run, the element for a task row keeps the exact same TaskRow widget
// instance across the keystroke; a full rebuild constructs a fresh one.
//
// The failure this prevents: onChanged calling setState on the whole list state,
// so every character typed re-derives the entire visible set and rebuilds every
// row — quadratic churn on a long list while the user is just naming a task.

import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  testWidgets('typing in quick-add rebuilds only the bar, not the task rows', (
    tester,
  ) async {
    await pumpList(
      tester,
      initial: [
        row('A', 'Alpha', position: '1'),
        row('B', 'Beta', position: '2'),
      ],
      lists: [list('L1', 'My Tasks')],
    );

    // Focus the quick-add field first so the subsequent keystroke is the only
    // change under test (the focus request itself is not what we measure).
    await tester.tap(find.byType(TextField));
    await settleList(tester);

    // The exact TaskRow widget instance currently mounted for row A.
    final rowABefore = tester.widget<TaskRow>(find.byKey(const ValueKey('A')));

    // A keystroke that DOES produce a date preview — a trailing "tomorrow"
    // after real title text (the phrase must leave a non-empty title). Proof
    // the bar itself must (and does) rebuild to show the chip.
    await tester.enterText(find.byType(TextField), 'Buy milk tomorrow');
    await tester.pump();

    // The bar rebuilt: the natural-language date preview chip is now shown.
    expect(
      find.byType(Chip),
      findsOneWidget,
      reason: 'the quick-add bar rebuilt to render the date preview',
    );

    // The list did NOT rebuild: row A is the SAME widget instance. A full
    // TaskListView.build would have constructed a fresh TaskRow for A.
    final rowAAfter = tester.widget<TaskRow>(find.byKey(const ValueKey('A')));
    expect(
      identical(rowABefore, rowAAfter),
      isTrue,
      reason:
          'a quick-add keystroke must not rebuild the task list — the row '
          'widget must be reused, not reconstructed',
    );
  });
}
