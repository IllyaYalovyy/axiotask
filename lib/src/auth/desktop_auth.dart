// Desktop OAuth — the port of `auth/flow.rs`, with the code→token exchange and
// refresh handed to googleapis_auth (MIGRATION-PLAN §2 auth). What stays ours:
// the OAuth config values, the loopback-redirect parser (`parse_redirect`), the
// consent-URL builder, and PKCE — because Google rejects anything but a real
// loopback/PKCE desktop flow, and the parser's UserDenied/StateMismatch
// contract is a guarantee we test directly rather than trust a library to keep.
//
// The pure pieces here (parseRedirect / buildAuthUrl / exchangeCode against an
// injected http.Client) are unit-tested; [runDesktopLoopbackLogin] is the thin
// runtime plumbing (a loopback socket + the browser) that composes them and is
// exercised for real only on desktop.

import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'auth_error.dart';
import 'pkce.dart';
import 'token_store.dart';

/// Configuration for the desktop OAuth flow. Ported from `OAuthConfig`.
class OAuthConfig {
  const OAuthConfig({
    required this.clientId,
    required this.clientSecret,
    this.scopes = const ['https://www.googleapis.com/auth/tasks'],
    this.authUrl = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenUrl = 'https://oauth2.googleapis.com/token',
  });

  /// Google OAuth client ID (a "Desktop app" client).
  final String clientId;

  /// Google OAuth client secret. Desktop-app clients carry one and must send it
  /// on the token exchange even under PKCE.
  final String clientSecret;

  /// Scopes to request.
  final List<String> scopes;

  /// Authorization endpoint.
  final String authUrl;

  /// Token endpoint.
  final String tokenUrl;
}

/// Build the OAuth 2.0 consent URL. Pure — the loopback flow passes its
/// ephemeral `http://127.0.0.1:<port>` redirect here. Ported from
/// `build_auth_url`; spaces encode as `%20` and reserved chars percent-encode,
/// matching the reference's `urlencoding::encode`.
String buildAuthUrl(
  OAuthConfig config, {
  required String redirectUri,
  required String challenge,
  required String method,
  required String state,
}) {
  String enc(String s) => Uri.encodeComponent(s);
  return '${config.authUrl}'
      '?client_id=${enc(config.clientId)}'
      '&redirect_uri=${enc(redirectUri)}'
      '&response_type=code'
      '&scope=${enc(config.scopes.join(' '))}'
      '&state=${enc(state)}'
      '&code_challenge=${enc(challenge)}'
      '&code_challenge_method=$method';
}

/// Parse the desktop loopback redirect URL, validate the CSRF `state`, and
/// return the authorization `code`. Ported from `parse_redirect`.
///
/// - An explicit `?error=…` (the user pressed *Deny*) → [AuthUserDenied].
/// - No `code` present → [AuthUserDenied].
/// - A `state` that does not match [expectedState] → [AuthStateMismatch]
///   (possible CSRF / stale redirect); the code is rejected even if present.
String parseRedirect(String redirectUrl, String expectedState) {
  final Uri parsed;
  try {
    parsed = Uri.parse(redirectUrl);
  } on FormatException catch (e) {
    throw AuthUserDenied('unparseable redirect: ${e.message}');
  }
  final params = parsed.queryParameters;

  if (params.containsKey('error')) {
    throw const AuthUserDenied();
  }
  final code = params['code'];
  if (code == null) {
    throw const AuthUserDenied();
  }
  final returnedState = params['state'];
  if (returnedState == null || returnedState != expectedState) {
    throw const AuthStateMismatch();
  }
  return code;
}

/// Exchange an authorization code for tokens through googleapis_auth.
///
/// Wrapper contract (T6.1): the exchange MUST send the desktop client's
/// `client_secret` and the PKCE `code_verifier` (both handled by
/// googleapis_auth for a confidential [ClientId]), and a response with NO
/// refresh token is a sign-in FAILURE ([RefreshTokenMissing]) — without it the
/// session cannot be resumed after restart. [httpClient] is injected so tests
/// drive the exchange against a scripted transport.
Future<StoredTokens> exchangeCode({
  required http.Client httpClient,
  required OAuthConfig config,
  required String code,
  required String redirectUri,
  required String codeVerifier,
}) async {
  final clientId = ClientId(config.clientId, config.clientSecret);
  final creds = await obtainAccessCredentialsViaCodeExchange(
    httpClient,
    clientId,
    code,
    redirectUrl: redirectUri,
    codeVerifier: codeVerifier,
  );
  final refresh = creds.refreshToken;
  if (refresh == null || refresh.isEmpty) {
    throw const RefreshTokenMissing();
  }
  return StoredTokens(
    accessToken: creds.accessToken.data,
    refreshToken: refresh,
    accessExpiresAt:
        creds.accessToken.expiry.millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond,
    scope: creds.scopes.join(' '),
  );
}

/// Run the full desktop loopback PKCE login and return the fresh tokens (the
/// caller persists them). Runtime plumbing only — it binds an ephemeral
/// loopback port, opens the system browser, waits for Google's redirect, and
/// composes the tested [parseRedirect] + [exchangeCode] units. Not unit-tested
/// (needs a browser and a live token endpoint); desktop is the only platform
/// that reaches it.
Future<StoredTokens> runDesktopLoopbackLogin(
  OAuthConfig config, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  final pkce = Pkce.generate();
  final state = randomState();
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final url = buildAuthUrl(
      config,
      redirectUri: redirectUri,
      challenge: pkce.challenge,
      method: Pkce.method,
      state: state,
    );
    // Best effort — a headless box without xdg-open still lets the user paste
    // the URL from the log.
    try {
      await Process.run('xdg-open', [url]);
    } on ProcessException {
      stderr.writeln('open this URL to sign in: $url');
    }

    final socket = await server.first;
    final requestLine = await _readRequestLine(socket);
    final path = requestLine.split(' ').elementAt(1);
    final code = parseRedirect('$redirectUri$path', state);
    socket.write(
      'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n'
      '<html><body><h1>Signed in.</h1><p>You can close this tab.</p></body></html>',
    );
    await socket.flush();
    await socket.close();

    return exchangeCode(
      httpClient: client,
      config: config,
      code: code,
      redirectUri: redirectUri,
      codeVerifier: pkce.verifier,
    );
  } finally {
    await server.close();
    if (httpClient == null) client.close();
  }
}

/// Read the first line (the HTTP request line) from an incoming loopback socket.
Future<String> _readRequestLine(Socket socket) async {
  final buffer = StringBuffer();
  await for (final chunk in socket) {
    buffer.write(String.fromCharCodes(chunk));
    final text = buffer.toString();
    final nl = text.indexOf('\r\n');
    if (nl >= 0) return text.substring(0, nl);
  }
  return buffer.toString();
}
