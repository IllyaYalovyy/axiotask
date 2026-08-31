// The detail panel's overflow actions (#245). The per-row "⋮" action sheet is
// gone, so the two functions that had NO other home — Duplicate and "Make
// subtask of…" (the #88 parent picker) — live here, on the screen a row tap
// already opens. Every assertion is about what the panel OFFERS and what the
// mutating [FakeBackend] HOLDS afterwards, never that a command merely fired.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];

  /// Open the detail app bar's overflow menu.
  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('detail-overflow')));
    await settleDetail(tester);
  }

  group('Duplicate (detail overflow)', () {
    testWidgets('creates a "(copy)" in the same list, under the same parent', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'A',
        initial: [row('A', 'apples')],
        lists: oneList,
        newId: () => 'copy-1',
      );

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-duplicate')));
      await settleDetail(tester);

      final copy = fake.tasks.firstWhere((t) => t.task.id == 'copy-1');
      expect(copy.task.title, 'apples (copy)');
      expect(copy.listId, 'L1');
      expect(copy.task.parent, isNull);
    });

    testWidgets('duplicating a SUBTASK keeps it under the same parent', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
        ],
        lists: oneList,
        newId: () => 'copy-2',
      );

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-duplicate')));
      await settleDetail(tester);

      final copy = fake.tasks.firstWhere((t) => t.task.id == 'copy-2');
      expect(copy.task.title, 'sub (copy)');
      expect(
        copy.task.parent,
        'P',
        reason: 'a duplicated subtask stays a subtask of the same parent',
      );
    });

    testWidgets('a title typed but not blurred is duplicated as typed', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'A',
        initial: [row('A', 'apples')],
        lists: oneList,
        newId: () => 'copy-3',
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'apples'),
        'apricots',
      );
      await tester.pump();
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-duplicate')));
      await settleDetail(tester);

      expect(
        fake.tasks.firstWhere((t) => t.task.id == 'copy-3').task.title,
        'apricots (copy)',
        reason: 'the overflow flushes the open edit before copying',
      );
    });
  });

  group('the overflow on a phone', () {
    testWidgets('stays tappable on a 400dp phone at 1.3x text, beside the '
        'delete and prev/next actions', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'A',
        initial: [
          row('A', 'a title long enough to crowd the whole app bar', due: null),
          row('B', 'bread'),
        ],
        lists: oneList,
        size: const Size(400, 900),
        textScale: 1.3,
      );

      expect(tester.takeException(), isNull);
      final overflow = find.byKey(const Key('detail-overflow'));
      expect(overflow.hitTestable(), findsOneWidget);
      // A finger-sized target, not a squeezed glyph.
      expect(tester.getRect(overflow).width, greaterThanOrEqualTo(40));
      expect(tester.getRect(overflow).height, greaterThanOrEqualTo(40));

      await openOverflow(tester);
      expect(find.byKey(const Key('detail-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('detail-demote')), findsOneWidget);
    });
  });

  group('Make subtask of… (detail overflow, #88)', () {
    testWidgets('nests the task under the parent chosen in the picker', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'A',
        initial: [row('A', 'apples'), row('B', 'bread')],
        lists: oneList,
      );

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-demote')));
      await settleDetail(tester);
      // The #88 picker offers the other childless top-level task, not itself.
      expect(find.byKey(const Key('parent-picker-B')), findsOneWidget);
      expect(find.byKey(const Key('parent-picker-A')), findsNothing);

      await tester.tap(find.byKey(const Key('parent-picker-B')));
      await settleDetail(tester);

      expect(fake.tasks.firstWhere((t) => t.task.id == 'A').task.parent, 'B');
    });

    testWidgets('is NOT offered for a task that already has subtasks', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('B', 'bread'),
        ],
        lists: oneList,
      );

      await openOverflow(tester);
      expect(find.byKey(const Key('detail-demote')), findsNothing);
      expect(
        find.byKey(const Key('detail-duplicate')),
        findsOneWidget,
        reason: 'Duplicate is always offered — only demotion is gated',
      );
    });

    testWidgets('is NOT offered when no other top-level task can host it', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'A',
        initial: [row('A', 'apples')],
        lists: oneList,
      );

      await openOverflow(tester);
      expect(find.byKey(const Key('detail-demote')), findsNothing);
    });

    testWidgets('is NOT offered for a subtask (it detaches first)', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
          row('B', 'bread'),
        ],
        lists: oneList,
      );

      await openOverflow(tester);
      expect(find.byKey(const Key('detail-demote')), findsNothing);
    });

    testWidgets('a host that already has subtasks is still offered — the '
        'two-level rule caps the CHILD, not the parent', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'A',
        initial: [
          row('A', 'apples'),
          row('P', 'parent'),
          row('S', 'sub', parent: 'P'),
        ],
        lists: oneList,
      );

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('detail-demote')));
      await settleDetail(tester);
      await tester.tap(find.byKey(const Key('parent-picker-P')));
      await settleDetail(tester);

      expect(fake.tasks.firstWhere((t) => t.task.id == 'A').task.parent, 'P');
    });

    testWidgets('never offers a parent from ANOTHER list', (tester) async {
      await pumpDetail(
        tester,
        taskId: 'A',
        initial: [
          row('A', 'apples'),
          row('X', 'elsewhere', listId: 'L2'),
        ],
        lists: [list('L1', 'My Tasks'), list('L2', 'Errands')],
      );

      await openOverflow(tester);
      expect(find.byKey(const Key('detail-demote')), findsNothing);
    });
  });
}
