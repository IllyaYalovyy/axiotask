// F3 (#177): the production [AuthedClient] — the 401→refresh-once→retry seam
// backed for real on both platforms. The reference is `auth/client.rs`
// (`AuthedClient` + `parse_refresh_response`) driven through `api/http.rs`.
//
// These tests protect the behaviors #177 calls out and whose absence would
// return the 401 retry-storm / dead-session-forever class of bug:
//  - a 401 refreshes EXACTLY once and replays the call with the fresh token,
//  - a second 401 after the refresh does NOT loop,
//  - a permanent denial (invalid_grant on desktop / interaction-required on
//    Android) becomes `AuthExpired` and the call is NOT replayed — the sole
//    origin of the sticky `needsReauth` state,
//  - a transient refresh failure stays retryable (`Network`),
//  - the refreshed token is persisted (store) AND adopted (memory),
//  - a proactively-expired access token refreshes before the send, so no
//    guaranteed-401 round trip is wasted,
//  - NO token material (access or refresh) ever leaks into an error string.
//
// Everything runs against a scripted `http.Client` (MockClient) and the
// headless [FakeTokenProvider]; no browser, no Play Services, no network.

import 'dart:convert';

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/authed_client.dart';
import 'package:axiotask/src/api/http_tasks_api.dart';
import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/production_authed_client.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _config = OAuthConfig(clientId: 'cid', clientSecret: 'secret');
const _base = 'https://mock.test/tasks/v1';

/// A recording [MockClient]: replies per 0-based call index and keeps every
/// finalized request (headers included) for wire assertions.
class _Script {
  _Script(this._handler);

  final http.Response Function(http.Request req, int callIndex) _handler;
  final List<http.Request> requests = <http.Request>[];

  late final http.Client client = MockClient((req) async {
    requests.add(req);
    return _handler(req, requests.length - 1);
  });
}

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

/// A successful token-endpoint reply (googleapis_auth shape).
http.Response _tokenOk(String access, {int expiresIn = 3600}) => _json({
  'token_type': 'Bearer',
  'access_token': access,
  'expires_in': expiresIn,
  'scope': 'tasks',
});

StoredTokens _initial({int? exp, String rt = 'rt', String at = 'old-access'}) =>
    StoredTokens(
      accessToken: at,
      refreshToken: rt,
      accessExpiresAt: exp,
      scope: 'tasks',
    );

String? _bearer(http.Request req) => req.headers['authorization'];

