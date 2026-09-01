// The bulk bar's SHAPE (#265).
//
// After #243 folded four date buttons into one "Due ▾" and #245 handed the
// retired per-row "⋮" its Duplicate and "Make subtasks of…", the bar carried
// seven labelled buttons in a [Wrap]. On the device the app is FOR that is not
// one toolbar: at 400dp the labels flowed onto FOUR runs — 264dp of permanent
// chrome above the first row, on top of the app bar and the bottom nav — and
// 340dp at the 2.0 accessibility text scale. A bar whose height depends on how
// long its labels happen to be is not a bar.
//
// So the bar is ONE row, [BulkBar.height] tall, at every width and every text
// scale: × · "N selected" · the four everyday actions · a "⋮" holding the two
// rarer ones. When the surface is wide enough for the labels it shows them —
// same row, same height, same order; when it is not, the actions are icons with
// tooltips. Nothing here ever wraps, so nothing here can push the list down.
//
// Every assertion is geometric or about what a finger can reach: the rendered
// height of the bar, whether a label is on screen, whether an action is
// hit-testable, and what the fake HOLDS after the action runs.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:axiotask/src/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  const phone = Size(400, 900);
  const desktop = Size(1200, 900);

  /// The touch way into selection mode — a long-press on a row.
  Future<void> longPressRow(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await settleList(tester);
  }

  /// The height the bar actually TAKES from the list — the slot it collapses
  /// in and out of, not the bar's own (fixed) box.
  double slotHeight(WidgetTester tester) =>
      tester.getSize(find.byType(BulkBarSlot)).height;

  /// Nothing on the row may hang outside the bar: an action pushed past the
  /// bar's own box is one a finger cannot land on.
  void expectInsideBar(WidgetTester tester, String key) {
    final bar = tester.getRect(find.byType(BulkBar));
    final action = tester.getRect(find.byKey(Key(key)));
    expect(
      bar.contains(action.topLeft) &&
          bar.contains(action.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
      reason: '$key is laid out at $action, outside the bar at $bar',
    );
  }

  /// Every action the bar must keep reachable, by key.
  const inlineActions = [
    'bulk-complete',
    'bulk-due',
    'bulk-move',
    'bulk-delete',
  ];

  group('one row, whatever the width and whatever the text scale', () {
    for (final scale in const [1.0, 1.3, 2.0]) {
      testWidgets('a 400dp phone at ${scale}x text: one 56dp row, every '
          'action reachable', (tester) async {
        await pumpList(
          tester,
          initial: [row('A', 'apples'), row('B', 'bread')],
          lists: oneList,
          size: phone,
          platform: TargetPlatform.android,
          textScale: scale,
        );
        await longPressRow(tester, 'apples');

        expect(tester.takeException(), isNull);
        expect(
          slotHeight(tester),
          BulkBar.height,
          reason:
              'the bar must take ONE row from the list at ${scale}x — a wrap '
              'grows a run per label and eats the list',
        );
        for (final key in [...inlineActions, 'bulk-clear-selection']) {
          expect(
            find.byKey(Key(key)).hitTestable(),
            findsOneWidget,
            reason: '$key must stay tappable at ${scale}x on a 400dp phone',
          );
          expectInsideBar(tester, key);
        }
        expect(
          find.byKey(const Key('bulk-overflow')).hitTestable(),
          findsOneWidget,
          reason: 'the two rarer actions must stay reachable behind the ⋮',
        );
      });
    }

    testWidgets('a 1200dp desktop is the SAME one row — with labels', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: desktop,
      );
      await tester.longPress(find.text('apples'));
      await settleList(tester);

      expect(slotHeight(tester), BulkBar.height);
      for (final label in const ['Complete', 'Due', 'Move', 'Delete']) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'a wide surface spells the action out',
        );
      }
      for (final key in [...inlineActions, 'bulk-clear-selection']) {
        expectInsideBar(tester, key);
        expect(
          tester.getSize(find.byKey(Key(key))).shortestSide,
          greaterThanOrEqualTo(48.0),
          reason: '$key is too small for a finger even with a label on it',
        );
      }
    });

    testWidgets('a 400dp phone spells NOTHING out — the labels would wrap, so '
        'the actions are icons with tooltips', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
      );
      await longPressRow(tester, 'apples');

      for (final label in const ['Complete', 'Move', 'Delete']) {
        expect(
          find.text(label),
          findsNothing,
          reason: '$label must be an icon',
        );
      }
      // The action is still NAMED — a tooltip, not a mystery glyph.
      for (final label in const ['Complete', 'Due', 'Move', 'Delete']) {
        expect(find.byTooltip(label), findsOneWidget);
      }
    });

    // The non-happy path: a WIDE surface whose labels still do not fit, because
    // the system font is at the 2.0 accessibility ceiling. The bar drops to
    // icons rather than wrapping or overflowing — the fit decides, not the
    // breakpoint.
    testWidgets('a wide surface at 2.0x text drops the labels rather than '
        'growing a second run', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: const Size(700, 900),
        textScale: 2,
      );
      await tester.longPress(find.text('apples'));
      await settleList(tester);

      expect(tester.takeException(), isNull);
      expect(slotHeight(tester), BulkBar.height);
      for (final key in inlineActions) {
        expectInsideBar(tester, key);
      }
      expect(find.text('Complete'), findsNothing);
      expect(find.byTooltip('Complete').hitTestable(), findsOneWidget);
    });
  });

  // The count is the one thing on the row that grows with the text scale. At
  // 2.0x on a phone the phrase no longer fits beside six square buttons, and
  // "3 sel…" spends the same pixels to say less than "3" does — so it degrades
  // to the number, and a screen reader still hears the phrase.
  testWidgets('at 2.0x on a phone the count reads "2", not "2 sel…" — and is '
      'still announced in full', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
      size: phone,
      platform: TargetPlatform.android,
      textScale: 2,
    );
    await longPressRow(tester, 'apples');
    await tester.longPress(find.text('bread'));
    await settleList(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('bulk-count'))).data,
      '2',
      reason: 'the number is the information; the word is what gets cut',
    );
    expect(find.bySemanticsLabel('2 selected'), findsOneWidget);
    handle.dispose();
  });

  // Visual stability. The row's FORM must not depend on how many rows are
  // picked: at a width where "9 selected" fits spelled out and "10 selected"
  // does not, the tenth tap would drop all four labels to icons under the
  // finger that made it. Swept across every width the bar can be given.
  testWidgets('the labels never come and go as the selection grows', (
    tester,
  ) async {
    Future<bool> spelledAt(double width, int count) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: BulkBar(
                count: count,
                onComplete: () {},
                onSetDue: (_) {},
                onPickDue: () {},
                onMove: () {},
                onDuplicate: () {},
                onDemote: () {},
                onDelete: () {},
                onClear: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return find.text('Complete').evaluate().isNotEmpty;
    }

    for (var width = 300.0; width <= 1400; width += 20) {
      final one = await spelledAt(width, 1);
      for (final count in const [9, 10, 99, 100, 999]) {
        expect(
          await spelledAt(width, count),
          one,
          reason:
              'at ${width}dp the bar spells its actions out for 1 selected but '
              'not for $count — the row reflows as the selection grows',
        );
      }
    }
  });

  group('the ⋮ overflow carries the two rarer actions', () {
    testWidgets('Duplicate runs from the overflow on a phone', (tester) async {
      var seq = 0;
      final fake = await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
        newId: () => 'copy-${seq++}',
      );
      await longPressRow(tester, 'apples');
      await tester.tap(find.byKey(const Key('bulk-overflow')));
      await settleList(tester);

      expect(find.byKey(const Key('bulk-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('bulk-demote')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bulk-duplicate')));
      await settleList(tester);

      expect(
        fake.tasks.map((t) => t.task.title),
        contains('apples (copy)'),
        reason: 'the overflow entry must actually duplicate',
      );
    });

    testWidgets('the overflow drops "Make subtasks of…" when no single task '
        'could host the selection', (tester) async {
      await pumpList(
        tester,
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('C', 'cheese'),
        ],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
      );
      await longPressRow(tester, 'parent');
      await tester.tap(find.byKey(const Key('bulk-overflow')));
      await settleList(tester);

      expect(find.byKey(const Key('bulk-duplicate')), findsOneWidget);
      expect(
        find.byKey(const Key('bulk-demote')),
        findsNothing,
        reason: 'a task with subtasks can never become one',
      );
    });

    testWidgets('with NOTHING selected the ⋮ is disabled — it would open a '
        'menu of dead entries', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
      );
      await tester.tap(find.byKey(const Key('toolbar-overflow')));
      await settleList(tester);
      await tester.tap(find.byKey(const Key('toolbar-select-tasks')));
      await settleList(tester);

      expect(find.byType(BulkBar), findsOneWidget);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const Key('bulk-overflow')),
            )
            .enabled,
        isFalse,
      );
    });
  });

  group('the bar collapses in and out (Motion.medium)', () {
    testWidgets('it grows its height on arrival and folds it away on clear', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
      );

      // Arrive: the row above the list must not JUMP into place.
      await tester.longPress(find.text('apples'));
      await tester.pump();
      await tester.pump(MotionDurations.medium ~/ 4);
      final early = slotHeight(tester);
      expect(
        early,
        allOf(greaterThan(0.0), lessThan(BulkBar.height)),
        reason: 'the bar unfolds; it does not appear at full height',
      );
      await tester.pump(MotionDurations.medium ~/ 4);
      final midway = slotHeight(tester);
      expect(midway, greaterThan(early));
      expect(midway, lessThan(BulkBar.height));
      await tester.pump(MotionDurations.medium);
      expect(slotHeight(tester), BulkBar.height);

      // Leave: still on screen mid-collapse, gone once it finishes.
      await tester.tap(find.byKey(const Key('bulk-clear-selection')));
      await tester.pump();
      await tester.pump(MotionDurations.medium ~/ 2);
      final leaving = slotHeight(tester);
      expect(
        leaving,
        allOf(greaterThan(0.0), lessThan(BulkBar.height)),
        reason: 'the bar folds away; it does not vanish',
      );
      await tester.pump(MotionDurations.medium);
      expect(find.byType(BulkBar), findsNothing);
    });

    testWidgets('with animations removed it is simply there, and simply gone', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        size: phone,
        platform: TargetPlatform.android,
        disableAnimations: true,
      );
      await tester.longPress(find.text('apples'));
      await tester.pump();
      expect(
        slotHeight(tester),
        BulkBar.height,
        reason: 'reduced motion reaches the end state in the same frame',
      );
      await tester.tap(find.byKey(const Key('bulk-clear-selection')));
      await tester.pump();
      expect(find.byType(BulkBar), findsNothing);
    });
  });

  testWidgets('the bar sits ABOVE the list and leaves the chrome alone — no '
      'app-bar morph', (tester) async {
    await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
      size: phone,
      platform: TargetPlatform.android,
    );
    final toolbarBefore = tester.getRect(
      find.byKey(const Key('sort-dropdown')),
    );
    await longPressRow(tester, 'apples');

    expect(
      tester.getRect(find.byKey(const Key('sort-dropdown'))),
      toolbarBefore,
      reason: 'the list toolbar does not become the selection bar',
    );
    final bar = tester.getRect(find.byType(BulkBar));
    expect(bar.top, greaterThanOrEqualTo(toolbarBefore.bottom));
    expect(
      bar.bottom,
      lessThanOrEqualTo(tester.getRect(find.text('bread')).top),
      reason: 'the bar is chrome above the rows, never over them',
    );
  });

  testWidgets('bulk Complete still completes the selection from the icon', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [row('A', 'apples'), row('B', 'bread')],
      lists: oneList,
      size: phone,
      platform: TargetPlatform.android,
    );
    await longPressRow(tester, 'apples');
    await tester.tap(find.byKey(const Key('bulk-complete')));
    await settleList(tester);

    expect(
      fake.tasks.firstWhere((t) => t.task.id == 'A').task.status,
      TaskStatus.completed,
    );
  });
}
