// SubtaskReorder suite — reordering a parent's subtasks from the detail panel
// (#90).
//
// The pair of up/down arrow buttons this suite used to drive is GONE (#306):
// it cost 96dp of chrome on every row, moved a subtask one slot per press, and
// could not be reached by a drag at all. Reorder is now a DRAG on a handle, the
// same affordance the task list already uses.
//
// The [FakeCommands] actually reassigns sibling positions on each
// `reorderTaskAfter`, so these assert the USER-VISIBLE order the panel renders
// — not merely that a command fired. The key non-happy case survives the
// change: reordering across a COLLAPSED completed subtask, which a naive
// visible-index step gets wrong, and which is ONE anchored reorder rather than
// a burst of swaps (#202).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  /// Drag the handle of the open subtask [id] down by [slots] rows and drop
  /// it (a negative [slots] drags it up). `ReorderableDragStartListener` is an immediate
  /// recognizer, so the gesture is stepped rather than flung.
  Future<void> dragSubtask(
    WidgetTester tester,
    String id, {
    required double slots,
  }) async {
    final handle = find.byKey(ValueKey('subtask-drag-handle-$id'));
    expect(handle, findsOneWidget, reason: 'every open subtask has a handle');
    final rowHeight = tester.getSize(find.byKey(ValueKey(id))).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(0, rowHeight * slots / 4));
      await tester.pump();
    }
    await gesture.up();
    // Bounded pumps, never pumpAndSettle: an undo toast runs a 30-SECOND
    // countdown animation, so settling to quiescence would run the toast this
    // very gesture raises out of its life before the test can see it.
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  group('drag reorder replaces the arrow buttons (#90)', () {
    testWidgets('no move-up / move-down buttons remain in the checklist', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', position: '1'),
          row('s2', 'Beta', parent: 'P', position: '2'),
        ],
      );
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      expect(find.byTooltip('Move up'), findsNothing);
      expect(find.byTooltip('Move down'), findsNothing);
      // …and the drag affordance is there in their place, one per open row.
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    });

    testWidgets('dragging a subtask down reorders it and offers one Undo', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', position: '1'),
          row('s2', 'Beta', parent: 'P', position: '2'),
        ],
      );
      expect(subtaskOrder(tester, ['Alpha', 'Beta']), ['Alpha', 'Beta']);

      await dragSubtask(tester, 's1', slots: 1.2);

      expect(subtaskOrder(tester, ['Alpha', 'Beta']), ['Beta', 'Alpha']);
      expect(fake.reordered, [
        's1:s2',
      ], reason: 'one drop is ONE anchored reorder, not a burst of steps');

      // ONE Undo for the drop, and it puts the row back where it started.
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settleDetail(tester);
      expect(subtaskOrder(tester, ['Alpha', 'Beta']), ['Alpha', 'Beta']);
    });

    testWidgets(
      'a drag across a COLLAPSED completed subtask lands where dropped',
      (tester) async {
        // Beta sits between Alpha and Gamma in the stored order but is folded
        // into the completed group, so it is not on screen between them. An
        // anchor taken from the visible slot index would leave the row behind
        // it.
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          hideCompletedSubtasks: true,
          initial: [
            row('P', 'Parent'),
            row('s1', 'Alpha', parent: 'P', position: '1'),
            row('s2', 'Beta', parent: 'P', position: '2', done: true),
            row('s3', 'Gamma', parent: 'P', position: '3'),
          ],
        );
        expect(find.text('Beta'), findsNothing, reason: 'collapsed away');
        expect(subtaskOrder(tester, ['Alpha', 'Gamma']), ['Alpha', 'Gamma']);

        await dragSubtask(tester, 's3', slots: -1.2);

        expect(subtaskOrder(tester, ['Alpha', 'Gamma']), ['Gamma', 'Alpha']);
        expect(fake.reordered, [
          's3:<front>',
        ], reason: 'Gamma follows nothing — Alpha was itself first');

        // Revealing the completed one shows it kept its own place.
        await tester.tap(find.byKey(const Key('completed-subtasks-toggle')));
        await settleDetail(tester);
        expect(subtaskOrder(tester, ['Alpha', 'Beta', 'Gamma']), [
          'Gamma',
          'Alpha',
          'Beta',
        ]);
      },
    );

    testWidgets('a drop back in place writes nothing and says nothing', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', position: '1'),
          row('s2', 'Beta', parent: 'P', position: '2'),
        ],
      );
      await dragSubtask(tester, 's1', slots: 0.1);
      expect(fake.reordered, isEmpty);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('completed subtasks carry no drag handle', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', position: '1'),
          row('s2', 'Beta', parent: 'P', position: '2', done: true),
        ],
      );
      expect(
        find.byKey(const ValueKey('subtask-drag-handle-s1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subtask-drag-handle-s2')),
        findsNothing,
        reason: 'a finished row is not part of the ordering being arranged',
      );
    });
  });
}
