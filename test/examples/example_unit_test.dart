// EXAMPLE — unit layer (pure logic, no Flutter binding).
//
// Template for every plain-Dart test in this repo. It also guards a real
// harness invariant: product code reads the wall clock through
// `package:clock`'s ambient `clock`, NEVER `DateTime.now()` (the gate greps
// lib/ for the latter — see .ktask/verify.sh and TESTING.md). That indirection
// is worthless unless `withClock` actually overrides what `clock.now()`
// returns, so this test pins time and proves the override takes effect. If it
// ever fails, date-dependent tests across the codebase have lost determinism.
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clock injection (the DateTime.now replacement)', () {
    final pinned = DateTime.utc(2026, 8, 7, 9, 30);

    test('withClock pins clock.now() to the injected instant', () {
      withClock(Clock.fixed(pinned), () {
        expect(clock.now(), pinned);
      });
    });

    test('durations across a pinned clock are deterministic', () {
      withClock(Clock.fixed(pinned), () {
        final later = clock.now().add(const Duration(hours: 2));
        expect(later.difference(clock.now()), const Duration(hours: 2));
      });
    });

    // Non-happy path: OUTSIDE a withClock zone the ambient clock is real wall
    // time, so it must NOT equal the pinned instant — the exact failure mode
    // that would make time-based tests pass or fail by accident.
    test('ambient clock is not the pinned instant', () {
      expect(clock.now(), isNot(pinned));
    });
  });
}
