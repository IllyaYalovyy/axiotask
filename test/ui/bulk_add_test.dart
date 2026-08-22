// BulkAdd + PasteCreate bulk-split (MIGRATION-PLAN §5 T7.6). The global Ctrl+V
// paste dies with the desktop-web layer; the SURVIVING behavior — split
// multi-line text into one task per non-blank line, or the first line as a
// title with the rest as notes — is exercised here through the BulkAdd dialog's
// own entry point, both as pure units and end-to-end through the real
// [TaskListView] toolbar button.

import 'package:axiotask/src/ui/bulk_add.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:clock/clock.dart';
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

    test('a pasted multi-line clipboard collapses to one readable draft', () {
      // A single-line field DELETES newlines outright, so without this the
      // fallback draft reads "buy milkcall bob" (#219).
      expect(collapsePastedLines('buy milk\ncall bob'), 'buy milk call bob');
      expect(collapsePastedLines('  a \n\n b \n   \nc'), 'a b c');
    });

    test('a single-line paste is inserted verbatim, never re-trimmed', () {
      // Splicing an ordinary fragment into a draft must insert exactly what was
      // copied — the collapse only ever removes a line BREAK.
      expect(collapsePastedLines(' buy milk '), ' buy milk ');
    });

    test('the split is offered only for a LIST pasted into an empty draft', () {
      expect(offersBulkSplit(draft: '', raw: 'a\nb'), isTrue);
      expect(offersBulkSplit(draft: '   ', raw: 'a\nb'), isTrue);
      // One real line is one task — nothing to offer.
      expect(offersBulkSplit(draft: '', raw: 'a\n\n  '), isFalse);
      expect(offersBulkSplit(draft: '', raw: 'buy milk'), isFalse);
      // Spliced into a half-typed title, the lines are not a standalone list.
      expect(offersBulkSplit(draft: 'today: ', raw: 'a\nb'), isFalse);
    });

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

  testWidgets('each line\'s trailing natural-language date becomes that '
      'task\'s due', (tester) async {
    // One split, one rule (#219): the per-line create reads a trailing date
    // exactly as the quick-add bar does — title verbatim, only the due parsed —
    // so a pasted "call bob tomorrow" is not filed as unscheduled.
    final fake = await pumpList(tester, initial: const [], lists: lists);
    // The fixed harness clock resolves "tomorrow" — never the wall clock. The
    // dialog is OPENED inside the zone too: the create runs in the awaiting
    // continuation of that tap, which carries the zone it started in.
    await withClock(testClock, () async {
      await openBulkAdd(tester);
      await tester.enterText(
        find.byKey(const Key('bulk-add-text')),
        'call bob tomorrow\nbuy milk',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-add-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    });

    final byTitle = {for (final t in fake.tasks) t.task.title: t.task.due};
    expect(byTitle['call bob tomorrow'], '2026-06-16T00:00:00.000Z');
    expect(byTitle['buy milk'], isNull);
    // Mixed dates scatter across views, so the toast claims no single landing
    // place — just the honest count.
    expect(find.text('Added 2 tasks'), findsOneWidget);
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

  testWidgets(
    'landing (#190): bulk-add from a dated view names Unscheduled (undated rows)',
    (tester) async {
      // Missed is a dated smart view; bulk-added rows are always undated, so
      // they land in Unscheduled — invisible to Missed. The toast must say so.
      await pumpList(tester, initial: const [], lists: lists, viewId: 'missed');
      await openBulkAdd(tester);
      await tester.enterText(find.byKey(const Key('bulk-add-text')), 'x\ny');
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-add-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Added 2 tasks to Unscheduled'), findsOneWidget);
    },
  );

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
