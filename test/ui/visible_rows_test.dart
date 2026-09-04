// The list's row derivation is computed ONCE per data change (#274).
//
// Rendering a view means filtering every task by the view's predicate, sorting
// them, sweeping the FULL task set for each parent's inherited date and its
// subtask counts, and — on Focus — partitioning the overdue bucket out. That is
// linear-to-superlinear work over every task the account holds, and it used to
// run inside the list pane's `build`. Every per-row `setState` the pane made —
// a selection toggled, an inline rename opened, a row finishing its collapse
// animation, a commit flash landing — re-ran the whole sweep, on a list that
// promises never to stutter.
//
// [visibleRowsProvider] is where it lives now: memoised per view, recomputed
// only when the tasks, the lists, the prefs, or the just-created pin actually
// move. These tests pin that — a data change derives exactly once, and a row
// interaction derives not at all.

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/visible_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeCommands, list, row;
import 'toast_harness.dart' show wrapWithToast;

void main() {
  testWidgets('a row interaction re-derives nothing', (tester) async {
    final fake = FakeCommands([
      row('A', 'apples'),
      row('B', 'bread', position: '2'),
      row('a1', 'granny smith', parent: 'A', position: '3'),
    ], newId: () => 'gen');
    addTearDown(fake.dispose);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Every value the memoised derivation has yielded, in order.
    final derived = <VisibleRows>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(const Prefs()),
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
          listsProvider.overrideWith(
            (ref) => Stream.value([list('L1', 'My Tasks')]),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          builder: (context, child) => wrapWithToast(context, child),
          home: Scaffold(
            body: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    derived.add(ref.watch(visibleRowsProvider('all')));
                    return const SizedBox.shrink();
                  },
                ),
                const Expanded(
                  child: TaskListView(
                    viewId: 'all',
                    selectedTaskId: null,
                    onOpenTask: _ignore,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // The stream's first snapshot is one derivation; the empty pre-data frame
    // may be another. Whatever it took to get here, it is the baseline.
    expect(derived.last.rows.map((r) => r.stored.task.id), ['A', 'B']);
    // The per-row sweep really is in there: 'apples' carries its subtask.
    expect(derived.last.rows.first.subtaskTotal, 1);
    final baseline = derived.length;

    // Ctrl-click a row: selection is pane state, not list data.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('apples'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // The bulk bar collapses its height IN (#265), so give the slot its frames.
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      find.text('1 selected'),
      findsOneWidget,
      reason: 'the interaction really did change what the user sees',
    );
    expect(
      derived.length,
      baseline,
      reason: 'selecting a row re-derives no rows',
    );

    // A real data change DOES derive — exactly once.
    await fake.renameTask('B', 'brioche');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(derived.length, baseline + 1);
    expect(
      derived.last.rows.map((r) => r.stored.task.title),
      containsAll(<String>['apples', 'brioche']),
    );
  });
}

void _ignore(String _) {}
