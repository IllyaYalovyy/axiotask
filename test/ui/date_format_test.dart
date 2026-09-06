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

  /// The label the badge SHOWS for [due] — what the spoken form must agree
  /// with wherever it does not respell anything.
  String visible(String due) => fmt(due, now);

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

  group('formatDueSpoken (#289)', () {
    String spoken(String? due) =>
        withClock(Clock.fixed(now), () => formatDueSpoken(due));

    test('an undated task has no date to say', () {
      // The caller words "No due date" itself — an empty phrase here would
      // otherwise be spliced into a sentence as a silent gap.
      expect(spoken(null), '');
      expect(spoken(''), '');
    });

    test('the badge glyphs become words', () {
      // "5d" / "in 3d" are written for the eye; a screen reader says the
      // letter. Everything a badge abbreviates is spelled out.
      expect(spoken('2026-06-10'), '5 days ago');
      expect(spoken('2026-06-13'), '2 days ago');
      expect(spoken('2026-06-18'), 'in 3 days');
    });

    test('the one-day words are already words', () {
      expect(spoken('2026-06-14'), 'yesterday');
      expect(spoken('2026-06-15'), 'today');
      expect(spoken('2026-06-16'), 'tomorrow');
    });

    test('a week or more out IS the visible absolute date', () {
      // Past the relative window there is nothing to respell, so the spoken
      // and visible labels must not drift apart.
      expect(spoken('2026-06-22'), visible('2026-06-22'));
      expect(spoken('2026-06-22'), 'Jun 22');
      expect(spoken('2027-03-10'), 'Mar 10, 2027');
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

  group('formatAbsoluteLocal (#218)', () {
    // Sync timestamps are stored as UTC instants but READ by a human sitting in
    // a local timezone. Rendering the UTC wall-clock would show a sync that just
    // happened as "7 hours ago"-o'clock. The expectations below are built from
    // LOCAL calendar fields, so on any machine whose zone is not UTC a
    // UTC-rendering implementation shows different digits and fails.
    String at(DateTime instant, DateTime now) =>
        withClock(Clock.fixed(now), () => formatAbsoluteLocal(instant));

    test(
      'renders the LOCAL wall clock of a UTC instant, never the UTC one',
      () {
        // A local moment, converted to the UTC instant the store would hold.
        final localMoment = DateTime(2026, 6, 15, 14, 5);
        expect(at(localMoment.toUtc(), now), 'Jun 15 14:05');
      },
    );

    test('pads single-digit hours and minutes', () {
      expect(at(DateTime(2026, 6, 15, 9, 7).toUtc(), now), 'Jun 15 09:07');
      expect(at(DateTime(2026, 6, 15, 0, 0).toUtc(), now), 'Jun 15 00:00');
    });

    test('shows the year only when it differs from the current one', () {
      expect(
        at(DateTime(2025, 12, 31, 23, 59).toUtc(), now),
        'Dec 31, 2025 23:59',
      );
      expect(at(DateTime(2026, 1, 1, 0, 1).toUtc(), now), 'Jan 1 00:01');
    });
  });
}
