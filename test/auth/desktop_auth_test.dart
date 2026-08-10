// Desktop OAuth tests — ports of `flow.rs`'s parse_redirect / build_auth_url
// cases, plus the T6.1 wrapper tests that pin googleapis_auth's exchange
// behavior. What they protect: a denied or forged loopback redirect never
// yields a code; the consent URL Google receives carries the loopback redirect,
// PKCE challenge and CSRF state; the token exchange sends the desktop
// client_secret + PKCE verifier; and a response missing the refresh token fails
// the sign-in instead of leaving an unresumable session.

import 'dart:convert';

import 'package:axiotask/src/auth/auth_error.dart';
import 'package:axiotask/src/auth/desktop_auth.dart';
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
}
