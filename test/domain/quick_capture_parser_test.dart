import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/quick_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = TaskDate(2026, 8, 16);

  group('PAR-CAPTURE-002 terminal date grammar', () {
    for (final value in <(String, String, TaskDate)>[
      ('Send invoice today', 'Send invoice', TaskDate(2026, 8, 16)),
      ('Send invoice due TODAY', 'Send invoice', TaskDate(2026, 8, 16)),
      ('Call tomorrow', 'Call', TaskDate(2026, 8, 17)),
      ('Plan next week', 'Plan', TaskDate(2026, 8, 23)),
      ('Review next month', 'Review', TaskDate(2026, 9, 16)),
      ('Book on 2026-08-31', 'Book', TaskDate(2026, 8, 31)),
      ('Book 2028-02-29', 'Book', TaskDate(2028, 2, 29)),
    ]) {
      test('parses ${value.$1}', () {
        expect(
          parseQuickCapture(value.$1, today: today),
          QuickCaptureParseResult(
            rawTitle: value.$1,
            title: value.$2,
            due: value.$3,
          ),
        );
      });
    }

    test('clamps next month at month and year boundaries', () {
      expect(
        parseQuickCapture(
          'Close books next month',
          today: TaskDate(2027, 1, 31),
        ).due,
        TaskDate(2027, 2, 28),
      );
      expect(
        parseQuickCapture(
          'Close books next month',
          today: TaskDate(2026, 12, 31),
        ).due,
        TaskDate(2027, 1, 31),
      );
    });

    for (final ambiguous in <String>[
      'Tomorrow call the team',
      'Discuss today notes',
      'Plan next week maybe',
      'Book 08/31/2026',
      'Book Aug 31',
      'Book 2026-02-29',
      'today',
      '2026-08-31',
      'Retoday',
      'Plan next  week',
    ]) {
      test('leaves ambiguous text literal: $ambiguous', () {
        final result = parseQuickCapture(ambiguous, today: today);
        expect(result.title, ambiguous.trim());
        expect(result.due, isNull);
      });
    }
  });
}
