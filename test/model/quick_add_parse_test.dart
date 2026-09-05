// Unit layer — QuickAdd.test.js trailing-date parse cases as pure units.
//
// Protects the quick-add NL date rule: a trailing "today/tomorrow/next
// week/next month/on YYYY-MM-DD" resolves to a due date WITHOUT rewriting the
// typed title, and a bare phrase with no title text is NOT treated as a date
// (strip-leaves-title rule). If this drifted, quick-add would either eat the
// title text or silently mis-date tasks. Relative dates resolve against a
// pinned clock so the test is deterministic.

import 'package:axiotask/src/model/quick_add_parse.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run [body] with the calendar day pinned to [ymd].
T onDay<T>(String ymd, T Function() body) {
  final parts = ymd.split('-').map(int.parse).toList();
  return withClock(
    Clock.fixed(DateTime.utc(parts[0], parts[1], parts[2], 9, 30)),
    body,
  );
}

void main() {
  group('relative phrases resolve against the pinned day', () {
    test('tomorrow', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('Send invoice tomorrow'), '2026-08-02'),
      );
    });

    test('today', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('Discuss agenda today'), '2026-08-01'),
      );
    });

    test('next week', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('Plan sprint next week'), '2026-08-08'),
      );
    });

    test('next month', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('Write report next month'), '2026-09-01'),
      );
    });

    test('next month clamps at month end (Jan 31 → Feb 28)', () {
      onDay(
        '2026-01-31',
        () => expect(parseQuickAddDue('Pay rent next month'), '2026-02-28'),
      );
    });

    test('an optional "due" lead word is accepted and stripped', () {
      onDay(
        '2026-08-01',
        () =>
            expect(parseQuickAddDue('Submit form due tomorrow'), '2026-08-02'),
      );
    });

    test('matching is case-insensitive', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('Send it TOMORROW'), '2026-08-02'),
      );
    });
  });

  group('explicit YYYY-MM-DD', () {
    test('with an "on" lead', () {
      onDay('2026-08-01', () {
        expect(parseQuickAddDue('Book dentist on 2026-08-03'), '2026-08-03');
      });
    });

    test('the lead word may be all the title there is', () {
      // Edge of the strip-leaves-title rule: "on" is consumed as the lead word
      // of the date phrase, leaving the bare title "on" — non-empty, so this IS
      // a dated task called "on", not an undated one called "on 2026-08-03".
      // Matches the reference (App.svelte parseQuickAddDue), which strips the
      // same span before testing it.
      onDay('2026-08-01', () {
        expect(parseQuickAddDue('on 2026-08-03'), '2026-08-03');
      });
    });

    test('bare trailing date', () {
      onDay('2026-08-01', () {
        expect(parseQuickAddDue('Ship release 2026-12-25'), '2026-12-25');
      });
    });
  });

  group('strip-leaves-title rule (non-happy paths)', () {
    test('a bare relative phrase with no title text is NOT a date', () {
      onDay('2026-08-01', () {
        expect(parseQuickAddDue('tomorrow'), isNull);
        expect(parseQuickAddDue('next month'), isNull);
      });
    });

    test('a bare explicit date with no title text is NOT a date', () {
      onDay('2026-08-01', () => expect(parseQuickAddDue('2026-08-03'), isNull));
    });

    test('no trailing phrase → no date', () {
      onDay('2026-08-01', () => expect(parseQuickAddDue('Buy milk'), isNull));
    });

    test('a phrase not at the END is not parsed', () {
      onDay(
        '2026-08-01',
        () => expect(parseQuickAddDue('tomorrow is the deadline'), isNull),
      );
    });
  });
}
