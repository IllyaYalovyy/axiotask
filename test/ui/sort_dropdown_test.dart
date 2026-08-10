// The sort dropdown's contract: it shows the current order as "Sort: <label>",
// opens a menu of all four modes, and reports the picked one. Presentational, so
// these WIDGET tests drive the real menu and assert what renders / the value a
// tap reports.

import 'package:axiotask/src/model/task_view.dart';
import 'package:axiotask/src/ui/sort_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<SortMode?> pump(WidgetTester tester, SortMode value) async {
    SortMode? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SortDropdown(value: value, onChanged: (m) => picked = m),
          ),
        ),
      ),
    );
    return picked;
  }

  testWidgets('shows the current order label', (tester) async {
    await pump(tester, SortMode.manual);
    expect(find.text('Sort: My order'), findsOneWidget);
    await pump(tester, SortMode.due);
    expect(find.text('Sort: Due date'), findsOneWidget);
  });

  testWidgets('opens a menu of every mode and reports the picked one', (
    tester,
  ) async {
    SortMode? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SortDropdown(
              value: SortMode.manual,
              onChanged: (m) => picked = m,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('sort-dropdown')));
    await tester.pumpAndSettle();
    // The menu offers all four orders…
    for (final m in SortMode.values) {
      expect(find.text(m.label), findsWidgets);
    }
    // …and selecting one reports it and closes the menu.
    await tester.tap(find.text('Alphabetical').last);
    await tester.pumpAndSettle();
    expect(picked, SortMode.alpha);
  });
}
