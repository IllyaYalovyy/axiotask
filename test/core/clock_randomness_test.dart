import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ManualClock advances wall and monotonic time deterministically', () {
    final clock = ManualClock(DateTime.utc(2026, 8, 12, 12));

    expect(clock.now(), DateTime.utc(2026, 8, 12, 12));
    expect(clock.monotonicElapsed, Duration.zero);

    clock.advance(const Duration(minutes: 7, milliseconds: 25));

    expect(clock.now(), DateTime.utc(2026, 8, 12, 12, 7, 0, 25));
    expect(
      clock.monotonicElapsed,
      const Duration(minutes: 7, milliseconds: 25),
    );
  });

  test('ManualClock schedules and cancels exact monotonic deadlines', () {
    final clock = ManualClock(DateTime.utc(2026, 8, 12, 12));
    final fired = <Duration>[];
    clock.schedule(const Duration(seconds: 5), () {
      fired.add(clock.monotonicElapsed);
    });
    final cancelled = clock.schedule(const Duration(seconds: 5), () {
      fired.add(const Duration(days: 1));
    });
    expect(cancelled.cancel(), isTrue);

    clock.advance(const Duration(seconds: 4, milliseconds: 999));
    expect(fired, isEmpty);
    clock.advance(const Duration(milliseconds: 1));
    expect(fired, <Duration>[const Duration(seconds: 5)]);
  });

  test(
    'SequenceRandomSource returns injected bytes without system entropy',
    () {
      final randomness = SequenceRandomSource(<int>[0, 1, 127, 255, 42]);

      expect(randomness.nextBytes(3), <int>[0, 1, 127]);
      expect(randomness.nextBytes(2), <int>[255, 42]);
      expect(() => randomness.nextBytes(1), throwsStateError);
    },
  );
}
