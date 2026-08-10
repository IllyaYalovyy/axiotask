// Protects the friendly due-date formatter (port of dateFormat.js formatDue):
// relative labels near today, an absolute "Mon D" further out, a year only when
// it differs, and NEVER the raw ISO string (#78b — the quick-add preview chip
// depends on this). Clock-driven so "today" is deterministic; local-date
// parsing so negative-UTC zones don't shift the day (#76).

import 'package:axiotask/src/ui/date_format.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String fmt(String? due, DateTime now) =>
      withClock(Clock.fixed(now), () => formatDue(due));

  final now = DateTime(2026, 6, 15); // a fixed "today"

  group('formatDue', () {
    test('empty/null renders as empty', () {
      expect(fmt(null, now), '');
      expect(fmt('', now), '');
    });

    test('relative labels around today', () {
      expect(fmt('2026-06-15', now), 'today');
      expect(fmt('2026-06-16', now), 'tomorrow');
      expect(fmt('2026-06-14', now), 'yesterday');
      expect(fmt('2026-06-18', now), 'in 3d');
      expect(fmt('2026-06-12', now), '3d overdue');
    });

    test('a week or more out is an absolute short date', () {
      // +7 is not "in 7d" — it crosses into the absolute format.
      expect(fmt('2026-06-22', now), 'Jun 22');
    });

    test('shows the year only when it differs from the current one', () {
      expect(fmt('2027-03-10', now), 'Mar 10, 2027');
    });

    test('never returns the raw ISO string (#78b)', () {
      final full = '2026-06-22T00:00:00.000Z';
      final out = fmt(full, now);
      expect(out, isNot(contains('T00:00')));
      expect(out, 'Jun 22');
    });
  });

  group('dueUrgency', () {
    DueUrgency urgency(String? due) =>
        withClock(Clock.fixed(now), () => dueUrgency(due));

    test('a past date is overdue', () {
      expect(urgency('2026-06-14'), DueUrgency.overdue);
      expect(urgency('2026-06-01'), DueUrgency.overdue);
    });

    test('today is due-today', () {
      expect(urgency('2026-06-15'), DueUrgency.today);
    });

    test('a future date and no date are neither', () {
      expect(urgency('2026-06-16'), DueUrgency.none);
      expect(urgency('2027-01-01'), DueUrgency.none);
      expect(urgency(null), DueUrgency.none);
      expect(urgency(''), DueUrgency.none);
    });
  });
}
