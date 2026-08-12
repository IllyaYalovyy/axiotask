// DragAndDrop semantics (MIGRATION-PLAN §5 T7.6). The HTML5-drag mechanics die;
// the SEMANTICS port to Flutter's reorderable: drag handles only in manual sort,
// a drop resolves to ONE target sibling index counting ONLY same-list siblings
// (cross-list smart-view cards are skipped), and a same-level (top-level-only)
// flat list. The touch-hold timing lives in T8.1; here the desktop drag-handle
// path is covered. A drop now issues a single move-to-index command (F20 #199).

import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  group('reorderTarget (single target sibling index, same-list-only)', () {
    final singleList = [
      row('A', 'a'),
      row('B', 'b'),
      row('C', 'c'),
      row('D', 'd'),
    ];

    test('a downward move targets the slot past every row it lands past', () {
      // A (rank 0) → landing index 2 (past B and C) → sibling slot 2.
      expect(reorderTarget(singleList, 0, 2), 2);
    });

    test('an upward move targets the slot before the rows it lands before', () {
      // D (rank 3) → landing index 1, crossing C and B → sibling slot 1.
      expect(reorderTarget(singleList, 3, 1), 1);
    });

    test('a drop in place is a no-op', () {
      expect(reorderTarget(singleList, 1, 1), isNull);
    });

    test('cross-list cards are NOT counted as reorder siblings', () {
      final crossList = [
        row('A', 'a', listId: 'L1'),
        row('X', 'x', listId: 'L2'),
        row('B', 'b', listId: 'L1'),
      ];
      // A (rank 0 in L1) → landing index 2 crosses X (other list, skipped) and B
      // (same) → one same-list step → sibling slot 1.
      expect(reorderTarget(crossList, 0, 2), 1);
    });

    test('a move crossing only other-list cards is a no-op', () {
      final crossList = [
        row('A', 'a', listId: 'L1'),
        row('X', 'x', listId: 'L2'),
        row('Y', 'y', listId: 'L2'),
      ];
      expect(reorderTarget(crossList, 0, 2), isNull);
    });
  });

  testWidgets('renders a reorderable list with drag handles in manual sort', (
    tester,
  ) async {
    await pumpList(
      tester,
      initial: [row('A', 'a'), row('B', 'b')],
      lists: oneList,
    );
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byKey(const Key('drag-handle-A')), findsOneWidget);
    expect(find.byKey(const Key('drag-handle-B')), findsOneWidget);
  });

  testWidgets('shows NO drag handles when the sort is not manual', (
    tester,
  ) async {
    await pumpList(
      tester,
      initial: [row('A', 'a'), row('B', 'b')],
      lists: oneList,
      sortPerView: const {'all': 'alpha'},
    );
    expect(find.byType(ReorderableListView), findsNothing);
    expect(find.byKey(const Key('drag-handle-A')), findsNothing);
  });

  testWidgets('dragging a row down issues one move-to-index command', (
    tester,
  ) async {
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'a', position: '1'),
        row('B', 'b', position: '2'),
      ],
      lists: oneList,
    );
    // Drag A's handle down past B and drop. ReorderableDragStartListener is an
    // immediate recognizer, so step the gesture across B's slot then release.
    final handle = find.byKey(const Key('drag-handle-A'));
    final rowHeight = tester.getSize(find.byKey(const ValueKey('A'))).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, rowHeight * 0.6));
    await tester.pump();
    await gesture.moveBy(Offset(0, rowHeight * 0.6));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // One same-list step down → exactly one reorderTaskToIndex('A', 1).
    expect(fake.reordered, ['A:1']);
  });

  testWidgets('a MOUSE-kind drag reorders exactly like a touch drag (#201)', (
    tester,
  ) async {
    // Desktop reorder rides a real mouse, not the touch pointer the sibling test
    // (and startGesture's default) uses. ReorderableDragStartListener is device-
    // agnostic; this pins that a mouse press-drag on the handle still fires the
    // single move-to-index command — so a regression that gated reorder to touch
    // (e.g. a dragDevices/PointerDeviceKind filter) would surface here.
    final fake = await pumpList(
      tester,
      initial: [
        row('A', 'a', position: '1'),
        row('B', 'b', position: '2'),
      ],
      lists: oneList,
      platform: TargetPlatform.linux,
    );
    final handle = find.byKey(const Key('drag-handle-A'));
    final rowHeight = tester.getSize(find.byKey(const ValueKey('A'))).height;
    final gesture = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, rowHeight * 0.6));
    await tester.pump();
    await gesture.moveBy(Offset(0, rowHeight * 0.6));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(fake.reordered, ['A:1']);
  });
}
