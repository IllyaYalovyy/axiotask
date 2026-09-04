// F18 (#197) Selection ergonomics + list orientation. WIDGET tests over the real
// [TaskListView] on the mutating [FakeCommands]:
//
//   • touch selection mode — once a selection is active (a long-press entered
//     it), a PLAIN tap toggles a row's membership instead of opening the detail;
//   • a visible desktop entry to selection — a "Select"/"Deselect" item in the
//     row context menu / action sheet;
//   • list orientation — the list-name tag renders on every row in a cross-list
//     view (Focus/All) and NEVER in a single-list view.
//
// Every assertion is on what RENDERS (the bulk-bar count, the tag text, whether
// the detail opened) — never that a method fired.

import 'package:axiotask/src/ui/bulk_bar.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];
  final twoLists = [list('L1', 'My Tasks'), list('L2', 'Errands')];

  /// A plain (unmodified) tap on the row titled [title]. The row body has an
  /// onDoubleTap, so the onTap only resolves after the double-tap timeout.
  Future<void> plainTap(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Right-click the row titled [title] to open the desktop context menu.
  Future<void> rightClick(WidgetTester tester, String title) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(title)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  group('touch selection mode — tap extends the selection', () {
    testWidgets(
      'once a long-press has entered selection, a plain tap toggles membership '
      'instead of opening the detail',
      (tester) async {
        final opened = <String>[];
        await pumpList(
          tester,
          initial: [row('A', 'apples'), row('B', 'bread'), row('C', 'cheese')],
          lists: oneList,
          opened: opened,
        );
        // Enter selection mode by long-pressing the first row (the T8.1 gesture).
        await tester.longPress(find.text('apples'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('1 selected'), findsOneWidget);

        // A plain tap on another row now EXTENDS the selection — it must not open
        // the detail panel.
        await plainTap(tester, 'bread');
        expect(find.text('2 selected'), findsOneWidget);
        expect(opened, isEmpty, reason: 'a tap in selection mode never opens');

        // Tapping a selected row toggles it back OUT.
        await plainTap(tester, 'apples');
        expect(find.text('1 selected'), findsOneWidget);
        expect(opened, isEmpty);
      },
    );

    testWidgets(
      'with NO selection active a plain touch tap still opens the detail',
      (tester) async {
        final opened = <String>[];
        await pumpList(
          tester,
          initial: [row('A', 'apples')],
          lists: oneList,
          opened: opened,
        );
        await plainTap(tester, 'apples');
        expect(opened, ['A']);
        expect(find.byType(BulkBar), findsNothing);
      },
    );
  });

  group('desktop entry to selection — the context menu Select item', () {
    testWidgets('right-click offers "Select", which adds the row to the '
        'selection', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      expect(find.byType(BulkBar), findsNothing);
      await rightClick(tester, 'apples');
      final selectItem = find.byKey(const Key('taskmenu-select'));
      expect(selectItem, findsOneWidget);
      expect(find.text('Select'), findsOneWidget);
      await tester.tap(selectItem);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // The selection lands in a post-frame callback (the menu dismisses
      // first), so the bar's collapse-in starts on the NEXT frame (#265).
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(BulkBar), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('the entry reads "Deselect" for an already-selected row and '
        'removes it', (tester) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      // Select via Ctrl-click first.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('apples'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      // One more frame: the bar collapses IN rather than appearing (#265).
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('1 selected'), findsOneWidget);

      await rightClick(tester, 'apples');
      expect(find.text('Deselect'), findsOneWidget);
      await tester.tap(find.byKey(const Key('taskmenu-select')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      // … and it collapses OUT, so it is still on screen for one more frame.
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(BulkBar), findsNothing);
    });
  });

  group("touch entry to selection — the toolbar's 'Select tasks' (#245)", () {
    /// Open the list toolbar's overflow and enter selection mode through it.
    Future<void> selectTasksFromToolbar(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('toolbar-overflow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const Key('toolbar-select-tasks')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('enters selection mode with NOTHING selected, bulk bar shown, '
        'and the first row tap then selects', (tester) async {
      final opened = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
        opened: opened,
      );
      expect(find.byType(BulkBar), findsNothing);

      await selectTasksFromToolbar(tester);

      expect(find.byType(BulkBar), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('bulk-count'))).data,
        'Select tasks',
        reason: 'the bar names the mode while the selection is still empty',
      );

      // The FIRST plain tap selects rather than opening the detail — the whole
      // point of entering the mode before touching a row.
      await plainTap(tester, 'apples');
      expect(find.text('1 selected'), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('with nothing selected the whole-selection actions are '
        'disabled — no button that does nothing', (tester) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      await selectTasksFromToolbar(tester);

      for (final k in const [
        'bulk-complete',
        'bulk-due',
        'bulk-move',
        'bulk-delete',
      ]) {
        expect(
          tester.widget<TextButton>(find.byKey(Key(k))).onPressed,
          isNull,
          reason: '$k must be disabled while nothing is selected',
        );
      }
      // Duplicate and "Make subtasks of…" moved behind the "⋮" (#265); the
      // rule is the same, so the menu that holds them cannot be opened at all.
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const Key('bulk-overflow')),
            )
            .enabled,
        isFalse,
        reason: 'the overflow must not open a menu of dead entries',
      );

      // Selecting one row arms them.
      await plainTap(tester, 'apples');
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('bulk-complete')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('clearing the empty mode restores plain tap-to-open', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        opened: opened,
      );
      await selectTasksFromToolbar(tester);
      await tester.tap(find.byKey(const Key('bulk-clear-selection')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(BulkBar), findsNothing);
      await plainTap(tester, 'apples');
      expect(opened, ['A']);
    });

    testWidgets('the overflow stays MOUNTED once the mode is on (its entry '
        'merely greys out) — the toolbar never re-flows under the finger', (
      tester,
    ) async {
      await pumpList(tester, initial: [row('A', 'apples')], lists: oneList);
      final before = tester.getRect(
        find.byKey(const Key('show-completed-toggle')),
      );
      await selectTasksFromToolbar(tester);

      expect(find.byKey(const Key('toolbar-overflow')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('show-completed-toggle'))),
        before,
        reason: 'entering the mode must not move the toolbar controls',
      );
      await tester.tap(find.byKey(const Key('toolbar-overflow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.byKey(const Key('toolbar-select-tasks')),
            )
            .enabled,
        isFalse,
        reason: 'the mode is already on — the entry has nothing left to do',
      );
    });

    testWidgets('the toolbar overflow is a COARSE-pointer affordance — the '
        'desktop reaches selection by Ctrl-click and right-click', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: [row('A', 'apples')],
        lists: oneList,
        platform: TargetPlatform.linux,
      );
      expect(find.byKey(const Key('toolbar-overflow')), findsNothing);
    });
  });

  group('list orientation — the list-name tag', () {
    testWidgets('the All view tags every row with its list name', (
      tester,
    ) async {
      await pumpList(
        tester,
        viewId: 'all',
        initial: [
          row('A', 'apples', listId: 'L1'),
          row('B', 'batteries', listId: 'L2'),
        ],
        lists: twoLists,
      );
      // Each row carries a tag naming the list it belongs to.
      expect(find.text('My Tasks'), findsOneWidget);
      expect(find.text('Errands'), findsOneWidget);
    });

    testWidgets('the Focus view (cross-list) also tags each row', (
      tester,
    ) async {
      await pumpList(
        tester,
        viewId: 'focus',
        initial: [
          // Both dated within the focus window (clock is 2026-06-15).
          row('A', 'apples', due: '2026-06-15T00:00:00.000Z', listId: 'L1'),
          row('B', 'batteries', due: '2026-06-16T00:00:00.000Z', listId: 'L2'),
        ],
        lists: twoLists,
      );
      expect(find.text('apples'), findsOneWidget);
      expect(find.text('batteries'), findsOneWidget);
      expect(find.text('My Tasks'), findsOneWidget);
      expect(find.text('Errands'), findsOneWidget);
    });

    testWidgets('a single-list view renders NO tag', (tester) async {
      await pumpList(
        tester,
        viewId: 'L1',
        initial: [row('A', 'apples', listId: 'L1')],
        lists: oneList,
      );
      expect(find.text('apples'), findsOneWidget);
      // The list's own name is never shown as a per-row tag in its own view.
      expect(find.text('My Tasks'), findsNothing);
    });
  });
}
