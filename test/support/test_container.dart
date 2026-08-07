import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not in flutter_riverpod's default export (it is only ever used
// positionally via inference); misc.dart is where Riverpod 3 exposes the type.
import 'package:flutter_riverpod/misc.dart' show Override;

/// Builds a [ProviderContainer] for tests with Riverpod's automatic retry
/// **disabled**.
///
/// Riverpod 3 retries a provider that throws on a 200ms→6.4s backoff. That
/// timer keeps firing under test and is a documented source of hangs and
/// flakes (riverpod discussion #4431); crucially, plain
/// `ProviderContainer.test()` does **not** disable it — the default is
/// [ProviderContainer.defaultRetry]. Passing a retry callback that always
/// returns `null` turns retry off, so a failing provider stays failed under
/// the assertions instead of silently rebuilding.
///
/// Every test that needs a container MUST build it through this helper — a
/// mandatory convention, not hygiene. The returned container auto-disposes at
/// the end of the test (via `ProviderContainer.test`).
ProviderContainer createTestContainer({List<Override> overrides = const []}) {
  return ProviderContainer.test(
    overrides: overrides,
    // `Retry` is `Duration? Function(int retryCount, Object error)`; returning
    // null means "do not schedule a retry".
    retry: (_, _) => null,
  );
}
