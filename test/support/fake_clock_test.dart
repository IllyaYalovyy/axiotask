import 'package:flutter_test/flutter_test.dart';

import 'fake_clock.dart';

void main() {
  group('FakeClock qualification', () {
    test('releases timers at the exact monotonic boundary', () {
      final clock = FakeClock(DateTime.utc(2026, 8, 15, 12));
      final fired = <Duration>[];
      clock.schedule(const Duration(minutes: 5), () {
        fired.add(clock.monotonicElapsed);
      });

      clock.advance(const Duration(minutes: 4, seconds: 59, milliseconds: 999));
      expect(fired, isEmpty);

      clock.advance(const Duration(milliseconds: 1));
      expect(fired, <Duration>[const Duration(minutes: 5)]);
    });

    test('wall-clock discontinuity does not release monotonic timers', () {
      final clock = FakeClock(DateTime.utc(2026, 8, 15, 12));
      var fired = false;
      clock.schedule(const Duration(seconds: 30), () => fired = true);

      clock.jumpWall(const Duration(days: 2));
      expect(clock.now(), DateTime.utc(2026, 8, 17, 12));
      expect(clock.monotonicElapsed, Duration.zero);
      expect(fired, isFalse);

      clock.jumpWall(const Duration(days: -4));
      clock.advanceMonotonic(const Duration(seconds: 30));
      expect(clock.now(), DateTime.utc(2026, 8, 13, 12));
      expect(fired, isTrue);
    });

    test('same-deadline timers release in registration order', () {
      final clock = FakeClock(DateTime.utc(2026, 8, 15));
      final order = <String>[];
      clock.schedule(const Duration(seconds: 1), () => order.add('first'));
      clock.schedule(const Duration(seconds: 1), () => order.add('second'));

      clock.advance(const Duration(seconds: 1));

      expect(order, <String>['first', 'second']);
    });
  });
}
