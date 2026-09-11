// DetailWorkflow suite — the panel's cross-task workflows: prev/next sibling
// navigation (flushing edits first), detach (#promoteTask), the empty-subtask
// discard-on-close rule (kept when it has children), the List move repoint
// (#93), and the parent breadcrumb. Assertions are on the USER-VISIBLE result
// and what the [FakeCommands] holds afterwards.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  group('prev/next navigation', () {
    testWidgets('the nav buttons are disabled when no sibling is wired', (
      tester,
    ) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'lone')]);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_left),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_right),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('tapping Next fires the callback', (tester) async {
      var next = 0;
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'first')],
        onNext: () => next++,
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await settleDetail(tester);
      expect(next, 1);
    });

    testWidgets('navigating flushes title and notes before reopening', (
      tester,
    ) async {
      final fake = FakeCommands([row('P', 'first')]);
      addTearDown(fake.dispose);
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'first')],
        onNext: () {},
        commands: fake,
      );
      // Type into both fields but do NOT blur — then navigate away.
      await tester.enterText(
        find.widgetWithText(TextField, 'first'),
        'edited first',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Notes'),
        'edited notes',
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await settleDetail(tester);
      // The in-progress edits survived navigation in the persisted command
      // state; opening the detail again is what the user sees afterward.
      expect(fake.tasks.single.task.title, 'edited first');
      expect(fake.tasks.single.task.notes, 'edited notes');

      await pumpDetail(
        tester,
        taskId: 'P',
        initial: fake.tasks,
        commands: fake,
      );
      expect(find.widgetWithText(TextField, 'edited first'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'edited notes'), findsOneWidget);
    });
  });

  group('detach (#promoteTask)', () {
    testWidgets('a subtask panel detaches to top level after its former parent', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'Parent'),
          row('S', 'Nested Child', parent: 'P'),
        ],
      );
      await openDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-detach')));
      await settleDetail(tester);

      expect(fake.movedTasks, ['S:parent=null:prev=P']);
      // The row is now top-level and the panel (same id) shows its affordances.
      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'S').task.parent,
        isNull,
      );
    });

    testWidgets('a top-level task offers no detach affordance', (tester) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'top')]);
      await openDetailOverflow(tester);
      expect(find.byKey(const Key('detail-detach')), findsNothing);
      expect(find.text('Detach from parent'), findsNothing);
    });
  });

  group('empty-subtask discard on close', () {
    testWidgets(
      'closing an untitled, childless subtask left untouched discards it',
      (tester) async {
        final closed = <String>[];
        final fake = await pumpDetail(
          tester,
          taskId: 'S',
          initial: [
            row('P', 'Parent'),
            row('S', '', parent: 'P'),
          ],
          closed: closed,
        );
        await tester.tap(find.byTooltip('Back'));
        await settleDetail(tester);
        expect(fake.deleted.map((t) => t.id), ['S']);
        expect(closed, ['close']);
      },
    );

    testWidgets(
      'NEVER discards an untitled subtask that has children of its own',
      (tester) async {
        // Deleting it would cascade the whole subtree away, with no undo.
        final fake = await pumpDetail(
          tester,
          taskId: 'mid',
          initial: [
            row('P', 'Parent'),
            row('mid', '', parent: 'P'),
            row('leaf', 'Grandchild work', parent: 'mid'),
          ],
        );
        await tester.tap(find.byTooltip('Back'));
        await settleDetail(tester);
        expect(fake.deleted, isEmpty);
      },
    );

    testWidgets('a titled subtask is kept on close', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'Parent'),
          row('S', 'has a name', parent: 'P'),
        ],
      );
      await tester.tap(find.byTooltip('Back'));
      await settleDetail(tester);
      expect(fake.deleted, isEmpty);
    });

    testWidgets('a top-level empty task is NOT auto-discarded', (tester) async {
      // The rule is subtask-only — a blank top-level task the user opened and
      // closed is theirs to keep.
      final fake = await pumpDetail(
        tester,
        taskId: 'T',
        initial: [row('T', '')],
      );
      await tester.tap(find.byTooltip('Back'));
      await settleDetail(tester);
      expect(fake.deleted, isEmpty);
    });
  });

  group('List move repoints the panel (#93)', () {
    testWidgets(
      'changing the list moves the task and follows it to the new id',
      (tester) async {
        final opened = <String>[];
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [row('P', 'Move me', listId: 'L1')],
          lists: [list('L1', 'Work'), list('L2', 'Personal')],
          opened: opened,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Move me'),
          'Moved with title',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Notes'),
          'Moved with notes',
        );
        await tester.tap(find.byKey(const Key('list-dropdown')));
        await tester.pumpAndSettle();
        // Bounded from here on: the move raises an Undo toast, and since #258
        // that toast draws a 30-second countdown — pumpAndSettle would run its
        // whole life out and settle on a screen the toast has already left.
        await tester.tap(find.text('Personal').last);
        await settleDetail(tester);

        expect(fake.movedToList, ['P->L2']);
        // A confirmation toast names the destination (the row otherwise just
        // vanishes from the current view).
        expect(find.text('Moved to Personal'), findsOneWidget);
        // moveTaskToList recreates under a fresh id; the panel follows it.
        expect(opened, ['P-moved']);
        final moved = fake.tasks.firstWhere((t) => t.task.id == 'P-moved');
        expect(moved.listId, 'L2');
        expect(moved.task.title, 'Moved with title');
        expect(moved.task.notes, 'Moved with notes');
      },
    );

    testWidgets(
      'the move toast Undo restores the task and repoints the panel (F11)',
      (tester) async {
        final opened = <String>[];
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [row('P', 'Move me', listId: 'L1')],
          lists: [list('L1', 'Work'), list('L2', 'Personal')],
          opened: opened,
        );
        await tester.tap(find.byKey(const Key('list-dropdown')));
        await tester.pumpAndSettle();
        // Bounded: see the sibling test — the undo toast's #258 countdown never
        // lets pumpAndSettle idle before the toast has lapsed.
        await tester.tap(find.text('Personal').last);
        await settleDetail(tester);
        expect(fake.movedToList, ['P->L2']);
        expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);

        await tester.tap(find.text('Undo'));
        await settleDetail(tester);
        // The clone is gone and the original 'P' is back in its source list…
        expect(fake.tasks.any((t) => t.task.id == 'P-moved'), isFalse);
        final restored = fake.tasks.firstWhere((t) => t.task.id == 'P');
        expect(restored.listId, 'L1');
        // …and the panel was repointed onto the restored original (not the clone).
        expect(opened, ['P-moved', 'P']);
      },
    );
  });

  group('parent breadcrumb', () {
    testWidgets('the breadcrumb opens the parent task', (tester) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'Parent'),
          row('S', 'Child', parent: 'P'),
        ],
        opened: opened,
      );
      // The breadcrumb shows the parent's title as a back affordance.
      await tester.tap(find.widgetWithText(TextButton, 'Parent'));
      await settleDetail(tester);
      expect(opened, ['P']);
    });
  });
}
