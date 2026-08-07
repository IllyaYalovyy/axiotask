import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fonts.dart';
import 'property_check.dart';
import 'test_container.dart';

void main() {
  group('createTestContainer', () {
    test('disables Riverpod retry for a failing provider', () {
      fakeAsync((async) {
        var builds = 0;
        final failing = FutureProvider<int>((ref) async {
          builds++;
          // A plain Exception is what Riverpod's defaultRetry reschedules; an
          // Error (or ProviderException) would never retry and prove nothing.
          throw Exception('boom');
        });

        final container = createTestContainer();
        container.listen<AsyncValue<int>>(
          failing,
          (_, _) {},
          onError: (_, _) {},
        );
        async.flushMicrotasks();
        expect(builds, 1, reason: 'the provider should build exactly once');

        // With retry ENABLED, Riverpod reschedules the build via Timer(200ms)
        // and keeps backing off, so 2s would drive several rebuilds. With the
        // shared helper's retry DISABLED, the failing provider must not rebuild.
        async.elapse(const Duration(seconds: 2));
        expect(
          builds,
          1,
          reason: 'shared test container must keep Riverpod retry disabled',
        );
      });
    });

    test('applies provider overrides', () {
      final value = Provider<int>((ref) => 1);
      final container = createTestContainer(
        overrides: [value.overrideWithValue(42)],
      );
      expect(container.read(value), 42);
    });
  });

  group('loadAppFonts', () {
    test('registers the bundled Material icon font', () async {
      final families = await loadAppFonts();
      // uses-material-design: true bundles MaterialIcons and lists it in the
      // manifest; an empty/missing set means the font harness silently broke.
      expect(families, isNotEmpty);
      expect(families, contains('MaterialIcons'));
    });
  });

  group('property_check facade', () {
    test('pins a deterministic default seed', () {
      expect(kDefaultPropertySeed, 20260807);
    });
  });

  property('facade forAll drives the block over generated values', () {
    forAll(integer(min: 0, max: 1 << 30), (n) {
      expect(n, greaterThanOrEqualTo(0));
    }, maxExamples: 25);
  });
}
