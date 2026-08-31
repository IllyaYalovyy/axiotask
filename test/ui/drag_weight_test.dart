// #256 — the weight a dragged row carries.
//
// The failure this suite prevents is the one the issue opens with: a drag with
// no weight. The bare reorderable lifts a row by swapping in a flat canvas
// rectangle, so the row the finger is holding looks exactly like the rows it is
// travelling over — "it feels like moving a spreadsheet cell". Nothing says the
// row DETACHED, nothing says it LANDED, and a drag that ends where it started
// is indistinguishable from one that moved.
//
// So this is asserted on the frames a user actually sees:
//
//   lift    the proxy takes elevation, scale and a tonal surface over
//           [Motion.short] — a motion, not a jump, and not nothing;
//   settle  the drop puts all three back over [Motion.medium], and never
//           outlives the proxy it is painted on;
//   landed  a drop at a NEW index leaves the #252 commit flash on the row, and
//           a drop where it started leaves NOTHING (no write, no wash).
//
// And the three ends a drag has besides the happy one: reduced motion (the
// weight is simply there, in one frame), a gesture the SYSTEM cancels out from
// under the drag, and a list taller than the screen, where a target below the
// fold is only reachable if the edge auto-scroll is on.
//
// The haptic ends of the same gesture (#257) are asserted in haptics_test.dart;
// the index arithmetic (#202) in drag_reorder_test.dart. Neither is restated.
//
// Durations and magnitudes are written out as literals on purpose — a test that
// reads the same constant as the code cannot catch the constant being wrong.

