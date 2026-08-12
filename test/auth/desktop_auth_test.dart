// Desktop OAuth tests — ports of `flow.rs`'s parse_redirect / build_auth_url
// cases, plus the T6.1 wrapper tests that pin googleapis_auth's exchange
// behavior. What they protect: a denied or forged loopback redirect never
// yields a code; the consent URL Google receives carries the loopback redirect,
// PKCE challenge and CSRF state; the token exchange sends the desktop
// client_secret + PKCE verifier; and a response missing the refresh token fails
// the sign-in instead of leaving an unresumable session.

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = OAuthConfig(
  clientId: 'desktop-id',
  clientSecret: 'desktop-secret',
);

http.Response _jsonReply(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

/// Open a loopback client, send [request] bytes, and return the raw response
/// text the server wrote back (read until the server closes the connection).
Future<String> _sendRequest(int port, String request) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write(request);
  await socket.flush();
  return utf8.decodeStream(socket);
}

void main() {
  group('parseRedirect (loopback contract)', () {
    test('extracts the code from a desktop loopback URL', () {
      const url = 'http://127.0.0.1:54321/?code=desk-code-123&state=st-abc';
      expect(parseRedirect(url, 'st-abc'), 'desk-code-123');
    });

    test('rejects a state mismatch even with a valid code (CSRF guard)', () {
      const url = 'http://127.0.0.1:54321/?code=attacker-code&state=WRONG';
      expect(
        () => parseRedirect(url, 'expected-state'),
        throwsA(isA<AuthStateMismatch>()),
      );
    });

    test('reports user-denied on an error param', () {
      const url = 'http://127.0.0.1:54321/?error=access_denied&state=st';
      expect(() => parseRedirect(url, 'st'), throwsA(isA<AuthUserDenied>()));
    });

    test('reports user-denied when no code is present', () {
      const url = 'http://127.0.0.1:54321/?state=st';
      expect(() => parseRedirect(url, 'st'), throwsA(isA<AuthUserDenied>()));
    });
  });

  group('buildAuthUrl', () {
    test('carries the loopback redirect, PKCE challenge, method and state', () {
      final url = buildAuthUrl(
        _config,
        redirectUri: 'http://127.0.0.1:54321',
        challenge: 'the-challenge',
        method: 'S256',
        state: 'the-state',
      );
      // Redirect URI is percent-encoded (`:` → %3A, `/` → %2F).
      expect(url, contains('redirect_uri=http%3A%2F%2F127.0.0.1%3A54321'));
      expect(url, contains('code_challenge=the-challenge'));
      expect(url, contains('code_challenge_method=S256'));
      expect(url, contains('state=the-state'));
      expect(url, contains('client_id=desktop-id'));
      expect(url, contains('response_type=code'));
    });
  });

  group('exchangeCode (googleapis_auth wrapper)', () {
    test(
      'sends client_secret + code_verifier and returns the tokens',
      () async {
        late http.Request captured;
        final transport = MockClient((request) async {
          captured = request;
          return _jsonReply({
            'token_type': 'Bearer',
            'access_token': 'at-desktop',
            'refresh_token': 'rt-desktop',
            'expires_in': 3600,
            'scope': 'https://www.googleapis.com/auth/tasks',
          });
        });

        final tokens = await exchangeCode(
          httpClient: transport,
          config: _config,
          code: 'the-code',
          redirectUri: 'http://127.0.0.1:0',
          codeVerifier: 'the-verifier',
        );

        expect(tokens.accessToken, 'at-desktop');
        expect(tokens.refreshToken, 'rt-desktop');
        expect(tokens.scope, 'https://www.googleapis.com/auth/tasks');
        // A desktop-app client must send its secret + the PKCE verifier.
        expect(captured.bodyFields['client_secret'], 'desktop-secret');
        expect(captured.bodyFields['code_verifier'], 'the-verifier');
        expect(captured.bodyFields['grant_type'], 'authorization_code');
      },
    );

    test('a response with no refresh token fails the sign-in', () async {
      final transport = MockClient((request) async {
        return _jsonReply({
          'token_type': 'Bearer',
          'access_token': 'at-desktop',
          // no refresh_token — Google omits it when the user already granted
          // once and `prompt=consent` was not forced.
          'expires_in': 3600,
          'scope': 'https://www.googleapis.com/auth/tasks',
        });
      });

      expect(
        () => exchangeCode(
          httpClient: transport,
          config: _config,
          code: 'the-code',
          redirectUri: 'http://127.0.0.1:0',
          codeVerifier: 'the-verifier',
        ),
        throwsA(isA<RefreshTokenMissing>()),
      );
    });
  });

  group('awaitLoopbackRedirect (loopback robustness, F21)', () {
    late ServerSocket server;
    late String redirectUri;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      redirectUri = 'http://127.0.0.1:${server.port}';
    });

    test('ignores a browser preconnect (404) and returns the code from the '
        'real redirect that follows', () async {
      final future = awaitLoopbackRedirect(
        server,
        redirectUri: redirectUri,
        state: 'st',
        timeout: const Duration(seconds: 5),
      );

      // A speculative preconnect / favicon probe: well-formed, but carries
      // neither `code` nor `error`. It must not consume the flow.
      final noiseReply = await _sendRequest(
        server.port,
        'GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
      );
      expect(noiseReply, contains('404 Not Found'));

      // The real redirect arrives on a fresh connection.
      final okReply = await _sendRequest(
        server.port,
        'GET /?code=real-code&state=st HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
      );
      expect(okReply, contains('200 OK'));
      expect(await future, 'real-code');
    });

    test('drops a dataless connection (opens, sends nothing, closes) as noise '
        'and returns the code from the real redirect that follows', () async {
      final future = awaitLoopbackRedirect(
        server,
        redirectUri: redirectUri,
        state: 'st',
        timeout: const Duration(seconds: 5),
      );

      // A speculative preconnect / probe: the browser opens the loopback
      // socket and closes it without ever sending a request line, while the
      // user is still on the consent screen. It must NOT fail the gesture
      // (#200) — the flow keeps waiting for the real redirect.
      final noise = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      await noise.close();
      await noise.drain<void>();

      // The real redirect arrives on a fresh connection and signs in.
      final okReply = await _sendRequest(
        server.port,
        'GET /?code=real-code&state=st HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
      );
      expect(okReply, contains('200 OK'));
      expect(await future, 'real-code');
    });

    test('a blank request line (no method, no target) fails with a typed '
        'AuthMalformedRedirect, not a raw RangeError', () async {
      final future = awaitLoopbackRedirect(
        server,
        redirectUri: redirectUri,
        state: 'st',
        timeout: const Duration(seconds: 5),
      );

      // Observe the failing future BEFORE triggering it: the flow records the
      // typed error the instant it parses the bad line, so a late listener
      // would see it surface as an unhandled error first.
      final expectation = expectLater(
        future,
        throwsA(isA<AuthMalformedRedirect>()),
      );

      // A connection that DOES send a request line, but a malformed one: a
      // lone token with no request-target. Distinct from a dataless probe —
      // this stays a typed failure rather than a raw RangeError.
      await _sendRequest(server.port, 'GARBAGE\r\n\r\n');

      await expectation;
    });

    test('a response-write failure still completes the sign-in with the '
        'received code and does not escape as an unhandled error', () async {
      // The browser delivers the real redirect, then drops the tab before the
      // server can write its success page — a broken pipe on the response
      // write. Simulated deterministically (a real loopback write of a small
      // body lands in the kernel buffer and succeeds regardless of the peer):
      // the injected writer throws a SocketException exactly as a broken pipe
      // would. Because the code was already received, the sign-in must still
      // complete with it — the failed write must neither discard the code
      // (hang to timeout) nor escape as an unhandled async error (#200). An
      // unhandled SocketException would be flagged by the test zone.
      final future = awaitLoopbackRedirect(
        server,
        redirectUri: redirectUri,
        state: 'st',
        timeout: const Duration(seconds: 5),
        writeResponse: (socket, status, reason, body) async {
          throw const SocketException('broken pipe');
        },
      );

      await _sendRequest(
        server.port,
        'GET /?code=real-code&state=st HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n',
      );

      expect(await future, 'real-code');
    });

    test('times out and cancels the server when no redirect arrives', () async {
      final future = awaitLoopbackRedirect(
        server,
        redirectUri: redirectUri,
        state: 'st',
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(future, throwsA(isA<AuthTimeout>()));

      // The server was cancelled, so its ephemeral port no longer accepts.
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, server.port),
        throwsA(isA<SocketException>()),
      );
    });

    test(
      'a redirect carrying error=access_denied fails as user-denied',
      () async {
        final future = awaitLoopbackRedirect(
          server,
          redirectUri: redirectUri,
          state: 'st',
          timeout: const Duration(seconds: 5),
        );

        // Observe the failing future before triggering it: the flow now
        // records the typed error before writing the 400 page, so a late
        // listener would see it as an unhandled error first.
        final expectation = expectLater(future, throwsA(isA<AuthUserDenied>()));

        final reply = await _sendRequest(
          server.port,
          'GET /?error=access_denied&state=st HTTP/1.1\r\n\r\n',
        );
        expect(reply, contains('400 Bad Request'));
        await expectation;
      },
    );
  });

  group('runDesktopLoopbackLogin (owned-client lifecycle, #207)', () {
    test(
      'the owned client stays open until the token exchange completes',
      () async {
        // The production path passes NO httpClient, so the flow creates and —
        // in its finally — closes its own. A `return future` inside try/finally
        // runs the finally BEFORE the future completes, so the exchange's POST
        // to Google died mid-connect ("Connection attempt cancelled") on every
        // sign-in whose exchange lost the race against teardown. This test owns
        // that ordering: the fake exchange yields, then sends a request THROUGH
        // the flow's own client — a prematurely closed client throws here and
        // fails the sign-in exactly like the field failure.
        final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => probe.close(force: true));
        probe.listen((req) async {
          req.response.write('ok');
          await req.response.close();
        });

        final tokens = await runDesktopLoopbackLogin(
          _config,
          openUrl: (url) async {
            // Play the browser: land Google's redirect on the loopback server
            // advertised in the consent URL, echoing its CSRF state. Fired
            // WITHOUT awaiting the reply — the flow starts listening only after
            // openUrl returns, exactly like a real browser racing xdg-open.
            final query = Uri.parse(url).queryParameters;
            final redirect = Uri.parse(query['redirect_uri']!);
            unawaited(
              _sendRequest(
                redirect.port,
                'GET /?code=the-code&state=${query['state']} HTTP/1.1\r\n'
                'Host: 127.0.0.1\r\n\r\n',
              ),
            );
          },
          exchange: (client, config, code, redirectUri, codeVerifier) async {
            expect(code, 'the-code');
            // Yield so a teardown scheduled too early gets its chance to run…
            await Future<void>.delayed(const Duration(milliseconds: 50));
            // …then prove the flow's client is still usable.
            await client.get(Uri.parse('http://127.0.0.1:${probe.port}/'));
            return const StoredTokens(
              accessToken: 'at',
              refreshToken: 'rt',
              accessExpiresAt: 1,
              scope: 'tasks',
            );
          },
        );

        expect(tokens.refreshToken, 'rt');
      },
    );
  });
}
