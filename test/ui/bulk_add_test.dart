// BulkAdd + PasteCreate bulk-split (MIGRATION-PLAN §5 T7.6). The global Ctrl+V
// paste dies with the desktop-web layer; the SURVIVING behavior — split
// multi-line text into one task per non-blank line, or the first line as a
// title with the rest as notes — is exercised here through the BulkAdd dialog's
// own entry point, both as pure units and end-to-end through the real
// [TaskListView] toolbar button.

import 'package:axiotask/src/ui/bulk_add.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list;
import 'list_harness.dart';

void main() {
  group('splitBulkLines / bulkAddCount (PasteCreate bulk-split)', () {
    test('a single line splits to exactly one task', () {
      expect(splitBulkLines('buy milk'), ['buy milk']);
    });

    test('multi-line splits to one task per non-blank line, trimmed', () {
      expect(splitBulkLines('  a \n\n b \n   \nc'), ['a', 'b', 'c']);
    });

    test(
      'empty or whitespace-only text yields nothing (no Untitled debris)',
      () {
        expect(splitBulkLines('   \n  \n'), isEmpty);
      },
    );

    test(
      'per-line count ignores blank lines; title-notes counts the title',
      () {
        expect(bulkAddCount('a\n\nb', BulkAddMode.perLine), 2);
        expect(bulkAddCount('title\nnote1\nnote2', BulkAddMode.titleNotes), 1);
        expect(bulkAddCount('   \n x', BulkAddMode.titleNotes), 0);
      },
    );
  });

  // The two lists let the dialog show its List selector; 'all' targets the
  // first (the reference's bulkTargetList).
  final lists = [list('L1', 'My Tasks'), list('L2', 'Errands')];

  Future<void> openBulkAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('bulk-add-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('defaults to one-task-per-line and shows a live count', (
    tester,
  ) async {
    await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    await tester.enterText(find.byKey(const Key('bulk-add-text')), 'a\nb\nc');
    await tester.pump();
    // Per-line is the default radio; the count reflects the three lines.
    expect(find.text('Creates 3 tasks'), findsOneWidget);
  });

  testWidgets('one-task-per-line creates a task for each non-empty line', (
    tester,
  ) async {
    final fake = await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    await tester.enterText(
      find.byKey(const Key('bulk-add-text')),
      'apples\n\noranges\npears',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-add-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final titles = fake.tasks.map((t) => t.task.title).toSet();
    expect(titles, containsAll(['apples', 'oranges', 'pears']));
    expect(fake.tasks.length, 3, reason: 'blank line created nothing');
  });

  testWidgets('first-line-title mode creates one task with the rest as notes', (
    tester,
  ) async {
    final fake = await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    await tester.enterText(
      find.byKey(const Key('bulk-add-text')),
      'Groceries\nmilk\neggs',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-add-mode-title-notes')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-add-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(fake.tasks.length, 1);
    expect(fake.tasks.single.task.title, 'Groceries');
    expect(fake.tasks.single.task.notes, 'milk\neggs');
  });

  testWidgets('shows a confirmation toast naming the count after creating', (
    tester,
  ) async {
    await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    await tester.enterText(find.byKey(const Key('bulk-add-text')), 'x\ny');
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-add-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Added 2 tasks'), findsOneWidget);
  });

  testWidgets('Cancel closes the dialog without creating anything', (
    tester,
  ) async {
    final fake = await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    await tester.enterText(find.byKey(const Key('bulk-add-text')), 'ghost');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(fake.tasks, isEmpty);
    expect(find.byType(BulkAddDialog), findsNothing);
    expect(find.byType(TaskRow), findsNothing);
  });

  testWidgets('Add is disabled when there is nothing to add', (tester) async {
    await pumpList(tester, initial: const [], lists: lists);
    await openBulkAdd(tester);
    // Empty textarea → "Nothing to add" and a disabled Add button.
    expect(find.text('Nothing to add'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('bulk-add-submit')),
    );
    expect(button.onPressed, isNull);
  });
}
