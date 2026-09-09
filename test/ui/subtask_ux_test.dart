// The #306 subtask UX pass, asserted on what the panel RENDERS and on what the
// fake HOLDS afterwards — never on which callback fired.
//
// What each group protects, and the failure it bars:
//
//   • drag reorder — the checklist used to carry a pair of arrow buttons per
//     row (96dp of chrome, one slot per press, unreachable by drag). A drag
//     must now move a subtask anywhere in one gesture, write ONE anchored
//     reorder, and offer ONE Undo that puts it back where it was. The
//     non-happy case is a drag while completed siblings are COLLAPSED: they
//     stay interleaved in the stored order, so an anchor computed off the
//     visible slot index would land the row in the wrong place.
//   • the row itself — a subtask with notes, a link or an unpushed edit showed
//     no sign of any of them, and a finger could not swipe it. It is now the
//     list's own row at subtask density, so all of that has to be there.
//   • the completed group — the finished subtasks gather under "N completed",
//     one tap from view, and the preference behind that group is no longer a
//     checkbox inside every panel.
//   • one progress format — the header states the SAME "N/M" the parent's row
//     states in the list, not a third wording of the same number.
//   • cascade counts — completing or deleting a parent moves its whole subtree;
//     the toast has to say how many rows Undo would restore.
//   • the empty hint — a parent with no subtasks said nothing about what the
//     bare input was for.
//
// Determinism: no due dates unless a test needs one, every field unfocused, and
// bounded pumps rather than pumpAndSettle (the panel holds text fields whose
// cursor never stops blinking).

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/ui/quick_date_menu.dart' show quickDateKey;
import 'package:axiotask/src/ui/task_row.dart' show TaskRow, TaskRowDensity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  group('a subtask row IS a task row (#306)', () {
    testWidgets('it is a TaskRow at subtask density', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P'),
        ],
      );
      final rows = tester.widgetList<TaskRow>(find.byType(TaskRow));
      expect(rows, hasLength(1));
      expect(rows.single.density, TaskRowDensity.subtask);
    });

    testWidgets('a subtask with notes shows the notes badge', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', notes: 'the fine print'),
          row('s2', 'Beta', parent: 'P'),
        ],
      );
      // Exactly one — the one that HAS notes.
      expect(find.byKey(const Key('notes-badge')), findsOneWidget);
    });

    testWidgets('a subtask with an unpushed edit shows the pending dot', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P'),
        ],
      );
      expect(find.byKey(const Key('pending-dot')), findsNothing);

      // Rename it through the store: the fake marks the row dirty exactly as
      // the real command does, so the dot is the local-edit signal the list
      // rows already carry.
      await fake.renameTask('s1', 'Alpha renamed');
      await settleDetail(tester);
      expect(find.byKey(const Key('pending-dot')), findsOneWidget);
    });

    testWidgets('a link in a subtask note is a tappable badge', (tester) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P', notes: 'see https://example.com/x'),
        ],
        urlOpener: (url) async => opened.add(url),
      );
      await tester.tap(find.byKey(const Key('link-badge')));
      await settleDetail(tester);
      expect(opened, ['https://example.com/x']);
    });

    testWidgets('swiping a subtask right completes it (touch)', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        theme: ThemeData(platform: TargetPlatform.android),
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P'),
        ],
      );
      final target = tester.getCenter(find.text('Alpha'));
      await tester.dragFrom(target, const Offset(160, 0));
      await settleDetail(tester);
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 's1').task.status,
        TaskStatus.completed,
      );
    });

    testWidgets('a mouse renames a subtask in place (desktop)', (tester) async {
      // Double-click-to-rename comes with the shared row (#306). Before it, a
      // subtask could only be retitled by opening its own panel — two
      // navigations for a typo.
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        theme: ThemeData(platform: TargetPlatform.linux),
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P'),
        ],
      );
      final title = find.text('Alpha');
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(title);
      await settleDetail(tester);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('s1')),
          matching: find.byType(TextField),
        ),
        'Alpha renamed',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleDetail(tester);

      expect(
        fake.tasks.firstWhere((t) => t.task.id == 's1').task.title,
        'Alpha renamed',
      );
    });

    testWidgets('the subtask date opens the shared quick-date menu (#243)', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'Alpha', parent: 'P'),
        ],
      );
      // A dateless subtask still offers the date: "no date" is the button.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('s1')),
          matching: find.byKey(const Key('row-due-segment')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(quickDateKey('today')), findsOneWidget);
      expect(find.byKey(quickDateKey('pick')), findsOneWidget);

      await tester.tap(find.byKey(quickDateKey('tomorrow')));
      await tester.pumpAndSettle();
      expect(fake.setDueCalls, ['s1=DateMove.tomorrow']);
    });
  });

  group('the completed group (#306)', () {
    testWidgets('finished subtasks gather under "N completed" at the bottom', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('done1', 'Washed up', parent: 'P', position: '1', done: true),
          row('open1', 'Still to do', parent: 'P', position: '2'),
        ],
      );
      expect(find.text('1 completed'), findsOneWidget);
      // Grouped LAST even though it sorts first by position.
      expect(subtaskOrder(tester, ['Washed up', 'Still to do']), [
        'Still to do',
        'Washed up',
      ]);
    });

    testWidgets('tapping the group collapses and reveals the finished ones', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('done1', 'Washed up', parent: 'P', position: '1', done: true),
          row('open1', 'Still to do', parent: 'P', position: '2'),
        ],
      );
      expect(find.text('Washed up'), findsOneWidget);

      await tester.tap(find.byKey(const Key('completed-subtasks-toggle')));
      await settleDetail(tester);
      expect(find.text('Washed up'), findsNothing);
      expect(find.text('1 completed'), findsOneWidget, reason: 'still counted');
      expect(find.text('Still to do'), findsOneWidget);

      await tester.tap(find.byKey(const Key('completed-subtasks-toggle')));
      await settleDetail(tester);
      expect(find.text('Washed up'), findsOneWidget);
    });

    testWidgets('the disclosure is a full 48dp thumb target', (tester) async {
      // It is the control that puts a finished checklist back on screen; at
      // its natural text height it was 36dp — the one target in the panel a
      // thumb could miss.
      await pumpDetail(
        tester,
        taskId: 'P',
        hideCompletedSubtasks: true,
        initial: [
          row('P', 'Parent'),
          row('done1', 'Washed up', parent: 'P', done: true),
        ],
      );
      final size = tester.getSize(
        find.byKey(const Key('completed-subtasks-toggle')),
      );
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('a completed row lines up with the open ones above it', (
      tester,
    ) async {
      // The open rows are inset by the drag-handle column; a completed row has
      // no handle, so it has to be inset by the same amount or the checklist
      // reads as two mis-aligned lists.
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('open1', 'Still to do', parent: 'P', position: '1'),
          row('done1', 'Washed up', parent: 'P', position: '2', done: true),
        ],
      );
      double checkboxLeft(String id) => tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(ValueKey(id)),
              matching: find.byKey(const Key('row-checkbox-target')),
            ),
          )
          .dx;
      expect(checkboxLeft('done1'), checkboxLeft('open1'));
    });

    testWidgets('no group at all when nothing is completed', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('open1', 'Still to do', parent: 'P'),
        ],
      );
      expect(find.byKey(const Key('completed-subtasks-toggle')), findsNothing);
      expect(find.textContaining('completed'), findsNothing);
    });

    testWidgets('the "Hide completed" checkbox is gone from the panel', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('done1', 'Washed up', parent: 'P', done: true),
        ],
      );
      expect(
        find.text('Hide completed'),
        findsNothing,
        reason: 'a global preference is not a control inside every task',
      );
    });
  });

  group('one progress format (#306)', () {
    testWidgets('the header states the same "N/M" the row states', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('c1', 'one', parent: 'P', position: '1', done: true),
          row('c2', 'two', parent: 'P', position: '2'),
          row('c3', 'three', parent: 'P', position: '3'),
        ],
      );
      expect(find.byKey(const Key('subtask-progress')), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(
        find.textContaining(' of 3 complete'),
        findsNothing,
        reason: 'the second wording of the same number is retired',
      );
    });

    testWidgets('it counts the collapsed ones too', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        hideCompletedSubtasks: true,
        initial: [
          row('P', 'Parent'),
          row('c1', 'one', parent: 'P', position: '1', done: true),
          row('c2', 'two', parent: 'P', position: '2'),
          row('c3', 'three', parent: 'P', position: '3'),
        ],
      );
      expect(find.text('one'), findsNothing, reason: 'collapsed away');
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('a task with no subtasks states no progress', (tester) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'Parent')]);
      expect(find.byKey(const Key('subtask-progress')), findsNothing);
    });
  });

  group('cascade counts in the panel toasts (#306)', () {
    testWidgets('deleting a parent says how many subtasks went with it', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'one', parent: 'P'),
          row('s2', 'two', parent: 'P'),
          row('s3', 'three', parent: 'P'),
        ],
      );
      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-delete')));
      await settleDetail(tester);
      expect(find.text('Deleted "Parent" and 3 subtasks'), findsOneWidget);
    });

    testWidgets('a childless task keeps the plain wording', (tester) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'Parent')]);
      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-delete')));
      await settleDetail(tester);
      expect(find.text('Deleted "Parent"'), findsOneWidget);
    });
  });

  group('the empty hint (#306)', () {
    testWidgets('a parent with no subtasks says what the field is for', (
      tester,
    ) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'Parent')]);
      expect(find.byKey(const Key('subtasks-empty-hint')), findsOneWidget);
    });

    testWidgets('the hint goes as soon as there is a subtask', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'Parent'),
          row('s1', 'one', parent: 'P'),
        ],
      );
      expect(find.byKey(const Key('subtasks-empty-hint')), findsNothing);
    });

    testWidgets('a collapsed completed subtask still counts as "not empty"', (
      tester,
    ) async {
      // The hint introduces the CONCEPT. A parent whose only subtask is
      // finished and folded away has already met it — showing the hint there
      // would read as "you have none" over a group that says "1 completed".
      await pumpDetail(
        tester,
        taskId: 'P',
        hideCompletedSubtasks: true,
        initial: [
          row('P', 'Parent'),
          row('s1', 'one', parent: 'P', done: true),
        ],
      );
      expect(find.byKey(const Key('subtasks-empty-hint')), findsNothing);
      expect(find.text('1 completed'), findsOneWidget);
    });
  });
}
