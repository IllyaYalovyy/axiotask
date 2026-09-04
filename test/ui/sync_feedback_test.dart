// Quiet visible sync (#255) — what the user actually sees while a sync runs,
// and what they see once it lands.
//
// The failures these prevent, one per group:
//
//  • a background sync that is invisible again (the whole point of #255), or
//    one whose line never goes away because the run failed;
//  • a line that costs layout — mounted as the app bar's `bottom`, or as a
//    Column child of the toolbar, either of which pushes every row down 2dp
//    the moment sync starts and pulls it back when it ends (a list that
//    twitches once a minute, forever);
//  • a footer that congratulates the user sixty times an hour, because the
//    check-mark fires on every completed run instead of only on the runs that
//    moved data;
//  • a pull-to-refresh that turns its own spinner for the whole run WHILE the
//    line runs beside it — two indicators for one sync, which is exactly the
//    "a manual and an automatic sync look like one thing" the design rules
//    out.
//
// Determinism: the line's running state is an INDETERMINATE progress
// indicator, so it never settles — every pump here is an explicit span named
// from [MotionDurations] via `pumpMotion`, and `pumpAndSettle` appears
// nowhere.

import 'dart:async';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/ui/auth/auth_sync_footer.dart';
import 'package:axiotask/src/ui/auth/auth_sync_status.dart';
import 'package:axiotask/src/ui/auth/sidebar_auth_sync_footer.dart';
import 'package:axiotask/src/ui/list_detail_scaffold.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/sync_feedback.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_motion.dart';
import 'detail_harness.dart' show FakeCommands, list, row;

const _destinations = [
  ShellDestination(
    icon: Icons.bolt_outlined,
    selectedIcon: Icons.bolt,
    label: 'Focus',
  ),
];

void _noop(String _) {}

final _line = find.byKey(const Key('sync-progress-line'));
final _check = find.byKey(const Key('sync-check-mark'));

/// The compact shell (a phone width) with [running] driving its sync line, and
/// one identifiable row in the list so layout can be measured against it.
Widget _shell({required bool running, bool reducedMotion = false}) =>
    MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        disableAnimations: reducedMotion,
      ),
      child: MaterialApp(
        theme: buildLightTheme(),
        home: ListDetailScaffold(
          sidebar: const Text('SIDEBAR'),
          destinations: _destinations,
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          title: 'All Tasks',
          syncLine: SyncProgressLine(running: running),
          list: const Align(
            alignment: Alignment.topLeft,
            child: Text('FIRST-ROW'),
          ),
        ),
      ),
    );

