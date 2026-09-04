// #260 — the designed empty state: an icon, the view's line, and (only where
// an action exists) a hint.
//
// What these tests protect:
//
//   • the five views each get their OWN icon, so an empty Focus and an empty
//     Missed are not the same grey nothing;
//   • the "Add a task" hint appears ONLY where the user can act on it — a
//     concrete list, where the composer is right there. A smart view offering
//     "Add a task" would be pointing at a composer that cannot put a task in
//     the view the user is looking at;
//   • the icon's entrance plays ONCE, when the state is ENTERED. A view that
//     re-animates its icon every time the store re-emits (the 60s poll that
//     finds nothing, a keystroke elsewhere in the pane) is a page that twitches
//     at rest — the defect this suite exists to catch;
//   • at 2.0× system text the state SCROLLS instead of overflowing.

import 'dart:async';

import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/empty_state.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_motion.dart';
import 'detail_harness.dart' show FakeCommands, list;

const _phone = Size(400, 800);

/// A live [TaskListView] over an EMPTY backend, with two handles a test can
/// pull: [view] switches the rendered view id (what a nav tap does), and
/// [rebuilds] forces the pane to rebuild with its state unchanged.
class _EmptyHarness {
  _EmptyHarness(this.fake, this.view, this.rebuilds);

  final FakeCommands fake;
  final ValueNotifier<String> view;
  final ValueNotifier<int> rebuilds;

  void rebuild() => rebuilds.value++;
}

