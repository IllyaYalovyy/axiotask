// DragAndDrop semantics (MIGRATION-PLAN §5 T7.6). The HTML5-drag mechanics die;
// the SEMANTICS port to Flutter's reorderable: drag handles only in manual sort,
// a drop resolves to ONE anchor sibling (the visible neighbour it lands after,
// counting ONLY same-list siblings — cross-list smart-view cards are skipped),
// on a same-level (top-level-only) flat list. The touch-hold timing lives in
// T8.1; here the desktop drag-handle path is covered. A drop issues a single
// anchored reorder resolved against the store's own order (#202), so it stays
// correct across hidden completed rows and Focus's lifted overdue bucket.

import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  group('reorderAnchor (anchor sibling id, same-list-only)', () {
    final singleList = [
      row('A', 'a'),
      row('B', 'b'),
      row('C', 'c'),
      row('D', 'd'),
    ];

    test('a downward move anchors after the last row it lands past', () {
      // A → adjusted landing index 2: in the reduced [B, C, D] it follows C.
      expect(reorderAnchor(singleList, 0, 2)?.previousId, 'C');
    });

    test('an upward move anchors after the row it lands behind', () {
      // D → adjusted landing index 1: in the reduced [A, B, C] it follows A.
      expect(reorderAnchor(singleList, 3, 1)?.previousId, 'A');
    });

    test('a move to the very top anchors at the front (null)', () {
      // D → landing index 0: nothing above → drop at the front of the siblings.
      expect(reorderAnchor(singleList, 3, 0), (previousId: null));
    });

    test('a drop in place is a no-op', () {
      expect(reorderAnchor(singleList, 1, 1), isNull);
    });

    test('cross-list cards are NOT counted as reorder siblings', () {
      final crossList = [
        row('A', 'a', listId: 'L1'),
        row('X', 'x', listId: 'L2'),
        row('B', 'b', listId: 'L1'),
      ];
      // A → landing index 2 crosses X (other list, skipped) and B (same) → the
      // nearest same-list row above the drop is B.
      expect(reorderAnchor(crossList, 0, 2)?.previousId, 'B');
    });

    test('a move crossing only other-list cards is a no-op', () {
      final crossList = [
        row('A', 'a', listId: 'L1'),
        row('X', 'x', listId: 'L2'),
        row('Y', 'y', listId: 'L2'),
      ];
      expect(reorderAnchor(crossList, 0, 2), isNull);
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

  testWidgets('the drag handle sits on the row\'s TITLE line', (tester) async {
    // The row's leading controls belong to the title, not to the two-line
    // block (#276): centred on the row, the handle sat 12dp below the checkbox
    // beside it and pointed at the gap between the two lines.
    await pumpList(tester, initial: [row('A', 'a')], lists: oneList);
    final handle = tester.getRect(find.byKey(const Key('drag-handle-A')));
    final checkbox = tester.getRect(
      find.byKey(const Key('row-checkbox-target')),
    );
    expect(
      (handle.center.dy - checkbox.center.dy).abs(),
      lessThanOrEqualTo(1),
      reason: 'the handle and the checkbox must share the title line',
    );
    // ...without giving up the 48dp drag target.
    expect(handle.height, greaterThanOrEqualTo(48));
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

  testWidgets('dragging a row down issues one anchored reorder', (
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

    // One same-list step down → exactly one reorderTaskAfter('A', 'B').
    expect(fake.reordered, ['A:B']);
  });

  testWidgets('a MOUSE-kind drag reorders exactly like a touch drag (#201)', (
    tester,
  ) async {
    // Desktop reorder rides a real mouse, not the touch pointer the sibling test
    // (and startGesture's default) uses. ReorderableDragStartListener is device-
    // agnostic; this pins that a mouse press-drag on the handle still fires the
    // single anchored reorder — so a regression that gated reorder to touch
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

    expect(fake.reordered, ['A:B']);
  });

  testWidgets(
    'dragging past a HIDDEN completed row lands where dropped (#202)',
    (tester) async {
      // Hide completed drops B from the visible list, but it stays interleaved
      // in the stored order. A gesture that drags A one visible slot down (past
      // C) must land A after C both on screen AND in the stored order — never
      // stall behind the hidden B while the order silently shifts.
      final fake = await pumpList(
        tester,
        initial: [
          row('A', 'a', position: '1'),
          row('B', 'b', position: '2', done: true), // hidden by showCompleted
          row('C', 'c', position: '3'),
          row('D', 'd', position: '4'),
        ],
        lists: oneList,
        showCompleted: false,
      );
      // Only the three open rows render.
      expect(find.byKey(const ValueKey('B')), findsNothing);

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

      // Rendered order: A dropped after C.
      double top(String id) => tester.getTopLeft(find.byKey(ValueKey(id))).dy;
      expect(top('C'), lessThan(top('A')));
      expect(top('A'), lessThan(top('D')));

      // Stored order (position order, hidden B included): B, C, A, D — the
      // anchor was resolved against the same ordering, so B kept its slot.
      final stored =
          (fake.tasks.toList()
                ..sort((a, b) => a.task.position.compareTo(b.task.position)))
              .map((t) => t.task.id)
              .toList();
      expect(stored, ['B', 'C', 'A', 'D']);
    },
  );
}
