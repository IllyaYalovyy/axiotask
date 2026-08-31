// The motion foundation (#250): one duration scale, one reduced-motion rule,
// and the two animations that already shipped reading BOTH through it.
//
// Two failures this suite prevents:
//
//   1. the published scale drifting. Ten motion tasks are queued behind this
//      file; if `medium` quietly becomes 250ms halfway through them, half the
//      UI moves at one speed and half at another, and nothing fails;
//   2. a consumer keeping its own literal duration and so ignoring "remove
//      animations" (Android) / reduced motion (desktop). That is the failure
//      the FAB and the nav-bar pill actually had: the app bar beside them
//      already snapped with motion off (#244) while they went on travelling.
//
// Every assertion below is about the rendered frame — whether the FAB is on
// screen, how wide the pill is DRAWN — not about which duration object a
// widget was handed.

import 'package:axiotask/src/ui/motion.dart';
import 'package:axiotask/src/ui/new_task_fab.dart';
import 'package:axiotask/src/ui/shell_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_motion.dart';

void main() {
  group('the scale', () {
    Future<Motion> motionAt(
      WidgetTester tester, {
      required bool disableAnimations,
    }) async {
      late Motion motion;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Builder(
            builder: (context) {
              motion = Motion.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return motion;
    }

    testWidgets('is the published one — the values every animation shares', (
      tester,
    ) async {
      final motion = await motionAt(tester, disableAnimations: false);

      expect(motion.short, const Duration(milliseconds: 100));
      expect(motion.medium, const Duration(milliseconds: 200));
      expect(motion.long, const Duration(milliseconds: 300));
      expect(motion.emphasized, const Duration(milliseconds: 400));
      expect(
        motion.resolve(MotionDurations.fabTransition),
        const Duration(milliseconds: 120),
        reason: 'a bespoke token still comes back at its own value',
      );
    });

    testWidgets('collapses to nothing when the platform says "remove '
        'animations"', (tester) async {
      final motion = await motionAt(tester, disableAnimations: true);

      expect(motion.short, Duration.zero);
      expect(motion.medium, Duration.zero);
      expect(motion.long, Duration.zero);
      expect(motion.emphasized, Duration.zero);
      for (final token in const [
        MotionDurations.short,
        MotionDurations.medium,
        MotionDurations.long,
        MotionDurations.emphasized,
        MotionDurations.fabTransition,
        MotionDurations.navSelection,
        MotionDurations.completionSettle,
        MotionDurations.completionCollapse,
      ]) {
        expect(
          motion.resolve(token),
          Duration.zero,
          reason: 'no token survives reduced motion',
        );
      }
    });
  });

  group('the FAB', () {
    Future<void> pumpFab(
      WidgetTester tester, {
      required bool visible,
      required bool disableAnimations,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            floatingActionButton: NewTaskFab(
              visible: visible,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    final fab = find.byType(FloatingActionButton);

    testWidgets('travels away over its transition and is gone at the end', (
      tester,
    ) async {
      await pumpFab(tester, visible: true, disableAnimations: false);
      await pumpMotion(tester, MotionDurations.fabTransition);
      expect(fab, findsOneWidget);

      await pumpFab(tester, visible: false, disableAnimations: false);
      await pumpMotion(tester, MotionDurations.fabTransition, fraction: 0.5);
      expect(fab, findsOneWidget, reason: 'half way out it is still on screen');
      expect(
        tester.widget<Opacity>(find.byType(Opacity).first).opacity,
        lessThan(1),
        reason: 'and visibly fading while it goes',
      );

      await pumpMotion(tester, MotionDurations.fabTransition);
      expect(fab, findsNothing);
    });

    testWidgets('with animations off it is gone on the frame it is hidden — '
        'the chrome beside it already snaps', (tester) async {
      await pumpFab(tester, visible: true, disableAnimations: true);
      await pumpMotion(tester, MotionDurations.fabTransition);
      expect(fab, findsOneWidget);

      // No settling pump: pumpWidget renders the frame that hides it, and
      // that frame is the one where it must already be gone.
      await pumpFab(tester, visible: false, disableAnimations: true);
      expect(
        fab,
        findsNothing,
        reason: 'with motion off the FAB stops travelling, not leaving',
      );
    });
  });

  group('the nav-bar pill', () {
    const destinations = [
      ShellDestination(
        icon: Icons.star_border,
        selectedIcon: Icons.star,
        label: 'One',
      ),
      ShellDestination(
        icon: Icons.circle_outlined,
        selectedIcon: Icons.circle,
        label: 'Two',
      ),
    ];

    Future<void> pumpBar(
      WidgetTester tester, {
      required int? selectedIndex,
      required bool disableAnimations,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            bottomNavigationBar: ShellNavBar(
              destinations: destinations,
              selectedIndex: selectedIndex,
              onDestinationSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    /// How wide the destination's indicator pill is actually DRAWN: the
    /// framework scales it in the x direction only, from nothing to full.
    double pillWidthFactor(WidgetTester tester, int index) {
      final scale = tester.widget<Transform>(
        find
            .descendant(
              of: find.byType(NavigationIndicator).at(index),
              matching: find.byType(Transform),
            )
            .first,
      );
      return scale.transform.entry(0, 0);
    }

    testWidgets('grows into place over the selection transition', (
      tester,
    ) async {
      await pumpBar(tester, selectedIndex: null, disableAnimations: false);
      await pumpMotion(tester, MotionDurations.navSelection);
      expect(pillWidthFactor(tester, 0), 0);

      await pumpBar(tester, selectedIndex: 0, disableAnimations: false);
      expect(
        pillWidthFactor(tester, 0),
        lessThan(1),
        reason: 'on the first frame the pill has only started growing',
      );

      await pumpMotion(tester, MotionDurations.navSelection);
      expect(pillWidthFactor(tester, 0), 1);
    });

    testWidgets('with animations off it is full size in a single frame', (
      tester,
    ) async {
      await pumpBar(tester, selectedIndex: null, disableAnimations: true);
      await pumpMotion(tester, MotionDurations.navSelection);
      expect(pillWidthFactor(tester, 0), 0);

      await pumpBar(tester, selectedIndex: 0, disableAnimations: true);
      expect(
        pillWidthFactor(tester, 0),
        1,
        reason: 'with motion off the pill arrives rather than grows',
      );
    });
  });
}