void main() {
  // ── Desktop refresh: classification + persistence (over googleapis_auth) ────

  group('desktop refresh', () {
    test(
      'refreshNow persists the refreshed token to store AND memory',
      () async {
        final store = InMemoryTokenStore()..save(_initial(exp: 0));
        final refresh = _Script((req, i) => _tokenOk('fresh-access'));
        final api = _Script((req, i) => _json(const <String, Object?>{}));
        final client = ProductionAuthedClient(
          transport: api.client,
          initialTokens: _initial(exp: 0),
          store: store,
          refresh: desktopRefreshFn(
            config: _config,
            refreshClient: refresh.client,
          ),
        );

        final outcome = await client.refreshNow();

        expect(outcome, isA<RefreshOk>());
        expect(
          refresh.requests.length,
          1,
          reason: 'exactly one token exchange',
        );
        // Persisted.
        expect(store.load()!.accessToken, 'fresh-access');
        expect(store.load()!.accessExpiresAt, isNotNull);
        expect(
          store.load()!.refreshToken,
          'rt',
          reason: 'refresh token retained',
        );
        // Adopted in memory: the next send carries the new bearer.
        await client.send(http.Request('GET', Uri.parse('https://x/y')));
        expect(_bearer(api.requests.single), 'Bearer fresh-access');
      },
    );

    test(
      'invalid_grant maps to RefreshDenied and leaves the store untouched',
      () async {
        final store = InMemoryTokenStore()..save(_initial(at: 'keep'));
        final refresh = _Script(
          (req, i) => _json(const {
            'error': 'invalid_grant',
            'error_description': 'Token has been expired or revoked.',
          }, status: 400),
        );
        final client = ProductionAuthedClient(
          transport: _Script((req, i) => _json(const {})).client,
          initialTokens: _initial(at: 'keep'),
          store: store,
          refresh: desktopRefreshFn(
            config: _config,
            refreshClient: refresh.client,
          ),
        );

        final outcome = await client.refreshNow();

        expect(outcome, isA<RefreshDenied>());
        expect(store.load()!.accessToken, 'keep', reason: 'no write on denial');
      },
    );

    test('5xx and non-grant OAuth errors map to RefreshTransient', () async {
      Future<RefreshOutcome> refreshWith(http.Response reply) async {
        final client = ProductionAuthedClient(
          transport: _Script((req, i) => _json(const {})).client,
          initialTokens: _initial(),
          store: InMemoryTokenStore(),
          refresh: desktopRefreshFn(
            config: _config,
            refreshClient: MockClient((req) async => reply),
          ),
        );
        return client.refreshNow();
      }

      // A token-endpoint 5xx — a hiccup, retry later.
      expect(
        await refreshWith(_json(const {'error': 'backend'}, status: 503)),
        isA<RefreshTransient>(),
      );
      // An OAuth error code that is NOT grant-level stays retryable.
      expect(
        await refreshWith(
          _json(const {'error': 'temporarily_unavailable'}, status: 400),
        ),
        isA<RefreshTransient>(),
      );
    });

    test(
      'a network failure at the token endpoint maps to RefreshTransient',
      () async {
        final client = ProductionAuthedClient(
          transport: _Script((req, i) => _json(const {})).client,
          initialTokens: _initial(),
          store: InMemoryTokenStore(),
          refresh: desktopRefreshFn(
            config: _config,
            refreshClient: MockClient(
              (req) async => throw http.ClientException('connection refused'),
            ),
          ),
        );

        expect(await client.refreshNow(), isA<RefreshTransient>());
      },
    );

    test('no token material leaks into a refresh error string', () async {
      const secretRt = 'SECRET-RT-9f3a-do-not-log';
      const secretAt = 'SECRET-AT-do-not-log';

      // Denied path.
      final denied = await ProductionAuthedClient(
        transport: _Script((req, i) => _json(const {})).client,
        initialTokens: _initial(at: secretAt, rt: secretRt),
        store: InMemoryTokenStore(),
        refresh: desktopRefreshFn(
          config: _config,
          refreshClient: MockClient(
            (req) async => _json(const {
              'error': 'invalid_grant',
              'error_description': 'revoked',
            }, status: 400),
          ),
        ),
      ).refreshNow();
      expect(denied, isA<RefreshDenied>());
      final deniedMsg = (denied as RefreshDenied).message;
      expect(deniedMsg, isNot(contains(secretRt)));
      expect(deniedMsg, isNot(contains(secretAt)));

      // Transient path.
      final transient = await ProductionAuthedClient(
        transport: _Script((req, i) => _json(const {})).client,
        initialTokens: _initial(at: secretAt, rt: secretRt),
        store: InMemoryTokenStore(),
        refresh: desktopRefreshFn(
          config: _config,
          refreshClient: MockClient(
            (req) async => _json(const {'error': 'server_error'}, status: 503),
          ),
        ),
      ).refreshNow();
      expect(transient, isA<RefreshTransient>());
      final transientMsg = (transient as RefreshTransient).message;
      expect(transientMsg, isNot(contains(secretRt)));
      expect(transientMsg, isNot(contains(secretAt)));
    });
  });

  // ── Desktop end-to-end through HttpTasksApi: the 401 seam ───────────────────

  group('desktop 401 seam', () {
    HttpTasksApi apiOver(_Script transport, _Script refresh, {int? exp}) {
      final client = ProductionAuthedClient(
        transport: transport.client,
        initialTokens: _initial(exp: exp),
        store: InMemoryTokenStore()..save(_initial(exp: exp)),
        refresh: desktopRefreshFn(
          config: _config,
          refreshClient: refresh.client,
        ),
      );
      return HttpTasksApi(client, baseUrl: _base, maxRetries: 0);
    }

    test('401 refreshes once and replays with the fresh token', () async {
      final transport = _Script(
        (req, i) => i == 0
            ? http.Response('', 401)
            : _json({
                'items': [
                  {
                    'id': 'L1',
                    'title': 'Inbox',
                    'updated': '2026-01-01T00:00:00Z',
                  },
                ],
              }),
      );
      final refresh = _Script((req, i) => _tokenOk('fresh-access'));

      final lists = await apiOver(transport, refresh).listTasklists();

      expect(lists.single.title, 'Inbox');
      expect(refresh.requests.length, 1, reason: 'exactly one refresh');
      expect(transport.requests.length, 2, reason: 'original + one replay');
      expect(_bearer(transport.requests[1]), 'Bearer fresh-access');
    });

    test('a second 401 after the refresh does NOT loop', () async {
      final transport = _Script((req, i) => http.Response('', 401));
      final refresh = _Script((req, i) => _tokenOk('fresh-access'));

      await expectLater(
        apiOver(transport, refresh).listTasklists(),
        throwsA(isA<Unauthorized>()),
      );
      expect(refresh.requests.length, 1, reason: 'refresh only once');
      expect(transport.requests.length, 2, reason: 'no third attempt');
    });

    test('a denied refresh surfaces AuthExpired and does not replay', () async {
      final transport = _Script((req, i) => http.Response('', 401));
      final refresh = _Script(
        (req, i) => _json(const {
          'error': 'invalid_grant',
          'error_description': 'Token has been expired or revoked.',
        }, status: 400),
      );

      final api = apiOver(transport, refresh);
      Object? caught;
      try {
        await api.listTasklists();
      } on ApiError catch (e) {
        caught = e;
      }
      expect(caught, isA<AuthExpired>());
      expect(
        transport.requests.length,
        1,
        reason: 'no replay after a dead refresh',
      );
    });

    test(
      'proactive: an expired access token refreshes before the send',
      () async {
        // exp in the past; a fixed clock past it → send() must refresh first, so
        // the API request carries the FRESH token and no 401 is ever needed.
        final transport = _Script(
          (req, i) => _json({
            'items': [
              {'id': 'L1', 'title': 'Inbox', 'updated': '2026-01-01T00:00:00Z'},
            ],
          }),
        );
        final refresh = _Script((req, i) => _tokenOk('fresh-access'));
        final client = ProductionAuthedClient(
          transport: transport.client,
          initialTokens: _initial(exp: 100),
          store: InMemoryTokenStore()..save(_initial(exp: 100)),
          refresh: desktopRefreshFn(
            config: _config,
            refreshClient: refresh.client,
          ),
          nowEpoch: () => 200,
        );

        await HttpTasksApi(
          client,
          baseUrl: _base,
          maxRetries: 0,
        ).listTasklists();

        expect(
          refresh.requests.length,
          1,
          reason: 'proactive refresh happened',
        );
        expect(
          transport.requests.length,
          1,
          reason: 'no wasted guaranteed-401',
        );
        expect(_bearer(transport.requests.single), 'Bearer fresh-access');
      },
    );

    test('no proactive refresh when the expiry is unknown (null)', () async {
      final transport = _Script(
        (req, i) => _json(const {'items': <Object?>[]}),
      );
      final refresh = _Script((req, i) => _tokenOk('unexpected'));
      final client = ProductionAuthedClient(
        transport: transport.client,
        initialTokens: _initial(exp: null),
        store: InMemoryTokenStore(),
        refresh: desktopRefreshFn(
          config: _config,
          refreshClient: refresh.client,
        ),
        nowEpoch: () => 9999999999,
      );

      await client.send(http.Request('GET', Uri.parse('https://x/y')));

      expect(
        refresh.requests,
        isEmpty,
        reason: 'unknown expiry → never proactive',
      );
      expect(_bearer(transport.requests.single), 'Bearer old-access');
    });
  });

  // ── Android: silent re-authorize on 401 (Play Services owns the grant) ──────

  group('android provider seam', () {
    HttpTasksApi apiOver(_Script transport, TokenProvider provider) {
      final client = ProductionAuthedClient.android(
        transport: transport.client,
        accessToken: 'android-old',
        provider: provider,
      );
      return HttpTasksApi(client, baseUrl: _base, maxRetries: 0);
    }

    test('401 silently re-authorizes and replays with the new token', () async {
      final transport = _Script(
        (req, i) => i == 0
            ? http.Response('', 401)
            : _json({
                'items': [
                  {
                    'id': 'L1',
                    'title': 'Inbox',
                    'updated': '2026-01-01T00:00:00Z',
                  },
                ],
              }),
      );
      final provider = FakeTokenProvider.withToken('android-fresh');

      final lists = await apiOver(transport, provider).listTasklists();

      expect(lists.single.title, 'Inbox');
      expect(provider.calls, <bool>[
        false,
      ], reason: 'exactly one SILENT re-authorize');
      expect(_bearer(transport.requests[1]), 'Bearer android-fresh');
    });

    test(
      'a silent interaction-required maps to AuthExpired without replay',
      () async {
        final transport = _Script((req, i) => http.Response('', 401));
        final provider = FakeTokenProvider.needsInteraction();

        final api = apiOver(transport, provider);
        Object? caught;
        try {
          await api.listTasklists();
        } on ApiError catch (e) {
          caught = e;
        }
        expect(caught, isA<AuthExpired>());
        expect(provider.calls, <bool>[
          false,
        ], reason: 'silent only — never prompts');
        expect(
          transport.requests.length,
          1,
          reason: 'no replay after a dead grant',
        );
      },
    );

    test(
      'a transient Play Services outage maps to a retryable Network error',
      () async {
        final transport = _Script((req, i) => http.Response('', 401));
        final provider = FakeTokenProvider.unavailable('gms updating');

        final api = apiOver(transport, provider);
        Object? caught;
        try {
          await api.listTasklists();
        } on ApiError catch (e) {
          caught = e;
        }
        expect(caught, isA<Network>());
        expect((caught! as ApiError).isTransient, isTrue);
        expect(transport.requests.length, 1);
      },
    );

    test(
      'never refreshes proactively (unknown expiry) — only on 401',
      () async {
        final transport = _Script(
          (req, i) => _json(const {'items': <Object?>[]}),
        );
        final provider = FakeTokenProvider.withToken('should-not-be-used');
        final client = ProductionAuthedClient.android(
          transport: transport.client,
          accessToken: 'android-old',
          provider: provider,
        );

        await client.send(http.Request('GET', Uri.parse('https://x/y')));

        expect(
          provider.calls,
          isEmpty,
          reason: 'no silent fetch without a 401',
        );
        expect(_bearer(transport.requests.single), 'Bearer android-old');
      },
    );
  });
}
