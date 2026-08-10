// TokenProvider seam tests — ported from `token_provider.rs`'s fake-provider
// cases. What they protect: the silent path never shows UI (records
// interactive=false), the gesture path is interactive, a revoked/absent grant
// and a transient outage surface as the two DISTINCT exception types the auth
// state machine branches on, and sign-out is observable.

import 'package:axiotask/src/auth/token_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'interactive authorize is the sign-in gesture; silent probe is silent',
    () async {
      final provider = FakeTokenProvider.needsInteraction();
      // Before sign-in, a silent probe reports interaction required...
      await expectLater(
        provider.authorize(interactive: false),
        throwsA(isA<TokenProviderInteractionRequired>()),
      );
      // ...the gesture completes and the grant comes alive.
      provider.setToken('after-consent');
      expect(await provider.authorize(interactive: true), 'after-consent');
      // Both the silent probe and the interactive gesture are recorded, in order.
      expect(provider.calls, [false, true]);
    },
  );

  test(
    'a transient outage is TokenProviderUnavailable, not InteractionRequired',
    () async {
      final provider = FakeTokenProvider.unavailable('gms updating');
      await expectLater(
        provider.authorize(interactive: false),
        throwsA(isA<TokenProviderUnavailable>()),
      );
    },
  );

  test('sign-out is recorded', () async {
    final provider = FakeTokenProvider.withToken('t');
    expect(provider.wasSignedOut, isFalse);
    await provider.signOut();
    expect(provider.wasSignedOut, isTrue);
  });
}
