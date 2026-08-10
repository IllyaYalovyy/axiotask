// Pull-storm editing guard (T10.1 / MIGRATION-PLAN §4).
//
// drift invalidation is table-granular: a sync pull re-fires every open watch,
// re-emitting the whole task list. The store-level dedup (store_test.dart /
// store_all_tasks_test.dart) collapses NO-OP re-emissions, but a genuine
// concurrent write — a pull landing an edit to ANOTHER row — still rebuilds the
// list. This is the widget half of the guard: an in-progress inline rename must
// SURVIVE that rebuild intact. The rows are keyed by task id, so Flutter reuses
// each row's element/State across the rebuild and the rename editor (its
// controller text AND its focus) is never thrown away mid-keystroke.
//
// The failure this prevents: a list re-emission during editing that clobbers the
// focused editor — the user is typing a new title, a background sync ticks, and
// their half-typed text or cursor vanishes. That is exactly the reflow/rebuild
// hazard the plan calls out ("inline rename survives a concurrent store write").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  testWidgets(
    'inline rename survives a concurrent store write (pull-storm editing guard)',
    (tester) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'Alpha', position: '1'),
          row('B', 'Beta', position: '2'),
        ],
        lists: [list('L1', 'My Tasks')],
      );

      // Enter inline rename on row A (double-tap its title). The two-tap-with-gap
      // sequence is the proven way to trigger the row's onDoubleTap without the
      // single-tap "open detail" path (see task_row_test).
      await tester.tap(find.text('Alpha'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('Alpha'));
      await settleList(tester);

      // The editor is pre-filled with the current title; the always-present
      // quick-add field is empty, so this uniquely targets the row's rename input.
      final editor = find.widgetWithText(TextField, 'Alpha');
      expect(
        editor,
        findsOneWidget,
        reason: 'inline rename is active on row A',
      );
      await tester.enterText(editor, 'Alpha edited'); // uncommitted keystrokes
      await tester.pump();

      // A concurrent store write to a DIFFERENT row (a sync pull landing) —
      // exactly the table-granular re-emission that re-fires the open list watch.
      fake.pushExternal('B', 'Beta changed');
      await settleList(tester);

      // The pull landed: row B shows its new title (the write was NOT dropped).
      expect(find.text('Beta changed'), findsOneWidget);

      // The in-progress rename SURVIVED the rebuild: the editor still holds the
      // uncommitted text, and it was never committed or discarded behind the
      // user's back.
      final surviving = find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == 'Alpha edited',
      );
      expect(
        surviving,
        findsOneWidget,
        reason:
            'the half-typed title must not be thrown away by the re-emission',
      );
      expect(
        tester.widget<EditableText>(surviving).focusNode.hasFocus,
        isTrue,
        reason: 'the rename editor kept focus across the concurrent write',
      );
      expect(
        fake.renamed,
        isEmpty,
        reason: 'the concurrent write must not silently commit the open rename',
      );
    },
  );
}
