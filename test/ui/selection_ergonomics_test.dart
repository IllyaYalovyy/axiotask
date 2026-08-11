// F18 (#197) Selection ergonomics + list orientation. WIDGET tests over the real
// [TaskListView] on the mutating [FakeBackend]:
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
      expect(find.text('1 selected'), findsOneWidget);

      await rightClick(tester, 'apples');
      expect(find.text('Deselect'), findsOneWidget);
      await tester.tap(find.byKey(const Key('taskmenu-select')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(BulkBar), findsNothing);
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
