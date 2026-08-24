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
    required this.configPath,
    Future<StoredTokens> Function(OAuthConfig config)? login,
  }) : _login = login ?? runDesktopLoopbackLogin;

  /// OAuth endpoints + desktop client credentials.
  final OAuthConfig config;

  /// Where the refresh token is persisted between sessions.
  final TokenStore store;

  /// Display path of the `config.json` that supplies [config]'s credentials.
  /// Carried only so an unconfigured install can NAME the file the user has to
  /// edit (#228); the provider never reads or writes it.
  final String configPath;

  /// The interactive loopback login. Defaults to the real browser flow;
  /// injected in tests so the gesture path runs without a browser.
  final Future<StoredTokens> Function(OAuthConfig config) _login;

  @override
  Future<String> authorize({required bool interactive}) async {
    // Before ANY flow, on BOTH paths: without a client id and secret there is
    // nothing to authenticate with. Opening the browser anyway lands the user
    // on Google's "Error 400: invalid_request — Missing required parameter:
    // client_id" with no way back, and handing a stored access token back would
    // claim a session that can never be refreshed. Fail loudly, in-app, naming
    // the file to edit (#228).
    if (config.clientId.trim().isEmpty || config.clientSecret.trim().isEmpty) {
      throw TokenProviderNotConfigured(configPath);
    }
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
