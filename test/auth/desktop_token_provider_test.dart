// DesktopTokenProvider tests — the desktop half of the provider seam. What they
// protect: a stored refresh token restores silently with no browser; a fresh
// desktop (empty store) reports interaction-required rather than pretending to
// be signed in; the interactive gesture runs the loopback login and PERSISTS
// the session so the next launch restores it; sign-out wipes the store; and an
// install whose config.json carries NO credentials refuses to start the flow at
// all instead of launching a browser that can only reach Google's
// "Error 400: invalid_request — Missing required parameter: client_id" (#228).

import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/desktop_token_provider.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = OAuthConfig(clientId: 'id', clientSecret: 'secret');
const _configPath = '/home/u/.config/axiotask/config.json';

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
        configPath: _configPath,
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
      configPath: _configPath,
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
        configPath: _configPath,
        login: (_) async => _tokens('fresh-access'),
      );

      final token = await provider.authorize(interactive: true);
      expect(token, 'fresh-access');
      // Persisted so a later silent restore recovers it without a gesture.
      expect(store.load()?.accessToken, 'fresh-access');
      expect(store.load()?.refreshToken, 'rt');
    },
  );

  group('#228 unconfigured credentials never launch a browser', () {
    // The shipped first-run config: the file exists, the google section is
    // there, both credential fields are empty strings.
    const blank = OAuthConfig(clientId: '', clientSecret: '');

    test(
      'the sign-in gesture short-circuits before any browser opens',
      () async {
        var loginRan = false;
        final provider = DesktopTokenProvider(
          config: blank,
          store: InMemoryTokenStore(),
          configPath: _configPath,
          login: (_) async {
            loginRan = true;
            return _tokens('never');
          },
        );

        await expectLater(
          provider.authorize(interactive: true),
          throwsA(
            isA<TokenProviderNotConfigured>().having(
              (e) => e.configPath,
              'configPath',
              _configPath,
            ),
          ),
        );
        expect(
          loginRan,
          isFalse,
          reason: 'no loopback flow, no browser, no Google 400',
        );
      },
    );

    test(
      'a client_id alone is not enough — the exchange needs the secret',
      () async {
        var loginRan = false;
        final provider = DesktopTokenProvider(
          config: const OAuthConfig(clientId: 'id.apps', clientSecret: '   '),
          store: InMemoryTokenStore(),
          configPath: _configPath,
          login: (_) async {
            loginRan = true;
            return _tokens('never');
          },
        );

        await expectLater(
          provider.authorize(interactive: true),
          throwsA(isA<TokenProviderNotConfigured>()),
        );
        expect(loginRan, isFalse);
      },
    );

    test(
      'even a stored session cannot be restored without credentials',
      () async {
        // The non-happy path the takeover produced in reverse: tokens on disk
        // but no client to refresh them with. Handing the stale access token
        // back would claim a live session that can never renew.
        final provider = DesktopTokenProvider(
          config: blank,
          store: InMemoryTokenStore()..save(_tokens('stale')),
          configPath: _configPath,
          login: (_) async => _tokens('never'),
        );

        await expectLater(
          provider.authorize(interactive: false),
          throwsA(isA<TokenProviderNotConfigured>()),
        );
      },
    );

    test('filled-in credentials behave exactly as before', () async {
      final store = InMemoryTokenStore();
      final provider = DesktopTokenProvider(
        config: _config,
        store: store,
        configPath: _configPath,
        login: (_) async => _tokens('fresh-access'),
      );

      expect(await provider.authorize(interactive: true), 'fresh-access');
      expect(store.load()?.refreshToken, 'rt');
    });
  });

  test('sign-out clears the token store', () async {
    final store = InMemoryTokenStore()..save(_tokens('a'));
    final provider = DesktopTokenProvider(
      config: _config,
      store: store,
      configPath: _configPath,
      login: (_) async => _tokens('x'),
    );

    await provider.signOut();
    expect(store.load(), isNull);
  });
}
