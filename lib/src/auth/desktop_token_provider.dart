// Desktop token provider — bridges the desktop OAuth flow (loopback PKCE +
// tokens.json) to the platform-agnostic [TokenProvider] seam the
// [AuthController] drives.
//
// The desktop restore model differs from Android's: there is no silent network
// probe. A previously-granted session is exactly "tokens.json holds a refresh
// token", so a non-interactive `authorize` reads the store. Present → hand back
// the access token (the API layer refreshes reactively on 401); absent → the
// grant needs the interactive gesture. That maps the same three-state machine
// onto desktop that Play Services gives Android.

import 'desktop_auth.dart';
import 'token_provider.dart';
import 'token_store.dart';

/// A [TokenProvider] over a desktop OAuth [OAuthConfig] + [TokenStore].
class DesktopTokenProvider implements TokenProvider {
  DesktopTokenProvider({
    required this.config,
    required this.store,
    Future<StoredTokens> Function(OAuthConfig config)? login,
  }) : _login = login ?? runDesktopLoopbackLogin;

  /// OAuth endpoints + desktop client credentials.
  final OAuthConfig config;

  /// Where the refresh token is persisted between sessions.
  final TokenStore store;

  /// The interactive loopback login. Defaults to the real browser flow;
  /// injected in tests so the gesture path runs without a browser.
  final Future<StoredTokens> Function(OAuthConfig config) _login;

  @override
  Future<String> authorize({required bool interactive}) async {
    if (interactive) {
      // The sign-in gesture: run the loopback flow and persist the new session.
      final tokens = await _login(config);
      store.save(tokens);
      return tokens.accessToken;
    }
    // Silent restore: a stored refresh token IS the live desktop session.
    final existing = store.load();
    if (existing == null) {
      throw const TokenProviderInteractionRequired();
    }
    return existing.accessToken;
  }

  @override
  Future<void> signOut() async => store.clear();
}
