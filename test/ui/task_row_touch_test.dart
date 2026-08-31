// TaskWidget [touch] sub-suite + CheckboxTapTarget contract (MIGRATION-PLAN §5
// T8.1). Protects the coarse-pointer gesture path grafted onto the desktop
// TaskRow: a swipe right completes the task, a swipe left opens the ONE shared
// quick-date sheet for the row (#243 — the in-row strip it used to reveal is
// retired, D-1), a long-press toggles selection with motion cancelling it, and
// a vertical drag still scrolls the list (gesture-vs-scroll slop). Every
// assertion is on what a gesture actually renders or the callback it fires —
// never "a method was called". Touch gestures are gated to a coarse pointer, so
// the mouse path (right-click) is deliberately left untouched and asserted too.

import 'package:axiotask/src/model/dates.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
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
    List<String>? picked,
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
              // The date menu needs BOTH a move sink and a calendar route —
              // "Pick a date…" is one of its six frozen options.
              onPickDate: wireSetDue ? () => picked?.add(title) : null,
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

  group('swipe left → the shared quick-date sheet (#243)', () {
    testWidgets('a swipe left opens the frozen option set for the row', (
      tester,
    ) async {
      final toggled = <String>[];
      await pumpRow(tester, toggled: toggled);

      // Nothing is on screen before the gesture (no hover on touch, and the
      // in-row strip is retired).
      expect(find.byKey(quickDateKey('today')), findsNothing);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);

      for (final label in const [
        'Today',
        'Tomorrow',
        'Next week',
        'Next month',
        'Pick a date…',
        'Clear',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(toggled, isEmpty, reason: 'swipe left never completes');
    });

    testWidgets('choosing an option from the swiped-open sheet fires its '
        'DateMove and closes the sheet', (tester) async {
      final moves = <DateMove>[];
      await pumpRow(tester, moves: moves);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);
      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await settle(tester);

      expect(moves, [DateMove.tomorrow]);
      expect(
        find.byKey(quickDateKey('tomorrow')),
        findsNothing,
        reason: 'the sheet dismisses itself once the date is set',
      );
    });

    testWidgets('"Pick a date…" from the swiped-open sheet routes to the '
        'calendar', (tester) async {
      final picked = <String>[];
      final moves = <DateMove>[];
      await pumpRow(tester, moves: moves, picked: picked);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);
      await tester.tap(find.byKey(quickDateKey('pick')));
      await settle(tester);

      expect(picked, ['buy milk']);
      expect(moves, isEmpty, reason: 'a calendar route is not a move');
    });

    testWidgets('a partial left swipe drags the content with the finger and '
        'snaps back below the threshold', (tester) async {
      await pumpRow(tester);

      final gesture = await tester.startGesture(tester.getCenter(rowFinder()));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();

      // The row content follows the finger — the only feedback that the
      // shortcut is live before it fires.
      final t = tester.widget<Transform>(
        find.byKey(const Key('swipe-content')),
      );
      expect(
        t.transform.getTranslation().x,
        lessThan(0),
        reason: 'the content tracks the finger during a left drag',
      );

      // Release below threshold → the row settles square and nothing opens.
      await gesture.up();
      await settle(tester);
      expect(find.byKey(quickDateKey('today')), findsNothing);
      final after = tester.widget<Transform>(
        find.byKey(const Key('swipe-content')),
      );
      expect(after.transform.getTranslation().x, 0);
    });

    testWidgets('with the date menu unwired a left swipe reveals nothing and '
        'does not complete', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, wireSetDue: false, toggled: toggled);

      await tester.drag(rowFinder(), const Offset(-180, 0));
      await settle(tester);

      expect(find.byKey(quickDateKey('today')), findsNothing);
      expect(toggled, isEmpty);
    });
  });

  group('swipe edge gating (F15 #193)', () {
    testWidgets('a right-swipe starting in the left drawer-edge gutter is '
        'ignored — no complete', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, toggled: toggled);

      // Start the drag at the far left edge (inside the 20px drawer-edge
      // gutter) and swipe right past the complete threshold. The Scaffold
      // drawer / system back gesture owns that gutter, so the row must not
      // treat it as a complete.
      final rect = tester.getRect(rowFinder());
      await tester.dragFrom(
        Offset(rect.left + 4, rect.center.dy),
        const Offset(200, 0),
      );
      await settle(tester);

      expect(
        toggled,
        isEmpty,
        reason: 'an edge-started swipe is not a row complete',
      );
    });

    testWidgets('a center-started right-swipe still completes', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, toggled: toggled);

      final rect = tester.getRect(rowFinder());
      await tester.dragFrom(rect.center, const Offset(200, 0));
      await settle(tester);

      expect(toggled, [
        'buy milk',
      ], reason: 'a drag well inside the row still completes');
    });

    testWidgets(
      'a swipe starting in the right system-gesture inset is ignored',
      (tester) async {
        final toggled = <String>[];
        final moves = <DateMove>[];
        // A full-width row under a MediaQuery that reserves a right-edge
        // system-gesture inset (as gesture-nav Android does).
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  systemGestureInsets: const EdgeInsets.only(right: 60),
                ),
                child: Scaffold(
                  body: TaskRow(
                    key: const Key('row'),
                    title: 'buy milk',
                    completed: false,
                    onOpen: () {},
                    onToggle: () => toggled.add('buy milk'),
                    onRename: (_) {},
                    onSetDue: (m) => moves.add(m),
                  ),
                ),
              ),
            ),
          ),
        );

        // Start the drag inside the right inset and swipe left; the
        // system back gesture owns that gutter, so the strip must not reveal.
        final rect = tester.getRect(rowFinder());
        await tester.dragFrom(
          Offset(rect.right - 5, rect.center.dy),
          const Offset(-200, 0),
        );
        await settle(tester);

        expect(
          find.byKey(quickDateKey('today')),
          findsNothing,
          reason: 'a swipe from the system-gesture inset is ignored',
        );
        expect(toggled, isEmpty);
        expect(moves, isEmpty);
      },
    );
  });

  group('completed-row swipe-right no-op (F15 #193)', () {
    testWidgets('swipe right on an already-completed row does NOT un-complete '
        'it', (tester) async {
      final toggled = <String>[];
      await pumpRow(tester, completed: true, toggled: toggled);

      final rect = tester.getRect(rowFinder());
      await tester.dragFrom(rect.center, const Offset(200, 0));
      await settle(tester);

      expect(
        toggled,
        isEmpty,
        reason: 'swipe-right must not toggle a completed row back to open',
      );
    });

    testWidgets('the checkbox is still the explicit un-complete affordance', (
      tester,
    ) async {
      final toggled = <String>[];
      await pumpRow(tester, completed: true, toggled: toggled);

      await tester.tap(find.byKey(const Key('row-checkbox-target')));
      await settle(tester);

      expect(toggled, [
        'buy milk',
      ], reason: 'tapping the checkbox remains the way to re-open a task');
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
      expect(find.byKey(quickDateKey('today')), findsNothing);
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
      'every option in the swipe-opened sheet meets the 48dp touch target',
      (tester) async {
        await pumpRow(tester);
        await tester.drag(rowFinder(), const Offset(-180, 0));
        await settle(tester);

        for (final id in const [
          'today',
          'tomorrow',
          'week',
          'month',
          'pick',
          'clear',
        ]) {
          final option = find.byKey(quickDateKey(id));
          expect(option, findsOneWidget);
          final box = tester.renderObject<RenderBox>(option);
          expect(box.size.height, greaterThanOrEqualTo(48), reason: id);
        }
      },
    );
  });
}
