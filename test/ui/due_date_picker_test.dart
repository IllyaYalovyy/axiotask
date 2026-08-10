// DatePicker (MIGRATION-PLAN §5 T7.3). The Material date-picker wrapper the due
// badge / "no date" tap opens: it must open on the CURRENT value's month, emit a
// LOCAL `YYYY-MM-DD` (never a UTC-shifted day, #76), offer Today and Clear, and
// cancel to null. Plus [dueCascadeMessage] — the pure #164 toast wording that the
// DueConsistency surface renders.
//
// Every assertion reads the value the picker actually returns / the string the
// message function produces — never "a method was called".

import 'package:axiotask/src/app/commands.dart' show DueUndoEntry, SetDueResult;
import 'package:axiotask/src/ui/due_date_picker.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed clock so "Today" and the default (undated) month are deterministic.
  final clockAt = Clock.fixed(DateTime(2026, 6, 15, 9));

  /// Pump a button that opens the picker and records its result, then tap it.
  Future<List<DuePick?>> openPicker(
    WidgetTester tester, {
    String? initial,
  }) async {
    final results = <DuePick?>[];
    await withClock(clockAt, () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async => results.add(
                  await showDueDatePicker(context, initial: initial),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    });
    return results;
  }

  group('showDueDatePicker', () {
    testWidgets('opens on the current value month', (tester) async {
      await openPicker(tester, initial: '2026-09-15T00:00:00.000Z');
      // The calendar header names the value's month, not today's (June).
      expect(find.textContaining('September 2026'), findsOneWidget);
      expect(find.textContaining('June'), findsNothing);
    });

    testWidgets('an undated value opens on today\'s month', (tester) async {
      await openPicker(tester); // no initial → clock is June 2026
      expect(find.textContaining('June 2026'), findsOneWidget);
    });

    testWidgets('tapping a day returns that LOCAL date as YYYY-MM-DD', (
      tester,
    ) async {
      final results = await openPicker(tester, initial: '2026-09-15');
      // Tap the 20th of the shown month.
      await tester.tap(find.text('20'));
      await tester.pumpAndSettle();
      expect(results, [const DuePickDate('2026-09-20')]);
    });

    testWidgets('Today returns today from the ambient clock', (tester) async {
      final results = await openPicker(tester, initial: '2026-09-15');
      await tester.tap(find.byKey(const Key('due-picker-today')));
      await tester.pumpAndSettle();
      expect(results, [const DuePickDate('2026-06-15')]);
    });

    testWidgets('Clear returns a clear result', (tester) async {
      final results = await openPicker(tester, initial: '2026-09-15');
      await tester.tap(find.byKey(const Key('due-picker-clear')));
      await tester.pumpAndSettle();
      expect(results, [isA<DuePickClear>()]);
    });

    testWidgets('Cancel dismisses with null (non-happy path)', (tester) async {
      final results = await openPicker(tester, initial: '2026-09-15');
      await tester.tap(find.byKey(const Key('due-picker-cancel')));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  });

  group('dueCascadeMessage (#164 toast wording)', () {
    SetDueResult res({required int cascaded, required bool parent}) =>
        SetDueResult(
          undo: [const DueUndoEntry(id: 'P')],
          cascaded: cascaded,
          cascadedParent: parent,
        );

    test('no cascade → no message', () {
      expect(dueCascadeMessage(res(cascaded: 0, parent: false)), isNull);
    });

    test('a pulled-down parent phrases the parent case', () {
      expect(
        dueCascadeMessage(res(cascaded: 1, parent: true)),
        'Parent date moved to match',
      );
    });

    test('one pulled-up child is singular', () {
      expect(
        dueCascadeMessage(res(cascaded: 1, parent: false)),
        '1 subtask date moved to match',
      );
    });

    test('several pulled-up children are plural', () {
      expect(
        dueCascadeMessage(res(cascaded: 3, parent: false)),
        '3 subtask dates moved to match',
      );
    });
  });
}
