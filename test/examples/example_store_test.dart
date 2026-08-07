// EXAMPLE — store layer (Riverpod provider state).
//
// Template for testing a Notifier/provider's observable STATE (not "a method
// was called") through the shared retry-disabled container. Every store test
// builds its container via createTestContainer() so a throwing provider cannot
// silently rebuild on Riverpod's retry backoff (see test/support). The subject
// here is a self-contained example Notifier standing in for a real store.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_container.dart';

/// Example store — a real store (T1.x) replaces this; the test SHAPE carries.
final exampleCounterProvider = NotifierProvider<ExampleCounter, int>(
  ExampleCounter.new,
);

class ExampleCounter extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state = state + 1;

  void reset() => state = 0;
}

void main() {
  group('exampleCounterProvider', () {
    test('starts at zero and observes each mutation', () {
      final container = createTestContainer();
      final seen = <int>[];
      container.listen<int>(
        exampleCounterProvider,
        (_, next) => seen.add(next),
        fireImmediately: false,
      );

      expect(container.read(exampleCounterProvider), 0);
      container.read(exampleCounterProvider.notifier).increment();
      container.read(exampleCounterProvider.notifier).increment();

      expect(container.read(exampleCounterProvider), 2);
      expect(seen, [1, 2], reason: 'each increment emits a new state');
    });

    // Non-happy path: reset from a non-zero state returns to the initial value.
    test('reset returns to the initial state', () {
      final container = createTestContainer();
      final notifier = container.read(exampleCounterProvider.notifier);
      notifier.increment();
      expect(container.read(exampleCounterProvider), 1);

      notifier.reset();
      expect(container.read(exampleCounterProvider), 0);
    });
  });
}
