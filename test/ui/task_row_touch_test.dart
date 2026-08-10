// TaskWidget [touch] sub-suite + CheckboxTapTarget contract (MIGRATION-PLAN §5
// T8.1). Protects the coarse-pointer gesture path grafted onto the desktop
// TaskRow: a swipe right completes the task, a swipe left reveals the quick-date
// action strip (following the finger while peeking, latched open at rest), a
// long-press toggles selection with motion cancelling it, and a vertical drag
// still scrolls the list (gesture-vs-scroll slop). Every assertion is on what a
// gesture actually renders or the callback it fires — never "a method was
// called". Touch gestures are gated to a coarse pointer, so the mouse path
// (hover + right-click) is deliberately left untouched and is asserted here too.

import 'package:axiotask/src/model/dates.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bounded pump — never `pumpAndSettle` (the completion fade/scale animates and
/// a focused editor would blink forever); one frame past the gesture window is
/// enough to observe the outcome.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String title = 'buy milk',
    bool completed = false,
    String? due,
    bool wireSetDue = true,
    List<String>? opened,
    List<String>? toggled,
    List<String>? selected,
    List<DateMove>? moves,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            child: TaskRow(
              key: const Key('row'),
              title: title,
              completed: completed,
              due: due,
              onOpen: () => opened?.add(title),
              onToggle: () => toggled?.add(title),
              onRename: (_) {},
              onSelectToggle: selected == null
                  ? null
                  : () => selected.add(title),
              onSetDue: wireSetDue ? (m) => moves?.add(m) : null,
            ),
          ),
        ),
      ),
    );
  }

  Finder rowFinder() => find.byKey(const Key('row'));

  group('swipe right → complete', () {
    testWidgets('a swipe right completes the task (fires onToggle)', (
      tester,
    ) async {
      final toggled = <String>[];
      final opened = <String>[];
      await pumpRow(tester, toggled: toggled, opened: opened);

      await tester.drag(rowFinder(), const Offset(180, 0));
      await settle(tester);

      expect(toggled, ['buy milk'], reason: 'swipe right completes the task');
      expect(
        opened,
        isEmpty,
        reason: 'the swipe must not also open the detail',
      );
    });

    testWidgets('a short right drag below the threshold does NOT complete', (
      tester,
    ) async {
      final toggled = <String>[];
      await pumpRow(tester, toggled: toggled);

      // Under the 80px threshold — a lazy nudge, not a commit.
      await tester.drag(rowFinder(), const Offset(40, 0));
      await settle(tester);

      expect(
        toggled,
        isEmpty,
        reason: 'a sub-threshold drag is not a complete',
      );
    });
  });

  group('swipe left → quick-date strip', () {
    testWidgets('a swipe left reveals the quick-date action strip', (
      tester,
    ) async {
      final toggled = <String>[];
      final moves = <DateMove>[];
      await pumpRow(tester, toggled: toggled, moves: moves);

      // Hidden before any gesture (no hover on touch).
      expect(find.byKey(const Key('quick-date-today')), findsNothing);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);

      expect(find.byKey(const Key('quick-date-today')), findsOneWidget);
      expect(find.byKey(const Key('quick-date-tomorrow')), findsOneWidget);
      expect(toggled, isEmpty, reason: 'swipe left reveals, never completes');
    });

    testWidgets('a revealed strip button still fires its DateMove', (
      tester,
    ) async {
      final moves = <DateMove>[];
      await pumpRow(tester, moves: moves);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);
      await tester.tap(find.byKey(const Key('quick-date-tomorrow')));
      await settle(tester);

      expect(moves, [DateMove.tomorrow]);
    });

    testWidgets('a partial left swipe peeks the strip and the content follows '
        'the finger', (tester) async {
      await pumpRow(tester);

      final gesture = await tester.startGesture(tester.getCenter(rowFinder()));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();

      // The strip peeks…
      expect(find.byKey(const Key('quick-date-today')), findsOneWidget);
      // …and the row content has shifted left to follow the finger.
      final t = tester.widget<Transform>(
        find.byKey(const Key('swipe-content')),
      );
      expect(
        t.transform.getTranslation().x,
        lessThan(0),
        reason: 'the content tracks the finger during a left peek',
      );

      // Release below threshold → snaps closed, no lingering strip.
      await gesture.up();
      await settle(tester);
      expect(find.byKey(const Key('quick-date-today')), findsNothing);
    });

    testWidgets('tapping the row with the strip open closes it without opening '
        'the detail', (tester) async {
      final opened = <String>[];
      await pumpRow(tester, opened: opened);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);
      expect(find.byKey(const Key('quick-date-today')), findsOneWidget);

      await tester.tap(find.text('buy milk'));
      await settle(tester);

      expect(opened, isEmpty, reason: 'the tap closes the strip, not opens');
      expect(find.byKey(const Key('quick-date-today')), findsNothing);
    });

    testWidgets('with onSetDue unwired a left swipe reveals nothing and does '
        'not complete', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, wireSetDue: false, toggled: toggled);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);

      expect(find.byKey(const Key('quick-date-today')), findsNothing);
      expect(toggled, isEmpty);
    });
  });

  group('long-press → select', () {
    testWidgets('a long-press toggles selection', (tester) async {
      final selected = <String>[];
      await pumpRow(tester, selected: selected);

      await tester.longPress(rowFinder());
      await settle(tester);

      expect(selected, ['buy milk']);
    });

    testWidgets('motion before the long-press fires cancels the selection', (
      tester,
    ) async {
      final selected = <String>[];
      final toggled = <String>[];
      await pumpRow(tester, selected: selected, toggled: toggled);

      // Move a little (past slop, but short of the swipe threshold) then hold
      // well past the long-press delay before releasing.
      final gesture = await tester.startGesture(tester.getCenter(rowFinder()));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await settle(tester);

      expect(selected, isEmpty, reason: 'motion cancels the long-press select');
      expect(toggled, isEmpty, reason: 'a sub-threshold drag is no complete');
    });
  });

  group('gesture-vs-scroll slop', () {
    testWidgets('a vertical drag scrolls the list and never completes or '
        'reveals', (tester) async {
      final toggled = <String>[];
      final moves = <DateMove>[];
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 30,
              itemBuilder: (context, i) => TaskRow(
                key: ValueKey('row-$i'),
                title: 'task $i',
                completed: false,
                onOpen: () {},
                onToggle: () => toggled.add('task $i'),
                onRename: (_) {},
                onSetDue: (m) => moves.add(m),
              ),
            ),
          ),
        ),
      );

      expect(controller.offset, 0);
      await tester.drag(
        find.byKey(const ValueKey('row-0')),
        const Offset(0, -300),
      );
      await settle(tester);

      expect(
        controller.offset,
        greaterThan(0),
        reason: 'a vertical drag scrolls',
      );
      expect(toggled, isEmpty, reason: 'a vertical drag is not a complete');
      expect(moves, isEmpty);
      expect(find.byKey(const Key('quick-date-today')), findsNothing);
    });
  });

  group('pointer-kind gating (desktop untouched)', () {
    testWidgets('a mouse horizontal drag does NOT swipe (mouse uses hover)', (
      tester,
    ) async {
      final toggled = <String>[];
      final opened = <String>[];
      await pumpRow(tester, toggled: toggled, opened: opened);

      await tester.drag(
        rowFinder(),
        const Offset(180, 0),
        kind: PointerDeviceKind.mouse,
      );
      await settle(tester);

      expect(toggled, isEmpty, reason: 'mouse drag is not a touch swipe');
      expect(opened, isEmpty);
    });
  });

  group('CheckboxTapTarget contract + 48dp audit', () {
    testWidgets('the checkbox hit target is at least 48x48', (tester) async {
      await pumpRow(tester);
      final size = tester.getSize(find.byKey(const Key('row-checkbox-target')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets(
      'the swipe-revealed action buttons meet the 48dp touch target',
      (tester) async {
        await pumpRow(tester);
        await tester.drag(rowFinder(), const Offset(-180, 0));
        await settle(tester);

        final btn = find.byKey(const Key('quick-date-today'));
        expect(btn, findsOneWidget);
        final box = tester.renderObject<RenderBox>(btn);
        expect(box.size.width, greaterThanOrEqualTo(48));
        expect(box.size.height, greaterThanOrEqualTo(48));
      },
    );
  });
}
