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
