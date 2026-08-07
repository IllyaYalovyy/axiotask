// Unit layer — the enumerated `dates.rs` tests ported 1:1.
//
// Protects one-keystroke date moves (month-end clamp, leap years, year cross),
// due-string canonicalization to Google's exact `.000Z` form (Feb 30 rejected,
// prefix-based, no panic on short/multibyte input), and the UTC now-stamp's
// micro precision that guards the push mark-clean race. These are the failure
// modes that would either desync every due date or misfire a completed move.

import 'package:axiotask/src/model/dates.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);

void main() {
  group('applyDateMove', () {
    test('today_returns_same_date', () {
      expect(applyDateMove(d(2026, 5, 23), DateMove.today), d(2026, 5, 23));
    });

    test('tomorrow_advances_one_day', () {
      expect(applyDateMove(d(2026, 5, 23), DateMove.tomorrow), d(2026, 5, 24));
    });

    test('tomorrow_crosses_month_boundary', () {
      expect(applyDateMove(d(2026, 1, 31), DateMove.tomorrow), d(2026, 2, 1));
    });

    test('next_week_is_plus_seven_days', () {
      expect(applyDateMove(d(2026, 5, 23), DateMove.nextWeek), d(2026, 5, 30));
    });

    test('next_month_clamps_at_february', () {
      expect(applyDateMove(d(2026, 1, 31), DateMove.nextMonth), d(2026, 2, 28));
    });

    test('next_month_uses_leap_february_when_applicable', () {
      expect(applyDateMove(d(2028, 1, 31), DateMove.nextMonth), d(2028, 2, 29));
    });

    test('next_month_crosses_year', () {
      expect(
        applyDateMove(d(2026, 12, 30), DateMove.nextMonth),
        d(2027, 1, 30),
      );
    });

    test('next_month_clamps_at_30_day_month', () {
      expect(applyDateMove(d(2026, 3, 31), DateMove.nextMonth), d(2026, 4, 30));
    });

    test('clear_returns_none', () {
      expect(applyDateMove(d(2026, 5, 23), DateMove.clear), isNull);
    });

    test('applying_tomorrow_twice_is_two_days_apart', () {
      final t = applyDateMove(d(2026, 5, 23), DateMove.tomorrow)!;
      final tt = applyDateMove(t, DateMove.tomorrow)!;
      expect(tt, d(2026, 5, 25));
    });
  });

  group('normalizeDue', () {
    test('bare_date_becomes_full_form', () {
      expect(normalizeDue('2026-08-02'), '2026-08-02T00:00:00.000Z');
    });

    test('seconds_only_form_gains_millis', () {
      expect(normalizeDue('2026-08-03T00:00:00Z'), '2026-08-03T00:00:00.000Z');
    });

    test('canonical_form_is_unchanged', () {
      expect(
        normalizeDue('2026-08-01T00:00:00.000Z'),
        '2026-08-01T00:00:00.000Z',
      );
    });

    test('nonzero_time_is_floored_to_date', () {
      expect(
        normalizeDue('2026-08-01T17:30:00.000Z'),
        '2026-08-01T00:00:00.000Z',
      );
    });

    test('garbage_is_rejected', () {
      expect(normalizeDue(''), isNull);
      expect(normalizeDue('tomorrow'), isNull);
      expect(normalizeDue('2026-13-45'), isNull);
      // Feb 30 fails the calendar check — rejected, not silently clamped.
      expect(normalizeDue('2026-02-30'), isNull);
    });

    test('import_uses_the_leading_ten_chars_and_floors_the_rest', () {
      for (final raw in [
        '2026-08-02T23:59:59-07:00',
        '2026-08-02T00:00:00.123456Z',
        '2026-08-02 anything at all',
      ]) {
        expect(normalizeDue(raw), '2026-08-02T00:00:00.000Z', reason: raw);
      }
      // The date MUST be at the front: leading junk shifts the prefix.
      expect(normalizeDue(' 2026-08-02'), isNull);
      expect(normalizeDue('due:2026-08-02'), isNull);
    });

    test('short_or_multibyte_input_returns_none_without_panicking', () {
      expect(normalizeDue('📅'), isNull);
      expect(normalizeDue('2026-8-2'), isNull); // unpadded: too short
      expect(normalizeDue('2026'), isNull);
    });
  });

  group('nowUtcString', () {
    test('has_z_and_micros with a pinned clock', () {
      withClock(Clock.fixed(DateTime.utc(2026, 7, 10, 0, 0, 0, 123, 456)), () {
        final s = nowUtcString();
        expect(s, '2026-07-10T00:00:00.123456Z');
        expect(s.endsWith('Z'), isTrue);
        expect(s.length, '2026-07-10T00:00:00.000000Z'.length);
      });
    });

    test('emits true UTC even when the clock is in a local offset', () {
      // A local instant must be converted to UTC, not labelled Z as-is (#47).
      withClock(
        Clock.fixed(
          DateTime.parse('2026-07-10T02:00:00.000000+02:00'),
        ), // 00:00 UTC
        () => expect(nowUtcString(), '2026-07-10T00:00:00.000000Z'),
      );
    });

    test(
      'consecutive calls differ (sub-second precision guards mark-clean)',
      () {
        var micros = 0;
        final advancing = Clock(
          () => DateTime.utc(2026, 1, 1).add(Duration(microseconds: micros++)),
        );
        withClock(advancing, () {
          expect(nowUtcString(), isNot(nowUtcString()));
        });
      },
    );
  });

  group('nextMonthClamped', () {
    test('is the identity basis of DateMove.nextMonth', () {
      expect(nextMonthClamped(d(2026, 1, 31)), d(2026, 2, 28));
      expect(nextMonthClamped(d(2026, 11, 30)), d(2026, 12, 30));
    });
  });
}
