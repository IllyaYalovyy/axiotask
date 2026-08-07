// Protects the quick-add auto-date contract (App.svelte's quickAddDueFor): a
// task quick-added from a dated smart view is born with the date that makes it
// visible in that view. Clock-driven, so the "today"/"+7" resolution is
// deterministic. The NL trailing-date preview is covered by
// model/quick_add_parse_test.dart (re-exported here).

import 'package:axiotask/src/app/quick_add.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A fixed "now" so today/+7 are exact.
  Future<T> at<T>(DateTime now, T Function() body) =>
      withClock(Clock.fixed(now), () async => body());

  group('quickAddDueFor', () {
    test('Focus births a task due today (so it shows in Focus)', () async {
      final due = await at(
        DateTime.utc(2026, 6, 15, 13),
        () => quickAddDueFor('focus'),
      );
      expect(due, '2026-06-15');
    });

    test('Upcoming births a task due in a week', () async {
      final due = await at(
        DateTime.utc(2026, 6, 15),
        () => quickAddDueFor('upcoming'),
      );
      expect(due, '2026-06-22');
    });

    test('Missed births a task due today (never born overdue)', () async {
      final due = await at(
        DateTime.utc(2026, 6, 15),
        () => quickAddDueFor('missed'),
      );
      expect(due, '2026-06-15');
    });

    test('Unscheduled, All and list views impose no date', () async {
      await at(DateTime.utc(2026, 6, 15), () {
        expect(quickAddDueFor('unscheduled'), isNull);
        expect(quickAddDueFor('all'), isNull);
        expect(quickAddDueFor('some-list-id'), isNull);
        return null;
      });
    });

    test('re-exports the natural-language preview parser', () {
      // Sanity that the model parser is reachable through this module.
      expect(parseQuickAddDue('buy milk 2026-07-01'), '2026-07-01');
    });
  });
}