import 'package:axiotask/src/ui/commit_flash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  // The lifted surface and the transform that scales it, both inside the drag
  // proxy the reorderable mounts in the overlay.
  final surface = find.byKey(const Key('drag-lift-surface'));
  final scaler = find.byKey(const Key('drag-lift-scale'));

  double elevation(WidgetTester tester) =>
      tester.widget<Material>(surface).elevation;
  Color surfaceColor(WidgetTester tester) =>
      tester.widget<Material>(surface).color!;
  double scale(WidgetTester tester) =>
      tester.widget<Transform>(scaler).transform.getMaxScaleOnAxis();

  /// Press row [id]'s drag handle and move [by] — past kTouchSlop, which is
  /// what the immediate multi-drag recognizer waits for before it claims the
  /// pointer — stopping on the frame the proxy FIRST paints, so the caller owns
  /// every frame of the lift that follows.
  Future<TestGesture> lift(
    WidgetTester tester,
    String id, {
    double by = 24,
  }) async {
    final handle = find.byKey(Key('drag-handle-$id'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, by));
    await tester.pump();
    return gesture;
  }

  /// The opacity of the whole-row wash on row [id], or -1 when the row renders
  /// no wash site at all.
  double wash(WidgetTester tester, String id) {
    final f = find.descendant(
      of: find.byKey(ValueKey('reorder-$id')),
      matching: find.byKey(const Key('commit-flash-row')),
    );
    if (f.evaluate().isEmpty) return -1;
    return tester.widget<CommitWash>(f).color.a;
  }

  /// Let the drop animation finish, the reorder command run and the landed row
  /// come back into the list, WITHOUT advancing the clock past the flash's own
  /// first frame.
  Future<void> land(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 250));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  group('the lift', () {
    testWidgets('raises elevation, scale and tint over Motion.short', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      final resting = Theme.of(
        tester.element(find.byType(ReorderableListView)),
      ).colorScheme.surface;

      final gesture = await lift(tester, 'A');
      addTearDown(() async => gesture.up());

      // The frame the proxy first paints: the row is still exactly the row it
      // was in the list. A lift that is already finished here is a jump.
      expect(elevation(tester), 0, reason: 'flat on the frame it detaches');
      expect(scale(tester), 1);
      expect(surfaceColor(tester), resting);

      await tester.pump(); // the first tick: still at the start
      await tester.pump(const Duration(milliseconds: 50));
      expect(elevation(tester), greaterThan(0));
      expect(elevation(tester), lessThan(6), reason: 'halfway, still rising');

      await tester.pump(const Duration(milliseconds: 50));
      expect(elevation(tester), 6, reason: 'M3 level 3, the dragged state');
      expect(scale(tester), closeTo(1.02, 0.0001));
      expect(
        surfaceColor(tester),
        isNot(resting),
        reason: 'the lifted surface takes the tint its elevation implies',
      );
    });

    testWidgets('is already landed on the first frame under reduced motion', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        disableAnimations: true,
      );
      final gesture = await lift(tester, 'A');
      addTearDown(() async => gesture.up());

      // No travel to watch — the row simply has weight. It must still HAVE it:
      // reduced motion removes the animation, not the affordance.
      expect(elevation(tester), 6);
      expect(scale(tester), closeTo(1.02, 0.0001));
    });
  });

  group('the drop', () {
    testWidgets('settles elevation and scale back over Motion.medium', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );
      final gesture = await lift(tester, 'A');
      await tester.pump(const Duration(milliseconds: 300));
      expect(elevation(tester), 6, reason: 'lifted before the release');

      await gesture.up();
      await tester.pump(); // the settle's first tick
      expect(elevation(tester), 6, reason: 'the weight comes off over time');

      await tester.pump(const Duration(milliseconds: 100));
      expect(elevation(tester), lessThan(6));
      expect(elevation(tester), greaterThan(0));

      await tester.pump(const Duration(milliseconds: 100));
      expect(elevation(tester), 0, reason: 'flat again, back in the list');
      expect(scale(tester), 1);

      await tester.pumpAndSettle();
    });
  });

  testWidgets('a flick released mid-lift still lands flat', (tester) async {
    // The proxy is the framework's, and it tears it down when its OWN drop
    // animation ends — which, for a row released before it had finished
    // lifting, is sooner than a full settle. The weight has to be off by then:
    // a surface that blinks out of existence while still elevated reads as the
    // row being deleted, not dropped.
    await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
    );
    final gesture = await lift(tester, 'A');
    await tester.pump(); // the lift's first tick
    await tester.pump(const Duration(milliseconds: 50));
    expect(elevation(tester), greaterThan(0), reason: 'released mid-lift');

    await gesture.up();
    var last = -1.0;
    for (var i = 0; i < 60 && surface.evaluate().isNotEmpty; i++) {
      last = elevation(tester);
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(surface, findsNothing, reason: 'the drop finished');
    expect(last, 0, reason: 'flat on the last frame the proxy painted');
    await tester.pumpAndSettle();
  });

  group('the landing', () {
    testWidgets('a drop at a NEW index flashes the row that moved', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples', position: '1'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
      );
      final rowHeight = tester.getSize(find.byKey(const ValueKey('A'))).height;
      // One visible slot down, stepped: the reorderable re-measures the gap on
      // every update, so a drag arrives at its target the way a finger does.
      final gesture = await lift(tester, 'A', by: rowHeight * 0.6);
      await gesture.moveBy(Offset(0, rowHeight * 0.6));
      await tester.pump();
      await gesture.up();
      await land(tester);

      expect(fake.reordered, ['A:B'], reason: 'the move actually happened');
      expect(
        wash(tester, 'A'),
        closeTo(0.4, 0.01),
        reason: 'the landed row says "it stuck"',
      );

      await tester.pump(const Duration(milliseconds: 400));
      expect(wash(tester, 'A'), 0, reason: 'one flash, then gone');
      await tester.pumpAndSettle();
    });

    testWidgets('a drop where it started writes nothing and flashes nothing', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples', position: '1'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
      );
      final gesture = await lift(tester, 'A');
      // Back to where it came from: a cancelled drag, which is the ONLY way to
      // abandon one on a touch device.
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();
      await gesture.up();
      await land(tester);

      expect(fake.reordered, isEmpty, reason: 'nothing moved');
      expect(wash(tester, 'A'), 0, reason: 'and nothing landed');
      await tester.pumpAndSettle();
    });
  });

  testWidgets('a drag the system CANCELS tears down clean and writes nothing', (
    tester,
  ) async {
    // Android sends a pointer cancel whenever the system takes the gesture —
    // the notification shade coming down, an incoming call, a back gesture
    // claiming the pointer. The reorderable answers that by disposing its proxy
    // animation WITHOUT reversing it, so the lift is torn down while it is
    // still listening to it, and nothing is left to run the settle on.
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'apples', position: '1'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
    );
    final gesture = await lift(tester, 'A', by: 40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(elevation(tester), 6, reason: 'lifted when the system stepped in');

    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(surface, findsNothing, reason: 'the proxy went with the gesture');
    expect(find.byKey(const ValueKey('A')), findsOneWidget);
    expect(fake.reordered, isEmpty, reason: 'a cancelled drag moves nothing');
  });

  testWidgets('a drag held at the bottom edge auto-scrolls the list', (
    tester,
  ) async {
    // Without this a reorder in a list taller than the screen is impossible:
    // the finger reaches the bottom edge and the target simply is not reachable.
    await pumpList(
      tester,
      initial: [
        for (var i = 0; i < 40; i++) row('T$i', 'task $i', position: '$i'),
      ],
      lists: oneList,
      size: const Size(800, 700),
    );
    final scrollable = find.descendant(
      of: find.byType(ReorderableListView),
      matching: find.byType(Scrollable),
    );
    double offset() =>
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset(), 0);

    final gesture = await lift(tester, 'T0');
    // Hold the finger just above the bottom edge of the viewport.
    await gesture.moveTo(const Offset(400, 690));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(offset(), greaterThan(0), reason: 'the list came to the finger');

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
