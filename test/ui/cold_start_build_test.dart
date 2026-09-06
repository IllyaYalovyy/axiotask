// #290 — the list body builds OUTSIDE a frame, and must survive it.
//
// A widget's first build does not necessarily happen inside a frame: at
// startup the root widget is attached from a timer, before the engine has
// begun one, so the whole tree — the list body included — is inflated with no
// frame in flight. `SchedulerBinding.currentFrameTimeStamp` is only valid
// inside a frame (it is `_currentFrameTimeStamp!`, cleared the moment a frame
// ends), so reading it from `build` threw "Null check operator used on a null
// value" on EVERY cold start: the framework caught it, the first frame of the
// launch rendered the error subtree where the list should be, and the next
// frame quietly repaired it.
//
// So this suite asserts what the user sees on a build that runs while the
// scheduler is idle: the LIST (or the empty state), never an error box, and no
// exception reported at all. The mechanism it exercises is the one that failed
// — a build of the list body with no frame in flight — driven here by marking
// the element dirty and running the build scope by hand, which is exactly what
// the root attach does at startup.

import 'package:axiotask/src/ui/empty_state.dart';
import 'package:axiotask/src/ui/task_list_body.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// Rebuild the list body with NO frame in flight — the startup condition.
  void buildOutsideFrame(WidgetTester tester) {
    expect(
      SchedulerBinding.instance.schedulerPhase,
      SchedulerPhase.idle,
      reason: 'the scenario is a build with no frame in flight',
    );
    tester.element(find.byType(TaskListBody)).markNeedsBuild();
    tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
  }

  testWidgets('a list built outside a frame renders its rows, not an error', (
    tester,
  ) async {
    await pumpList(
      tester,
      initial: [row('A', 'Buy milk'), row('B', 'Call the plumber')],
      lists: oneList,
    );

    buildOutsideFrame(tester);

    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.text('Call the plumber'), findsOneWidget);
    expect(find.byType(TaskRow), findsNWidgets(2));
  });

  testWidgets(
    'an EMPTY view built outside a frame shows its empty state (non-happy path)',
    (tester) async {
      await pumpList(tester, initial: [], lists: oneList);
      expect(find.byType(EmptyStateView), findsOneWidget);

      buildOutsideFrame(tester);

      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byType(EmptyStateView), findsOneWidget);
    },
  );
}
