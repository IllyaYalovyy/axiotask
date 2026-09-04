// #260 — first-frame content: the list waits for the store's first snapshot
// WITHOUT a spinner and without pretending the account is empty.
//
// The store is local. Measured on this machine, a file-backed first snapshot
// costs 7–13 ms at 50–1000 tasks and 32 ms at 5000 (designs/cold-start.md
// §"First snapshot") — an order of magnitude inside the
// [MotionDurations.firstSnapshotGrace]. So the honest first frame is CONTENT,
// and the three failures this suite protects against are:
//
//   • a spinner — for a wait that is over before the eye can find it, a
//     spinner is a stutter the app inflicts on itself. There must never be
//     one, on any frame of this path;
//   • "No tasks yet" flashed at a user who has 200 tasks, because the pane
//     read "not loaded yet" as "empty" (the pre-#260 behaviour);
//   • a wait that genuinely outlives the grace showing NOTHING at all — a
//     dead pane the user cannot tell from a hung app. Past the grace the pane
//     admits it is waiting, with 3 skeleton rows that cross-fade into the real
//     ones.

import 'dart:async';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/empty_state.dart';
import 'package:axiotask/src/ui/first_snapshot.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_motion.dart';
import 'composed_list.dart';
import 'detail_harness.dart' show FakeCommands, list, row;

const _phone = Size(400, 800);

/// A live [TaskListView] over a store that answers only when the test says so.
///
/// Returns the "the store answers this" hook — everything here turns on WHEN
/// it is called relative to the grace.
Future<void Function(List<StoredTask>)> _pumpWaiting(
  WidgetTester tester, {
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = StreamController<List<StoredTask>>();
  addTearDown(store.close);
  final fake = FakeCommands(const []);
  addTearDown(fake.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(const Prefs()),
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => store.stream),
        listsProvider.overrideWith(
          (ref) => Stream.value([list('L1', 'My Tasks')]),
        ),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: Scaffold(
          body: composedList(viewId: 'all', onOpenTask: _noop),
        ),
      ),
    ),
  );
  await tester.pump();
  return store.add;
}

void _noop(String _) {}

final _spinner = find.byType(CircularProgressIndicator);

void main() {
  testWidgets('the first frame is blank, never a spinner and never a verdict', (
    tester,
  ) async {
    await _pumpWaiting(tester);

    expect(_spinner, findsNothing, reason: 'the app never spins');
    expect(
      find.byType(SkeletonRow),
      findsNothing,
      reason: 'inside the grace there is nothing to apologise for yet',
    );
    expect(
      find.byType(EmptyStateView),
      findsNothing,
      reason: '"no tasks" is an ANSWER, and the store has not given one',
    );
    expect(find.byType(TaskRow), findsNothing);
  });

  testWidgets('a snapshot inside the grace lands as content, with no skeleton '
      'and no spinner in between', (tester) async {
    final answer = await _pumpWaiting(tester);

    // Half the grace goes by — the realistic case by an order of magnitude.
    await tester.pump(MotionDurations.firstSnapshotGrace ~/ 2);
    expect(find.byType(SkeletonRow), findsNothing);
    expect(_spinner, findsNothing);

    answer([row('T1', 'buy milk'), row('T2', 'call the bank')]);
    await tester.pump();

    expect(
      find.byType(TaskRow),
      findsNWidgets(2),
      reason: 'the rows are there on the frame the store answers',
    );
    expect(find.byType(SkeletonRow), findsNothing);
    expect(_spinner, findsNothing);
  });

  testWidgets('a snapshot that outlives the grace gets 3 skeleton rows that '
      'cross-fade into the real ones', (tester) async {
    final answer = await _pumpWaiting(tester);

    await pumpMotion(tester, MotionDurations.firstSnapshotGrace);
    expect(
      find.byType(SkeletonRow),
      findsNWidgets(3),
      reason: 'past the grace the pane says it is working — without a spinner',
    );
    expect(_spinner, findsNothing);
    expect(find.byType(EmptyStateView), findsNothing);

    answer([row('T1', 'buy milk')]);
    // One frame for the snapshot to land and start the fade, then half of it:
    // both are on screen, neither at full opacity — that overlap IS the
    // cross-fade.
    await tester.pump();
    await pumpMotion(tester, MotionDurations.medium, fraction: 0.5);
    final skeletonOpacity = tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(SkeletonRow).first,
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    final contentOpacity = tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(TaskRow).first,
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(skeletonOpacity, lessThan(1));
    expect(skeletonOpacity, greaterThan(0));
    expect(contentOpacity, lessThan(1));
    expect(contentOpacity, greaterThan(0));

    await pumpMotion(tester, MotionDurations.medium);
    expect(find.byType(TaskRow), findsOneWidget);
    expect(
      find.byType(SkeletonRow),
      findsNothing,
      reason: 'the placeholder is gone once the content it stood for is there',
    );
    expect(_spinner, findsNothing);
  });

  testWidgets('an account that really IS empty gets the empty state, not a '
      'skeleton left standing', (tester) async {
    final answer = await _pumpWaiting(tester);
    await pumpMotion(tester, MotionDurations.firstSnapshotGrace);
    expect(find.byType(SkeletonRow), findsNWidgets(3));

    answer(const []);
    await pumpMotion(tester, MotionDurations.medium);
    await pumpMotion(tester, MotionDurations.medium);

    expect(find.byType(SkeletonRow), findsNothing);
    expect(find.text('No tasks yet'), findsOneWidget);
    expect(_spinner, findsNothing);
  });

  testWidgets('reduced motion: the skeleton is replaced, not cross-faded', (
    tester,
  ) async {
    final answer = await _pumpWaiting(tester, reducedMotion: true);
    await pumpMotion(tester, MotionDurations.firstSnapshotGrace);
    expect(
      find.byType(SkeletonRow),
      findsNWidgets(3),
      reason:
          'the grace is a threshold, not motion — a reduced-motion user is '
          'still told the app is working',
    );

    answer([row('T1', 'buy milk')]);
    // The same two frames the full-motion test spends on the fade — with the
    // span resolved to zero, which is what reduced motion makes of it.
    await pumpMotion(tester, Duration.zero);
    expect(
      find.byType(TaskRow),
      findsOneWidget,
      reason: 'the rows are simply there, on the frame the store answers',
    );
    expect(
      find.byType(SkeletonRow),
      findsNothing,
      reason: 'and the placeholder is simply gone — no fade frames at all',
    );
  });
}