Future<_EmptyHarness> _pumpEmpty(
  WidgetTester tester, {
  String viewId = 'all',
  bool reducedMotion = false,
  double textScale = 1.0,
  Size size = _phone,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fake = FakeCommands(const []);
  addTearDown(fake.dispose);
  final view = ValueNotifier<String>(viewId);
  addTearDown(view.dispose);
  final rebuilds = ValueNotifier<int>(0);
  addTearDown(rebuilds.dispose);

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
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: rebuilds,
            builder: (context, _, _) => ValueListenableBuilder<String>(
              valueListenable: view,
              builder: (context, viewId, _) => TaskListView(
                viewId: viewId,
                selectedTaskId: null,
                onOpenTask: _noop,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // One frame to mount, one for the store's (immediate) first snapshot — the
  // frame the empty state is ENTERED on, and where the entrance begins.
  await tester.pump();
  await tester.pump();
  if (settle) await pumpMotion(tester, MotionDurations.medium);
  return _EmptyHarness(fake, view, rebuilds);
}

void _noop(String _) {}

/// The scale the icon is actually PAINTED at — read off the transform matrix
/// the [ScaleTransition] hands the render tree, not off the animation object.
/// (Column 0's x is the horizontal scale; `getMaxScaleOnAxis` would report the
/// untouched z axis instead.)
double _iconScale(WidgetTester tester, IconData icon) {
  final transform = tester.widget<Transform>(
    find
        .ancestor(of: find.byIcon(icon), matching: find.byType(Transform))
        .first,
  );
  return transform.transform.getColumn(0).x;
}

/// Whether the icon's entrance is running RIGHT NOW. Scoped to the icon on
/// purpose: the pane as a whole always has a frame callback pending, so a
/// tree-wide ticker count would say nothing about this widget.
bool _iconEntering(WidgetTester tester, IconData icon) => tester
    .widget<ScaleTransition>(
      find
          .ancestor(
            of: find.byIcon(icon),
            matching: find.byType(ScaleTransition),
          )
          .first,
    )
    .scale
    .isAnimating;

double _iconOpacity(WidgetTester tester, IconData icon) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byIcon(icon),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  group('the five empty states', () {
    // Each view gets the icon its own message is about — the pairing is the
    // point, so they are asserted together.
    const cases = <(String, String, IconData)>[
      ('focus', 'All clear for this week', Icons.check_circle_outline),
      ('upcoming', 'Nothing upcoming', Icons.event_available),
      ('missed', 'Nothing overdue', Icons.sentiment_satisfied_alt),
      ('unscheduled', 'Everything is scheduled', Icons.schedule),
      ('all', 'No tasks yet', Icons.inbox),
      ('L1', 'No tasks yet', Icons.inbox),
    ];

    for (final (viewId, message, icon) in cases) {
      testWidgets('$viewId renders its icon above its line', (tester) async {
        await _pumpEmpty(tester, viewId: viewId);
        expect(find.text(message), findsOneWidget);
        expect(find.byIcon(icon), findsOneWidget);
      });
    }

    testWidgets('a concrete list offers the hint; a smart view never does', (
      tester,
    ) async {
      final harness = await _pumpEmpty(tester, viewId: 'L1');
      expect(
        find.text('Add a task'),
        findsOneWidget,
        reason: 'the composer is right there and puts the task in THIS list',
      );

      for (final smart in ['focus', 'upcoming', 'missed', 'unscheduled']) {
        harness.view.value = smart;
        await tester.pump();
        await pumpMotion(tester, MotionDurations.medium);
        expect(
          find.text('Add a task'),
          findsNothing,
          reason:
              '$smart is a computed view — a task added here would not land '
              'in it, so an "Add a task" hint would be a lie',
        );
      }
    });
  });

  group('the icon enters once', () {
    testWidgets('it scales from 0.9 and fades in over Motion.medium', (
      tester,
    ) async {
      await _pumpEmpty(tester, settle: false);
      expect(
        _iconScale(tester, Icons.inbox),
        closeTo(0.9, 0.001),
        reason: 'the entrance starts small',
      );
      expect(_iconOpacity(tester, Icons.inbox), 0);

      await pumpMotion(tester, MotionDurations.medium, fraction: 0.5);
      final midScale = _iconScale(tester, Icons.inbox);
      expect(midScale, greaterThan(0.9));
      expect(midScale, lessThan(1.0));
      expect(_iconOpacity(tester, Icons.inbox), greaterThan(0));
      expect(_iconOpacity(tester, Icons.inbox), lessThan(1));

      await pumpMotion(tester, MotionDurations.medium);
      expect(_iconScale(tester, Icons.inbox), closeTo(1, 0.001));
      expect(_iconOpacity(tester, Icons.inbox), 1);
      expect(
        _iconEntering(tester, Icons.inbox),
        isFalse,
        reason: 'the entrance is over — nothing is still travelling',
      );
    });

    testWidgets('a rebuild with the same state does not replay it', (
      tester,
    ) async {
      final harness = await _pumpEmpty(tester);
      expect(_iconScale(tester, Icons.inbox), closeTo(1, 0.001));

      harness.rebuild();
      await tester.pump();
      expect(
        _iconScale(tester, Icons.inbox),
        closeTo(1, 0.001),
        reason: 'a rebuild is not an entrance',
      );
      expect(
        _iconEntering(tester, Icons.inbox),
        isFalse,
        reason: 'no animation was scheduled by the rebuild',
      );
      // …and it stays put across the frames a replay would have moved on.
      await pumpMotion(tester, MotionDurations.medium, fraction: 0.5);
      expect(_iconScale(tester, Icons.inbox), closeTo(1, 0.001));
      expect(_iconOpacity(tester, Icons.inbox), 1);
    });

    testWidgets('a store re-emission (the poll that finds nothing) does not '
        'replay it', (tester) async {
      final harness = await _pumpEmpty(tester);

      // Exactly what a 60s poll over an empty account does: the same empty set
      // arrives again. The page must not twitch.
      harness.fake.pushAll(const []);
      await tester.pump();
      expect(_iconScale(tester, Icons.inbox), closeTo(1, 0.001));
      expect(_iconEntering(tester, Icons.inbox), isFalse);
      await pumpMotion(tester, MotionDurations.medium, fraction: 0.5);
      expect(_iconScale(tester, Icons.inbox), closeTo(1, 0.001));
      expect(_iconOpacity(tester, Icons.inbox), 1);
    });

    testWidgets('switching to another empty view DOES play its entrance', (
      tester,
    ) async {
      final harness = await _pumpEmpty(tester, viewId: 'all');
      harness.view.value = 'focus';
      await tester.pump();
      expect(
        _iconScale(tester, Icons.check_circle_outline),
        closeTo(0.9, 0.001),
        reason: 'a different view is a different state — it is entered',
      );
      await pumpMotion(tester, MotionDurations.medium);
      expect(_iconScale(tester, Icons.check_circle_outline), closeTo(1, 0.001));
    });

    testWidgets('reduced motion: the icon is simply there, no travel', (
      tester,
    ) async {
      await _pumpEmpty(tester, reducedMotion: true, settle: false);
      expect(
        _iconScale(tester, Icons.inbox),
        closeTo(1, 0.001),
        reason: 'the end state, on the frame the state is entered',
      );
      expect(_iconOpacity(tester, Icons.inbox), 1);
      expect(
        _iconEntering(tester, Icons.inbox),
        isFalse,
        reason: 'nothing is travelling at all',
      );
    });
  });

  group('large text', () {
    for (final scale in [1.3, 2.0]) {
      testWidgets('${scale}x — the empty state does not overflow', (
        tester,
      ) async {
        await _pumpEmpty(tester, viewId: 'L1', textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.text('No tasks yet'), findsOneWidget);
        expect(find.text('Add a task'), findsOneWidget);
      });
    }

    testWidgets('2.0x on a short viewport — it scrolls instead of clipping', (
      tester,
    ) async {
      // A phone in landscape with the IME up: the shortest the pane ever gets.
      await _pumpEmpty(
        tester,
        viewId: 'L1',
        textScale: 2.0,
        size: const Size(640, 260),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsWidgets);
    });
  });

  group('the empty state is not a loading state', () {
    testWidgets('a store that has not answered yet shows no message at all', (
      tester,
    ) async {
      // A stream that never emits: the store is still opening. The pane must
      // not claim the account is empty — that line is an ANSWER, and it does
      // not have one yet.
      tester.view.physicalSize = _phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final silent = StreamController<List<StoredTask>>();
      addTearDown(silent.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(const Prefs()),
            commandsProvider.overrideWithValue(FakeCommands(const [])),
            allTasksProvider.overrideWith((ref) => silent.stream),
            listsProvider.overrideWith((ref) => const Stream.empty()),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: const Scaffold(
              body: TaskListView(
                viewId: 'all',
                selectedTaskId: null,
                onOpenTask: _noop,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('No tasks yet'), findsNothing);
      expect(find.byType(EmptyStateView), findsNothing);
    });
  });
}
