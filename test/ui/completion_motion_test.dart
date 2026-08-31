// CompletionMotion (#241) — the ONE completion sequence every completion path
// plays: the title takes its strikethrough as a left-to-right sweep, the row
// settles (fade + slight shrink), and — when the show-completed filter hides it
// — the row's height collapses to zero so the rows below slide up instead of
// snapping. Undo re-expands the row into place. `disableAnimations` reaches the
// same end state in a single frame.
//
// These are frame-by-frame widget tests: they pump fixed slices of the sequence
// and assert the GEOMETRY on screen at that instant (the swept strike's painted
// width, the offset of the row below, whether the row is rendered at all) — not
// that a controller exists or a method fired. The store write is asserted to
// have already landed in the fake while the motion is still mid-flight: the
// sequence is presentation only and never gates the data.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeBackend, list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// The checkbox of the row titled [title].
  Finder checkboxOf(String title) => find.descendant(
    of: find.ancestor(
      of: find.text(title),
      matching: find.byKey(const Key('swipe-content')),
    ),
    matching: find.byType(Checkbox),
  );

  /// Tap [title]'s checkbox and let the store write land — WITHOUT pumping any
  /// of the motion, so the caller owns every following frame.
  Future<void> tick(WidgetTester tester, String title) async {
    await tester.tap(checkboxOf(title));
    await tester.pump();
  }

  bool isDone(FakeBackend fake, String id) =>
      fake.tasks.firstWhere((t) => t.task.id == id).task.status ==
      TaskStatus.completed;

  group('the strike sweeps in (never snaps)', () {
    testWidgets('mid-sweep the title is struck over only part of its width', (
      tester,
    ) async {
      // Show-completed ON: the row stays, so this test sees the settle alone.
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        showCompleted: true,
        platform: TargetPlatform.linux,
      );
      await tick(tester, 'apples');
      // The data write is NOT waiting on the motion.
      expect(isDone(fake, 'A'), isTrue);

      await tester.pump(const Duration(milliseconds: 40));
      final strike = find.byKey(const Key('title-strike'));
      expect(strike, findsOneWidget, reason: 'the strike is still sweeping');
      final early = tester.getSize(strike).width;
      final titleWidth = tester.getSize(find.text('apples').first).width;
      expect(early, greaterThan(0.0));
      expect(
        early,
        lessThan(titleWidth),
        reason: 'only part of the title is struck this early',
      );
      // The unstruck base is still visible under the swept-in struck copy.
      final decorations = tester
          .widgetList<Text>(find.text('apples'))
          .map((t) => t.style?.decoration)
          .toList();
      expect(decorations, contains(null));
      expect(decorations, contains(TextDecoration.lineThrough));

      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getSize(strike).width,
        greaterThan(early),
        reason: 'the strike keeps sweeping across the title',
      );

      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const Key('title-strike')),
        findsNothing,
        reason: 'at rest the title is a single fully struck line again',
      );
      final settled = tester.widget<Text>(find.text('apples'));
      expect(settled.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('the row fades as it settles, not in one step', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        showCompleted: true,
        platform: TargetPlatform.linux,
      );
      await tick(tester, 'apples');
      await tester.pump(const Duration(milliseconds: 40));
      final fade = tester.widget<FadeTransition>(
        find.byKey(const Key('row-completion-fade')),
      );
      expect(
        fade.opacity.value,
        inExclusiveRange(0.5, 1.0),
        reason: 'the dim is part of the sequence, not an instant restyle',
      );
    });
  });

  testWidgets(
    'a long title at 1.3x text scale sweeps without reflowing the row',
    (tester) async {
      const long =
          'pick up the dry cleaning and the parcel from the depot before six';
      await pumpList(
        tester,
        initial: [row('A', long)],
        lists: oneList,
        showCompleted: true,
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        textScale: 1.3,
      );
      final title = find.text(long);
      final restHeight = tester.getSize(find.byType(TaskRow)).height;
      final restWidth = tester.getSize(title.first).width;

      await tick(tester, long);
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getSize(find.byType(TaskRow)).height,
        restHeight,
        reason: 'the sweep is paint, not layout — the row must not reflow',
      );
      final strike = tester.getSize(find.byKey(const Key('title-strike')));
      expect(strike.width, greaterThan(0.0));
      expect(
        strike.width,
        lessThanOrEqualTo(restWidth),
        reason: 'the strike never runs past the (ellipsised) title itself',
      );
    },
  );

  group('collapse when the filter hides the row', () {
    testWidgets('the row height animates to zero and the rows below slide up', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final before = tester.getTopLeft(find.text('bread')).dy;
      await tick(tester, 'apples');
      expect(
        isDone(fake, 'A'),
        isTrue,
        reason: 'the write lands on the tick, before any motion',
      );

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.text('apples'),
        findsOneWidget,
        reason: 'the row is still on screen, settled and about to collapse',
      );
      await tester.pump(const Duration(milliseconds: 90));
      final mid = tester.getTopLeft(find.text('bread')).dy;
      expect(
        mid,
        lessThan(before),
        reason: 'the row below has started sliding up',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('apples'), findsNothing);
      final after = tester.getTopLeft(find.text('bread')).dy;
      expect(
        mid,
        greaterThan(after),
        reason: 'the slide is progressive — mid-collapse is between the ends',
      );
      expect(find.text('cheese'), findsOneWidget);
    });

    testWidgets('a row that is folding away no longer takes taps', (
      tester,
    ) async {
      final opened = <String>[];
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        opened: opened,
        platform: TargetPlatform.linux,
      );
      await tick(tester, 'apples');
      await tester.pump(const Duration(milliseconds: 150));
      // It is still on screen — and it is a shrinking target sliding under the
      // finger, so nothing on it may fire.
      await tester.tap(find.text('apples'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
      expect(opened, isEmpty, reason: 'a leaving row does not open its detail');
      expect(
        isDone(fake, 'A'),
        isTrue,
        reason: 'and nothing re-opened the task either',
      );
      expect(find.text('apples'), findsNothing);
    });

    testWidgets('an alphabetically sorted list collapses the same way', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        sortPerView: const {'all': 'alpha'},
        platform: TargetPlatform.linux,
      );
      final before = tester.getTopLeft(find.text('bread')).dy;
      await tick(tester, 'apples');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('apples'), findsOneWidget);
      expect(tester.getTopLeft(find.text('bread')).dy, lessThan(before));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('apples'), findsNothing);
    });

    testWidgets('Undo re-expands the row into place instead of popping it in', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final full = tester.getTopLeft(find.text('bread')).dy;
      await tick(tester, 'apples');
      await settleList(tester);
      final collapsed = tester.getTopLeft(find.text('bread')).dy;
      expect(collapsed, lessThan(full));

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final growing = tester.getTopLeft(find.text('bread')).dy;
      expect(
        growing,
        greaterThan(collapsed),
        reason: 'the restored row is re-expanding',
      );
      expect(
        growing,
        lessThan(full),
        reason: 'mid-expansion it is not yet at full height (no pop-in)',
      );

      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('apples'), findsOneWidget);
      expect(tester.getTopLeft(find.text('bread')).dy, full);
    });
  });

  group('every completion path runs the same sequence', () {
    testWidgets('a touch swipe right collapses the row like the checkbox', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      final before = tester.getTopLeft(find.text('bread')).dy;
      await tester.drag(find.text('apples'), const Offset(180, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        find.text('apples'),
        findsOneWidget,
        reason: 'the swiped row collapses through the same sequence',
      );
      expect(tester.getTopLeft(find.text('bread')).dy, lessThan(before));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('apples'), findsNothing);
    });

    testWidgets('bulk Complete collapses every selected row', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final before = tester.getTopLeft(find.text('cheese')).dy;
      for (final title in ['apples', 'bread']) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(find.text(title));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('bulk-complete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(
        find.text('apples'),
        findsOneWidget,
        reason: 'both bulk-completed rows collapse, they do not vanish',
      );
      expect(find.text('bread'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('apples'), findsNothing);
      expect(find.text('bread'), findsNothing);
      expect(tester.getTopLeft(find.text('cheese')).dy, lessThan(before));
    });
  });

  group('reduced motion', () {
    testWidgets('disableAnimations reaches the end state in a single frame', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        platform: TargetPlatform.linux,
        disableAnimations: true,
      );
      final before = tester.getTopLeft(find.text('bread')).dy;
      await tick(tester, 'apples');
      // One more frame to paint the store change — and nothing beyond it.
      await tester.pump();
      expect(find.text('apples'), findsNothing);
      expect(
        tester.getTopLeft(find.text('bread')).dy,
        lessThan(before),
        reason: 'the list closed the gap immediately, with no collapse',
      );
      // Drain the ghost bookkeeping so no frame is left owing.
      await settleList(tester);
      expect(find.text('apples'), findsNothing);
    });

    testWidgets('disableAnimations strikes the title in a single frame', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        showCompleted: true,
        platform: TargetPlatform.linux,
        disableAnimations: true,
      );
      await tick(tester, 'apples');
      await tester.pump();
      expect(
        find.byKey(const Key('title-strike')),
        findsNothing,
        reason: 'no sweep — the strike is simply there',
      );
      expect(
        tester.widget<Text>(find.text('apples')).style?.decoration,
        TextDecoration.lineThrough,
      );
      expect(
        tester
            .widget<FadeTransition>(
              find.byKey(const Key('row-completion-fade')),
            )
            .opacity
            .value,
        0.5,
      );
    });
  });
}
