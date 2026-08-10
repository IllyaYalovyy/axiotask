// DesktopTokenProvider tests — the desktop half of the provider seam. What they
// protect: a stored refresh token restores silently with no browser; a fresh
// desktop (empty store) reports interaction-required rather than pretending to
// be signed in; the interactive gesture runs the loopback login and PERSISTS
// the session so the next launch restores it; and sign-out wipes the store.

import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/desktop_token_provider.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = OAuthConfig(clientId: 'id', clientSecret: 'secret');

StoredTokens _tokens(String access) => StoredTokens(
  accessToken: access,
  refreshToken: 'rt',
  scope: 'https://www.googleapis.com/auth/tasks',
);

void main() {
  test(
    'silent restore hands back the stored access token, no login run',
    () async {
      final store = InMemoryTokenStore()..save(_tokens('stored-access'));
      var loginRan = false;
      final provider = DesktopTokenProvider(
        config: _config,
        store: store,
        login: (_) async {
          loginRan = true;
          return _tokens('should-not-happen');
        },
      );

      expect(await provider.authorize(interactive: false), 'stored-access');
      expect(loginRan, isFalse, reason: 'restore must not open a browser');
    },
  );

  test('silent restore on an empty store requires interaction', () async {
    final provider = DesktopTokenProvider(
      config: _config,
      store: InMemoryTokenStore(),
      login: (_) async => _tokens('unused'),
    );

    await expectLater(
      provider.authorize(interactive: false),
      throwsA(isA<TokenProviderInteractionRequired>()),
    );
  });

  test(
    'interactive sign-in runs the loopback login and persists the session',
    () async {
      final store = InMemoryTokenStore();
      final provider = DesktopTokenProvider(
        config: _config,
        store: store,
        login: (_) async => _tokens('fresh-access'),
      );

      final token = await provider.authorize(interactive: true);
      expect(token, 'fresh-access');
      // Persisted so a later silent restore recovers it without a gesture.
      expect(store.load()?.accessToken, 'fresh-access');
      expect(store.load()?.refreshToken, 'rt');
    },
  );

  test('sign-out clears the token store', () async {
    final store = InMemoryTokenStore()..save(_tokens('a'));
    final provider = DesktopTokenProvider(
      config: _config,
      store: store,
      login: (_) async => _tokens('x'),
    );

    await provider.signOut();
    expect(store.load(), isNull);
  });
}
