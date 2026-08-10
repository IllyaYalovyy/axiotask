// Reschedule + reveal-WITHOUT-REFLOW geometry (#168, MIGRATION-PLAN §5 T7.2).
//
// The desktop quick-date strip is revealed by mouse hover and reschedules the
// task in one gesture. The #168 regression it guards: because the action
// buttons are taller than the title line, toggling them in and out of the
// layout flow used to grow the row on hover and make it jump. The strip must be
// lifted out of flow so the row's height is IDENTICAL hovered or not — the
// geometry assertion below is exactly that check.

import 'package:axiotask/src/model/dates.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    String? due,
    ValueChanged<DateMove>? onSetDue,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // A bounded width so the row lays out like a real list item.
          body: SizedBox(
            width: 500,
            child: TaskRow(
              key: const Key('row'),
              title: 'buy milk',
              completed: false,
              due: due,
              onOpen: () {},
              onToggle: () {},
              onRename: (_) {},
              onSetDue: onSetDue,
            ),
          ),
        ),
      ),
    );
  }

  /// Move a mouse pointer onto the row's centre and settle the hover state.
  Future<TestGesture> hoverRow(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byKey(const Key('row'))));
    await tester.pump();
    return gesture;
  }

  testWidgets('the quick-date strip is hidden until hover, then revealed', (
    tester,
  ) async {
    await pumpRow(tester, onSetDue: (_) {});
    // Hidden without a pointer over the row.
    expect(find.byKey(const Key('quick-date-today')), findsNothing);

    await hoverRow(tester);
    expect(find.byKey(const Key('quick-date-today')), findsOneWidget);
    expect(find.byKey(const Key('quick-date-tomorrow')), findsOneWidget);
    expect(find.byKey(const Key('quick-date-week')), findsOneWidget);
    expect(find.byKey(const Key('quick-date-month')), findsOneWidget);
  });

  testWidgets('revealing the strip does NOT change the row height (#168)', (
    tester,
  ) async {
    await pumpRow(tester, onSetDue: (_) {});
    final before = tester.getSize(find.byKey(const Key('row')));

    await hoverRow(tester);
    // The strip is now visible…
    expect(find.byKey(const Key('quick-date-today')), findsOneWidget);
    // …and the row is byte-for-byte the same size (no reflow).
    final after = tester.getSize(find.byKey(const Key('row')));
    expect(after, before, reason: 'hover must not reflow the row (#168)');
  });

  testWidgets('each quick-date button fires the matching DateMove', (
    tester,
  ) async {
    final moves = <DateMove>[];
    await pumpRow(tester, due: '2026-06-15', onSetDue: moves.add);
    await hoverRow(tester);

    await tester.tap(find.byKey(const Key('quick-date-today')));
    await tester.tap(find.byKey(const Key('quick-date-tomorrow')));
    await tester.tap(find.byKey(const Key('quick-date-week')));
    await tester.tap(find.byKey(const Key('quick-date-month')));
    await tester.pump();

    expect(moves, [
      DateMove.today,
      DateMove.tomorrow,
      DateMove.nextWeek,
      DateMove.nextMonth,
    ]);
  });

  testWidgets('an undated task shows no clear button', (tester) async {
    await pumpRow(tester, onSetDue: (_) {});
    await hoverRow(tester);
    expect(find.byKey(const Key('quick-date-clear')), findsNothing);
  });

  testWidgets('a dated task shows a clear button that fires DateMove.clear', (
    tester,
  ) async {
    final moves = <DateMove>[];
    await pumpRow(tester, due: '2026-06-15', onSetDue: moves.add);
    await hoverRow(tester);
    expect(find.byKey(const Key('quick-date-clear')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick-date-clear')));
    await tester.pump();
    expect(moves, [DateMove.clear]);
  });

  testWidgets('no strip is rendered when onSetDue is not wired', (
    tester,
  ) async {
    await pumpRow(tester, onSetDue: null);
    await hoverRow(tester);
    expect(find.byKey(const Key('quick-date-today')), findsNothing);
  });
}
