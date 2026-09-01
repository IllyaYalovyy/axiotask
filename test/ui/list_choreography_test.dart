// #251 — the list choreography: what a row DOES when it joins the list and when
// it leaves it. Before this, every list change was a reflow: a created task
// popped in, a deleted one vanished between frames, a task rescheduled out of
// the current smart view was simply gone, Undo re-inserted with no trace, and a
// sync pull rewrote the list silently. The user's edit produced a new layout,
// not feedback.
//
// The rules under test, ratified with "do not overdo it. It should not be too
// much":
//
//   enter  fade-in + height-grow over 300ms (Motion.long), ease-out
//   leave  height-collapse + fade over 300ms, ease-in
//   cap    at most 8 rows move on ONE change; every other row snaps
//   stagger 40ms between one animating row and the next
//   reduced motion → the end state in the same frame
//
// These are frame-by-frame tests: they pump fixed slices and assert the row's
// RENDERED HEIGHT at that instant — the geometry a user sees — never that a
// controller exists or a callback fired. The durations are written out as
// literals on purpose: a test that reads the same constant as the code cannot
// catch the constant being wrong.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

/// The gap between one animating row and the next.
const _stagger = Duration(milliseconds: 40);

/// At most this many rows move on one change.
const _cap = 8;

/// The whole window a single change may occupy: the motion plus the stagger the
/// last row the cap allows waits through.
const _window = Duration(milliseconds: 300 + 40 * 8);

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// The height of the list slot holding task [id] — 0 when the slot renders
  /// nothing (a fully folded row, or a row that has not started growing yet).
  ///
  /// The default sort is `manual`, so the list is a ReorderableListView and the
  /// per-slot key is `reorder-<id>`.
  double slotHeight(WidgetTester tester, String id) {
    final f = find.byKey(ValueKey('reorder-$id'));
    if (f.evaluate().isEmpty) return 0;
    return tester.getSize(f).height;
  }

  /// Ctrl-click the row titled [title] — the desktop selection gesture (the row
  /// body has an onDoubleTap, so the tap resolves only after that timeout).
  Future<void> ctrlClick(WidgetTester tester, String title) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // The bulk bar collapses IN over Motion.medium (#265). Let it finish here,
    // so the frames this suite owns afterwards belong to the ROWS alone.
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Let a command run and the task stream deliver WITHOUT advancing the clock,
  /// so the caller owns every frame of the motion that follows.
  Future<void> land(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  group('a row that arrives grows into place', () {
    testWidgets('a task created from the composer is not there in one frame', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');
      expect(full, greaterThan(0));

      await tester.enterText(find.byType(TextField), 'pears');
      await tester.pump();
      await tester.tap(find.byKey(const Key('quick-add-submit')));
      await land(tester);

      // The store already holds the task — the motion never gates the data.
      expect(fake.tasks.map((t) => t.task.title), ['apples', 'pears']);
      expect(
        slotHeight(tester, 'gen-0'),
        0,
        reason: 'the new row starts folded, not at full height',
      );

      await tester.pump(const Duration(milliseconds: 60));
      final growing = slotHeight(tester, 'gen-0');
      expect(growing, greaterThan(0));
      expect(
        growing,
        lessThan(full),
        reason: 'the row is still growing 60ms in, not already placed',
      );

      // It fades in as it grows — mid-flight it is not yet fully opaque.
      final fade = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.widgetWithText(TaskRow, 'pears'),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(fade.opacity, inExclusiveRange(0.0, 1.0));

      await tester.pump(const Duration(milliseconds: 300));
      expect(
        slotHeight(tester, 'gen-0'),
        full,
        reason: 'the row has arrived at its full height',
      );
    });

    testWidgets('a row a sync pull added grows in too', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');

      fake.pushAll([row('A', 'apples'), row('B', 'bread', position: '2')]);
      await land(tester);
      await tester.pump(const Duration(milliseconds: 60));
      expect(slotHeight(tester, 'B'), inExclusiveRange(0.0, full));
      await tester.pump(const Duration(milliseconds: 300));
      expect(slotHeight(tester, 'B'), full);
    });
  });

  group('a row that leaves folds away', () {
    testWidgets('a deleted row collapses instead of vanishing', (tester) async {
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');

      await ctrlClick(tester, 'apples');
      await tester.tap(find.byKey(const Key('bulk-delete')));
      await land(tester);

      // Gone from the store the moment the command ran…
      expect(fake.tasks.map((t) => t.task.id), ['B']);
      // …but still on screen, folding.
      await tester.pump(const Duration(milliseconds: 150));
      final folding = slotHeight(tester, 'A');
      expect(
        folding,
        inExclusiveRange(0.0, full),
        reason: 'the deleted row is still on screen, part-folded',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(
        slotHeight(tester, 'A'),
        0,
        reason: 'the fold is over and the slot is gone',
      );
      expect(find.widgetWithText(TaskRow, 'apples'), findsNothing);
    });

    testWidgets('a task rescheduled out of the view folds away', (
      tester,
    ) async {
      // Focus shows what is due today; pushing the task a month out removes it
      // from this view without deleting anything.
      await pumpList(
        tester,
        initial: [
          row('A', 'apples', due: '2026-06-15T00:00:00.000Z'),
          row('B', 'bread', due: '2026-06-15T00:00:00.000Z', position: '2'),
        ],
        lists: oneList,
        viewId: 'focus',
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');

      await ctrlClick(tester, 'apples');
      await withClock(testClock, () async {
        await tester.tap(find.byKey(const Key('bulk-due')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(quickDateKey('month')));
      });
      await land(tester);

      await tester.pump(const Duration(milliseconds: 150));
      expect(
        slotHeight(tester, 'A'),
        inExclusiveRange(0.0, full),
        reason: 'a row leaving the view folds; it does not blink out',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(slotHeight(tester, 'A'), 0);
    });

    testWidgets('Undo grows the deleted row back at the index it held', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [
          row('A', 'apples'),
          row('B', 'bread', position: '2'),
          row('C', 'cheese', position: '3'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'B');

      await ctrlClick(tester, 'bread');
      await tester.tap(find.byKey(const Key('bulk-delete')));
      await land(tester);
      // Let the fold finish so the row is genuinely gone before the Undo.
      await tester.pump(_window);
      expect(slotHeight(tester, 'B'), 0);

      await tester.tap(find.text('Undo'));
      await land(tester);
      final back = slotHeight(tester, 'B');
      expect(
        back,
        lessThan(full),
        reason: 'the restored row grows back; it does not snap in',
      );

      await tester.pump(_window);
      expect(slotHeight(tester, 'B'), full);
      final titles = tester
          .widgetList<TaskRow>(find.byType(TaskRow))
          .map((r) => r.title)
          .toList();
      expect(titles, [
        'apples',
        'bread',
        'cheese',
      ], reason: 'it comes back where it was, not at the end');
    });
  });

  group('restraint: the cap and the window', () {
    testWidgets('at most eight rows move on one change; the rest snap', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: const Size(1200, 2400),
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');

      // A sync pull that brings twenty rows at once.
      final pulled = <StoredTask>[
        row('A', 'apples'),
        for (var i = 0; i < 20; i++)
          row('p$i', 'pulled $i', position: 'p${i.toString().padLeft(2, '0')}'),
      ];
      fake.pushAll(pulled);
      await land(tester);

      final moving = [
        for (var i = 0; i < 20; i++)
          if (slotHeight(tester, 'p$i') < full) 'p$i',
      ];
      expect(
        moving.length,
        _cap,
        reason: 'exactly the cap animates; the other twelve are already placed',
      );
    });

    testWidgets('a two-hundred-row rewrite is finished inside the window', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [
          for (var i = 0; i < 200; i++)
            row('o$i', 'old $i', position: 'o${i.toString().padLeft(3, '0')}'),
        ],
        lists: oneList,
        platform: TargetPlatform.linux,
      );

      fake.pushAll([
        for (var i = 0; i < 200; i++)
          row('n$i', 'new $i', position: 'n${i.toString().padLeft(3, '0')}'),
      ]);
      await land(tester);
      await tester.pump(_window);

      expect(
        tester.binding.transientCallbackCount,
        0,
        reason:
            'every row motion the rewrite started is over: nothing is still '
            'ticking after Motion.long + the capped stagger',
      );
      expect(find.widgetWithText(TaskRow, 'old 0'), findsNothing);
    });

    testWidgets('the stagger holds a later row back, but only briefly', (
      tester,
    ) async {
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: const Size(1200, 2400),
        platform: TargetPlatform.linux,
      );
      final full = slotHeight(tester, 'A');

      fake.pushAll([
        row('A', 'apples'),
        for (var i = 0; i < 4; i++) row('p$i', 'pulled $i', position: 'p$i'),
      ]);
      await land(tester);

      // 20ms in: the first pulled row has started, the second has not (its
      // stagger slot is 40ms away).
      await tester.pump(const Duration(milliseconds: 20));
      expect(slotHeight(tester, 'p0'), greaterThan(0));
      expect(slotHeight(tester, 'p1'), 0);

      // …and by 40ms + a frame it has, so no row waits longer than one slot.
      await tester.pump(_stagger);
      expect(slotHeight(tester, 'p1'), greaterThan(0));
      expect(slotHeight(tester, 'p1'), lessThan(full));
    });
  });

  testWidgets('reduced motion places and removes rows in the same frame', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      platform: TargetPlatform.linux,
      disableAnimations: true,
    );
    final full = slotHeight(tester, 'A');

    fake.pushAll([
      row('A', 'apples'),
      row('B', 'bread', position: '2'),
      row('C', 'cheese', position: '3'),
    ]);
    await land(tester);
    expect(
      slotHeight(tester, 'C'),
      full,
      reason: 'with animations off the row is simply there',
    );

    fake.pushAll([row('B', 'bread', position: '2')]);
    await land(tester);
    expect(slotHeight(tester, 'A'), 0);
    expect(find.widgetWithText(TaskRow, 'apples'), findsNothing);
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'nothing is animating: the end state was reached in-frame',
    );
  });

  testWidgets('the first contents of a view do not animate', (tester) async {
    // Launching the app, or switching to a view, is not eight rows arriving —
    // it is what the view IS. Nothing may cascade on the first build.
    await pumpList(
      tester,
      initial: [
        for (var i = 0; i < 5; i++) row('s$i', 'seed $i', position: 's$i'),
      ],
      lists: oneList,
      platform: TargetPlatform.linux,
    );
    expect(tester.binding.transientCallbackCount, 0);
    final heights = [for (var i = 0; i < 5; i++) slotHeight(tester, 's$i')];
    expect(heights.every((h) => h > 0 && h == heights.first), isTrue);
  });

  testWidgets('completing a row keeps #241 sequence, not a second collapse', (
    tester,
  ) async {
    // A completion is the one departure that is NOT this issue's: it plays the
    // 140ms settle + 180ms collapse of #241, so the whole thing is over well
    // before a 300ms leave would be.
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'apples'),
        row('B', 'bread', position: '2'),
      ],
      lists: oneList,
      platform: TargetPlatform.linux,
    );
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(TaskRow, 'apples'),
        matching: find.byType(Checkbox),
      ),
    );
    await land(tester);
    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'A').task.status,
      TaskStatus.completed,
    );
    await tester.pump(const Duration(milliseconds: 330));
    expect(
      slotHeight(tester, 'A'),
      0,
      reason: 'the completion sequence is 320ms end to end, not 300+stagger',
    );
  });
}
