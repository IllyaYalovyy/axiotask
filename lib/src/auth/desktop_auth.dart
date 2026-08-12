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

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart' show RestartableTimer;
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
  Duration timeout = const Duration(minutes: 5),
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

    final code = await awaitLoopbackRedirect(
      server,
      redirectUri: redirectUri,
      state: state,
      timeout: timeout,
    );

    return exchangeCode(
      httpClient: client,
      config: config,
      code: code,
      redirectUri: redirectUri,
      codeVerifier: pkce.verifier,
    );
  } finally {
    // awaitLoopbackRedirect already closes the server on every exit; this is a
    // defensive double-close covering an early throw before it is reached
    // (ServerSocket.close is idempotent).
    await server.close();
    if (httpClient == null) client.close();
  }
}

/// Wait on the bound loopback [server] for Google's OAuth redirect and return
/// the authorization `code`. Extracted from [runDesktopLoopbackLogin] so the
/// tricky socket handling is unit-tested against real loopback sockets.
///
/// Robustness contract (F21):
/// - **Accept-loop, not first-connection.** Browsers open speculative
///   preconnect sockets and fetch `/favicon.ico`; a well-formed request that
///   carries neither `code` nor `error` is answered `404` and the loop keeps
///   waiting for the real redirect. Handlers run concurrently, so a silent
///   preconnect that never sends a request line cannot wedge the real one.
/// - **Typed failure on garbage.** A request line that cannot be parsed into a
///   request-target raises [AuthMalformedRedirect] — never a raw `RangeError`.
/// - **Bounded gesture.** If no parseable redirect arrives within [timeout] the
///   wait fails with [AuthTimeout]. On every exit (success, timeout, or a
///   redirect that itself denies/mismatches) the [server] is cancelled and any
///   lingering sockets are destroyed, releasing the ephemeral port.
Future<String> awaitLoopbackRedirect(
  ServerSocket server, {
  required String redirectUri,
  required String state,
  required Duration timeout,
}) async {
  final completer = Completer<String>();
  final open = <Socket>{};

  // RestartableTimer (package:async) — the repo bans a raw dart:async Timer
  // below lib/ because it is uncontrollable under test; this one is cancellable.
  final timer = RestartableTimer(timeout, () {
    if (!completer.isCompleted) completer.completeError(const AuthTimeout());
  });

  final sub = server.listen((socket) async {
    open.add(socket);
    try {
      final requestLine = await _readRequestLine(socket);
      if (completer.isCompleted) return;
      final path = _requestTarget(requestLine);
      final query = Uri.parse('$redirectUri$path').queryParameters;
      if (!query.containsKey('code') && !query.containsKey('error')) {
        // Browser preconnect / favicon probe / speculative socket — not the
        // redirect. Answer 404 and keep listening.
        await _writeResponse(
          socket,
          404,
          'Not Found',
          '<html><body><p>Waiting for sign-in to complete...</p></body></html>',
        );
        return;
      }
      final code = parseRedirect('$redirectUri$path', state);
      await _writeResponse(
        socket,
        200,
        'OK',
        '<html><body><h1>Signed in.</h1>'
            '<p>You can close this tab.</p></body></html>',
      );
      if (!completer.isCompleted) completer.complete(code);
    } on AuthException catch (e) {
      await _writeResponse(
        socket,
        400,
        'Bad Request',
        '<html><body><p>Sign-in failed.</p></body></html>',
      );
      if (!completer.isCompleted) completer.completeError(e);
    } finally {
      open.remove(socket);
      await socket.close().catchError((_) => socket);
    }
  });

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
    for (final socket in open) {
      socket.destroy();
    }
    await server.close();
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

/// Extract the request-target (path + query) from an HTTP request line
/// (`GET /?code=… HTTP/1.1`). A line without a method+target is garbage —
/// raise [AuthMalformedRedirect] rather than let `elementAt(1)` throw a raw
/// `RangeError`.
String _requestTarget(String requestLine) {
  final parts = requestLine
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.length < 2) {
    throw const AuthMalformedRedirect();
  }
  return parts[1];
}

/// Write a minimal HTTP response and flush it to the loopback socket.
Future<void> _writeResponse(
  Socket socket,
  int status,
  String reason,
  String body,
) async {
  socket.write(
    'HTTP/1.1 $status $reason\r\n'
    'Content-Type: text/html\r\n'
    'Content-Length: ${body.length}\r\n'
    'Connection: close\r\n'
    '\r\n$body',
  );
  await socket.flush();
}