void main() {
  group('the sync line', () {
    testWidgets('a running sync puts a 2dp line on the app bar bottom edge', (
      tester,
    ) async {
      await tester.pumpWidget(_shell(running: false));
      expect(
        _line,
        findsNothing,
        reason: 'nothing syncing → no line at all (quiet sync)',
      );

      await tester.pumpWidget(_shell(running: true));
      await tester.pump();

      expect(_line, findsOneWidget);
      expect(tester.getSize(_line).height, kSyncLineHeight);
      // On the bar's EDGE: the line's bottom is the app bar's bottom, and it
      // spans the full width.
      final bar = tester.getRect(find.byType(AppBar).first);
      final line = tester.getRect(_line);
      expect(line.bottom, moreOrLessEquals(bar.bottom, epsilon: 0.5));
      expect(line.left, bar.left);
      expect(line.right, bar.right);
    });

    testWidgets('a finished run fills to the end, fades, and is gone', (
      tester,
    ) async {
      await tester.pumpWidget(_shell(running: true));
      await tester.pump();

      await tester.pumpWidget(_shell(running: false));
      await tester.pump();
      // The run is over but the line has not vanished: it is finishing — a
      // determinate bar running to the end, so the sync reads as COMPLETED
      // rather than as interrupted.
      expect(_line, findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(_line).value,
        isNotNull,
        reason: 'the fill is determinate — an indeterminate sweep never ends',
      );

      // Mid-fade it is still there…
      await pumpMotion(tester, MotionDurations.syncLineFinish, fraction: 0.75);
      expect(_line, findsOneWidget);
      // …and once the fade is over, gone.
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(_line, findsNothing);
    });

    testWidgets('a run starting inside the previous fade restarts the line', (
      tester,
    ) async {
      await tester.pumpWidget(_shell(running: true));
      await tester.pump();
      await tester.pumpWidget(_shell(running: false));
      await pumpMotion(tester, MotionDurations.syncLineFinish, fraction: 0.5);

      // The next run arrives while the previous one is still fading out.
      await tester.pumpWidget(_shell(running: true));
      await tester.pump();
      expect(
        tester.widget<LinearProgressIndicator>(_line).value,
        isNull,
        reason: 'the new run is indeterminate again, not a half-faded fill',
      );

      // And the abandoned fade cannot take the line away underneath it.
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(_line, findsOneWidget);
    });

    testWidgets('reduced motion: the line is simply there, then simply gone', (
      tester,
    ) async {
      await tester.pumpWidget(_shell(running: true, reducedMotion: true));
      await tester.pump();
      expect(
        _line,
        findsOneWidget,
        reason: 'the line is STATUS, not decoration — it still appears',
      );

      await tester.pumpWidget(_shell(running: false, reducedMotion: true));
      await tester.pump();
      expect(_line, findsNothing, reason: 'no fill, no fade — one frame');
    });

    testWidgets('the line never moves a row (it costs no layout)', (
      tester,
    ) async {
      await tester.pumpWidget(_shell(running: false));
      await tester.pump();
      final atRest = tester.getTopLeft(find.text('FIRST-ROW'));

      await tester.pumpWidget(_shell(running: true));
      await tester.pump();
      expect(_line, findsOneWidget);
      expect(
        tester.getTopLeft(find.text('FIRST-ROW')),
        atRest,
        reason: 'a sync starting must not push the list down',
      );

      // …and it does not spring back when the run ends, either.
      await tester.pumpWidget(_shell(running: false));
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(tester.getTopLeft(find.text('FIRST-ROW')), atRest);
    });
  });

  group('the live sync line', () {
    /// A stream event needs TWO frames to reach the widget: one for the
    /// microtask that delivers it into the provider, one for the rebuild that
    /// follows. Anything less is a test that passes on scheduling luck.
    Future<void> deliver(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    /// [LiveSyncLine] over a hand-driven run-event stream — the wiring the
    /// desktop list toolbar and the compact app bar both mount.
    Future<void> pumpLive(
      WidgetTester tester,
      Stream<SyncRunEvent> events,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [syncRunEventsProvider.overrideWith((ref) => events)],
          child: const MaterialApp(home: Scaffold(body: LiveSyncLine())),
        ),
      );
    }

    testWidgets('a started run raises the line; a finished one lowers it', (
      tester,
    ) async {
      final events = StreamController<SyncRunEvent>();
      // NOT `addTearDown(events.close)`: teardown runs after the fake-async
      // zone has stopped pumping microtasks, so awaiting the close future
      // hangs the whole suite for the full 10-minute test timeout.
      addTearDown(() => unawaited(events.close()));
      await pumpLive(tester, events.stream);
      await deliver(tester);
      expect(_line, findsNothing);

      events.add(const SyncRunEvent.started());
      await deliver(tester);
      expect(_line, findsOneWidget);

      events.add(const SyncRunEvent.finished(changed: true, failed: false));
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(_line, findsNothing);
    });

    testWidgets('a FAILED run takes the line down too — it never sticks', (
      tester,
    ) async {
      final events = StreamController<SyncRunEvent>();
      // NOT `addTearDown(events.close)`: teardown runs after the fake-async
      // zone has stopped pumping microtasks, so awaiting the close future
      // hangs the whole suite for the full 10-minute test timeout.
      addTearDown(() => unawaited(events.close()));
      await pumpLive(tester, events.stream);
      events.add(const SyncRunEvent.started());
      await deliver(tester);
      expect(_line, findsOneWidget);

      events.add(const SyncRunEvent.finished(changed: false, failed: true));
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(
        _line,
        findsNothing,
        reason: 'a failure leaves no line behind (its toast says the rest)',
      );
    });
  });

  group('the live footer', () {
    /// The REAL sidebar footer over a hand-driven run-event stream: the wiring
    /// that decides WHICH runs are worth a check-mark.
    Future<void Function(SyncRunEvent)> pumpLiveFooter(
      WidgetTester tester,
    ) async {
      final events = StreamController<SyncRunEvent>();
      addTearDown(() => unawaited(events.close()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncRunEventsProvider.overrideWith((ref) => events.stream),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: SizedBox(width: 240, child: SidebarAuthSyncFooter()),
            ),
          ),
        ),
      );
      await tester.pump();
      return events.add;
    }

    testWidgets('only a run that MOVED data draws the check', (tester) async {
      final emit = await pumpLiveFooter(tester);

      // The once-a-minute poll that finds nothing: the user is told nothing.
      emit(const SyncRunEvent.started());
      emit(const SyncRunEvent.finished(changed: false, failed: false));
      await pumpMotion(tester, MotionDurations.syncCheck, fraction: 0.3);
      expect(_check, findsNothing);

      // A run that actually pulled or pushed something: one check.
      emit(const SyncRunEvent.started());
      emit(const SyncRunEvent.finished(changed: true, failed: false));
      await pumpMotion(tester, MotionDurations.syncCheck, fraction: 0.3);
      expect(_check, findsOneWidget);

      await pumpMotion(tester, MotionDurations.syncCheck);
      expect(_check, findsNothing);
    });

    testWidgets('a FAILED run never draws a check', (tester) async {
      final emit = await pumpLiveFooter(tester);

      emit(const SyncRunEvent.started());
      emit(const SyncRunEvent.finished(changed: false, failed: true));
      await pumpMotion(tester, MotionDurations.syncCheck, fraction: 0.3);
      expect(
        _check,
        findsNothing,
        reason: 'a failure has confirmed nothing — it has its own path',
      );
    });
  });

  group('the footer check-mark', () {
    Future<void> pumpFooter(
      WidgetTester tester,
      int confirmedRuns, {
      bool reducedMotion = false,
    }) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reducedMotion),
          child: MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 240,
                child: AuthSyncFooter(
                  status: const AuthSyncStatus(
                    isAuthenticated: true,
                    needsReauth: false,
                    lastSynced: '2026-08-31T10:00:00Z',
                  ),
                  confirmedRuns: confirmedRuns,
                  onSignIn: () {},
                  onSignOut: () {},
                  onSync: () {},
                  onOpenProperties: () {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a run that changed something draws a check, then clears', (
      tester,
    ) async {
      await pumpFooter(tester, 0);
      expect(_check, findsNothing, reason: 'a mounted footer draws no check');
      final dotAtRest = tester.getRect(
        find.byKey(const Key('auth-footer-dot')),
      );

      await pumpFooter(tester, 1);
      await pumpMotion(tester, MotionDurations.syncCheck, fraction: 0.3);
      expect(_check, findsOneWidget);
      // Over the dot, never beside it: the dot's own box has not moved, so
      // nothing in the footer has.
      expect(
        tester.getRect(find.byKey(const Key('auth-footer-dot'))),
        dotAtRest,
      );
      expect(
        tester.getRect(_check).center,
        offsetMoreOrLessEquals(dotAtRest.center, epsilon: 0.5),
      );

      await pumpMotion(tester, MotionDurations.syncCheck);
      expect(_check, findsNothing, reason: 'the mark clears back to the dot');
    });

    testWidgets('a run that changed nothing draws no check at all', (
      tester,
    ) async {
      await pumpFooter(tester, 3);
      await tester.pump();
      // A no-op poll leaves the count where it was — the footer must not react
      // to a rebuild alone.
      await pumpFooter(tester, 3);
      await pumpMotion(tester, MotionDurations.syncCheck, fraction: 0.3);
      expect(_check, findsNothing);
    });

    testWidgets('reduced motion: no mark is drawn', (tester) async {
      await pumpFooter(tester, 0, reducedMotion: true);
      await pumpFooter(tester, 1, reducedMotion: true);
      await pumpMotion(tester, Duration.zero);
      expect(
        _check,
        findsNothing,
        reason: 'a stroke drawing itself in IS the travel (the #252 rule)',
      );
    });
  });

  group('pull-to-refresh', () {
    /// The REAL compact chrome — [ListDetailScaffold] + a live [TaskListView]
    /// over the in-memory backend — so the [RefreshIndicator] under test is the
    /// one the phone actually mounts, not a stand-in.
    ///
    /// [onRefresh] is the runtime seam the gesture calls; [events] is the run
    /// stream both the app bar's line and the gesture read.
    Future<void> pumpChrome(
      WidgetTester tester, {
      required FakeCommands fake,
      required Future<void> Function() onRefresh,
      required Stream<SyncRunEvent> events,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(
              const Prefs(sortPerView: {'all': 'alpha'}),
            ),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            listsProvider.overrideWith(
              (ref) => Stream.value([list('L1', 'L')]),
            ),
            refreshActionProvider.overrideWithValue(onRefresh),
            syncRunEventsProvider.overrideWith((ref) => events),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: ListDetailScaffold(
                sidebar: const Text('SIDEBAR'),
                destinations: _destinations,
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                title: 'All Tasks',
                syncLine: const LiveSyncLine(),
                list: const TaskListView(
                  viewId: 'all',
                  selectedTaskId: null,
                  onOpenTask: _noop,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// Arm and fire the pull. The spans are the FRAMEWORK's own (the drag
    /// settle and [RefreshIndicator]'s arm/retract animations), not ours —
    /// there is no [MotionDurations] token for them, and a generous fixed span
    /// is what drives them past their end deterministically.
    Future<void> pullDown(WidgetTester tester) async {
      await tester.fling(find.text('a'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('the gesture hands its spinner off to the line — one '
        'indicator for one sync, never two', (tester) async {
      final fake = FakeCommands([row('T1', 'a'), row('T2', 'b')]);
      addTearDown(fake.dispose);
      final events = StreamController<SyncRunEvent>.broadcast();
      addTearDown(() => unawaited(events.close()));
      // The run the gesture kicks off, and never finishes while the gesture is
      // being observed: a real sync outlives the pull that asked for it.
      final run = Completer<void>();
      await pumpChrome(
        tester,
        fake: fake,
        events: events.stream,
        onRefresh: () {
          events.add(const SyncRunEvent.started());
          return run.future;
        },
      );

      await pullDown(tester);
      // Once the gesture's future is done the framework retracts the spinner
      // over an animation of its own: one frame for the hand-off to land, then
      // two spans to drive that retraction past its end.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byType(RefreshProgressIndicator),
        findsNothing,
        reason:
            'the run is still going, but the SPINNER has handed over — '
            'the gesture completed into the line instead of turning beside it',
      );
      expect(
        _line,
        findsOneWidget,
        reason: 'and the line is what is carrying the run now',
      );
      expect(
        tester.widget<LinearProgressIndicator>(_line).value,
        isNull,
        reason: 'still indeterminate — the run has not landed yet',
      );

      // The run lands: the line finishes and goes, and nothing brings the
      // spinner back.
      events.add(const SyncRunEvent.finished(changed: true, failed: false));
      run.complete();
      await pumpMotion(tester, MotionDurations.syncLineFinish);
      expect(_line, findsNothing);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });

    testWidgets('a refresh that raises no run at all still ends the gesture', (
      tester,
    ) async {
      // Signed out (the runtime's refresh is a documented no-op) or no runtime
      // mounted at all: nothing ever emits a started event. The hand-off must
      // not be the ONLY way out, or the spinner turns forever.
      final fake = FakeCommands([row('T1', 'a'), row('T2', 'b')]);
      addTearDown(fake.dispose);
      final refresh = Completer<void>();
      await pumpChrome(
        tester,
        fake: fake,
        events: const Stream<SyncRunEvent>.empty(),
        onRefresh: () => refresh.future,
      );

      await pullDown(tester);
      expect(
        find.byType(RefreshProgressIndicator),
        findsOneWidget,
        reason: 'no run to hand off to — the gesture keeps its own spinner',
      );

      refresh.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(_line, findsNothing, reason: 'no run happened, so no line');
    });

    testWidgets('the spinner is drawn in the app\'s primary colour (#260)', (
      tester,
    ) async {
      // The gesture's own indicator and the line it hands off to are ONE piece
      // of feedback, so they are one colour: whatever the theme calls primary,
      // never whatever a future Material default happens to pick.
      final fake = FakeCommands([row('T1', 'a'), row('T2', 'b')]);
      addTearDown(fake.dispose);
      final refresh = Completer<void>();
      addTearDown(refresh.complete);
      await pumpChrome(
        tester,
        fake: fake,
        events: const Stream<SyncRunEvent>.empty(),
        onRefresh: () => refresh.future,
      );

      await pullDown(tester);
      final drawn = tester
          .widget<RefreshProgressIndicator>(
            find.byType(RefreshProgressIndicator),
          )
          .valueColor!
          .value!;
      final primary = buildLightTheme().colorScheme.primary;
      expect(
        (drawn.r, drawn.g, drawn.b),
        (primary.r, primary.g, primary.b),
        reason: 'the arc is the theme\'s primary',
      );
      expect(drawn.a, greaterThan(0), reason: 'and it is actually painted');
    });

    testWidgets('the list can leave mid-run — the hand-off outlives nothing', (
      tester,
    ) async {
      // The Android interruption case: the user pulls, then immediately opens
      // a task / switches view, and the list that started the gesture is gone
      // while the sync is still going. The hand-off holds a live provider
      // subscription and an unresolved future across that unmount.
      final fake = FakeCommands([row('T1', 'a'), row('T2', 'b')]);
      addTearDown(fake.dispose);
      final events = StreamController<SyncRunEvent>.broadcast();
      addTearDown(() => unawaited(events.close()));
      final run = Completer<void>();
      await pumpChrome(
        tester,
        fake: fake,
        events: events.stream,
        onRefresh: () => run.future,
      );

      await pullDown(tester);
      await tester.pumpWidget(const MaterialApp(home: Text('GONE')));
      // The run lands after the list that asked for it is off the tree.
      events.add(const SyncRunEvent.finished(changed: true, failed: false));
      run.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('GONE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
