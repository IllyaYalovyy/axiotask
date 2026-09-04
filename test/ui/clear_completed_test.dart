// ClearCompleted (MIGRATION-PLAN §5 T7.7). The "Clear completed" action lives in
// the list toolbar and is deliberately gated: it only appears on a concrete list
// view AND only while Show-completed is on (you cannot bulk-delete what you
// cannot see). Deletion is destructive and NOT undoable, so it goes behind a
// styled confirm naming the count. These tests drive the real [TaskListView]
// over the mutating [FakeCommands] and assert what RENDERS and what the fake
// HOLDS afterward — never that a method merely fired.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show FakeCommands, list, row;
import 'list_harness.dart';

void main() {
  final oneList = [list('L1', 'My Tasks')];
  final seed = [
    row('A', 'apples'),
    row('D1', 'done one', done: true),
    row('D2', 'done two', done: true),
  ];

  Finder clearButton() => find.byKey(const Key('clear-completed-button'));

  group('visibility', () {
    testWidgets('hidden when showCompleted is off (even on a list)', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: seed,
        lists: oneList,
        viewId: 'L1',
        showCompleted: false,
      );
      expect(clearButton(), findsNothing);
    });

    testWidgets('appears when showCompleted is on and viewing a list', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: seed,
        lists: oneList,
        viewId: 'L1',
        showCompleted: true,
      );
      expect(clearButton(), findsOneWidget);
    });

    testWidgets('hidden on a smart view even with showCompleted on', (
      tester,
    ) async {
      await pumpList(
        tester,
        initial: seed,
        lists: oneList,
        viewId: 'all',
        showCompleted: true,
      );
      expect(clearButton(), findsNothing);
    });
  });

  group('confirm flow', () {
    Future<FakeCommands> pump(WidgetTester tester) => pumpList(
      tester,
      initial: seed,
      lists: oneList,
      viewId: 'L1',
      showCompleted: true,
    );

    testWidgets('clicking Clear completed shows a confirm naming the count', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(clearButton());
      await tester.pumpAndSettle();

      // Styled confirm, count in the message, and a destructive-safe "Delete".
      expect(find.text('Clear completed'), findsWidgets);
      expect(
        find.text('Delete 2 completed tasks? This cannot be undone.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('clear-completed-confirm-button')),
        findsOneWidget,
      );
    });

    testWidgets('canceling the confirm deletes nothing', (tester) async {
      final fake = await pump(tester);
      await tester.tap(clearButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fake.clearedLists, isEmpty);
      expect(find.text('done one'), findsOneWidget);
      expect(find.text('done two'), findsOneWidget);
    });

    testWidgets('confirming deletes the completed tasks from the list', (
      tester,
    ) async {
      final fake = await pump(tester);
      await tester.tap(clearButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-completed-confirm-button')));
      await tester.pumpAndSettle();

      expect(fake.clearedLists, ['L1']);
      expect(find.text('done one'), findsNothing);
      expect(find.text('done two'), findsNothing);
      expect(find.text('apples'), findsOneWidget, reason: 'open task survives');
    });
  });
}
