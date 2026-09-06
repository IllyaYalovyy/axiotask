// Getting TO the export (#297) — the entry point on the list's own chrome.
//
// The sheet itself is covered by export_sheet_test; what is pinned here is that
// a user can actually reach it from a view, on BOTH pointer classes:
//
//   • on a mouse platform the list pane's toolbar had no overflow at all (its
//     only entry, "Select tasks", is coarse-pointer-only), so an entry added
//     "to the overflow" would have rendered nowhere on the desktop — the
//     failure this test exists to prevent;
//   • and the export must be aimed at the VIEW the user is looking at, named
//     in the sheet, not at some other list.

import 'package:axiotask/src/ui/list_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'detail_harness.dart' show list, row;
import 'list_harness.dart';

void main() {
  final overflow = find.byKey(const Key('toolbar-overflow'));

  testWidgets('the desktop toolbar carries Export view… and opens the sheet '
      'for the current view', (tester) async {
    await pumpList(
      tester,
      initial: [row('T1', 'Buy milk')],
      lists: [list('L1', 'Groceries')],
      viewId: 'L1',
      platform: TargetPlatform.linux,
    );

    expect(
      find.descendant(of: find.byType(ListToolbar), matching: overflow),
      findsOneWidget,
      reason: 'a mouse needs the overflow too — it holds the only export entry',
    );

    await tester.tap(overflow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export view…'));
    await tester.pumpAndSettle();

    expect(find.text('Export Groceries'), findsOneWidget);
    expect(find.byKey(const Key('export-copy')), findsOneWidget);
  });

  testWidgets('a smart view exports under its own name', (tester) async {
    await pumpList(
      tester,
      initial: [row('T1', 'Buy milk')],
      lists: [list('L1', 'Groceries')],
      viewId: 'unscheduled',
      platform: TargetPlatform.linux,
    );

    await tester.tap(overflow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export view…'));
    await tester.pumpAndSettle();

    expect(find.text('Export Unscheduled'), findsOneWidget);
  });
}
