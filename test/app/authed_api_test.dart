// F3 (#177): the composition builders that mount the production AuthedClient
// under HttpTasksApi — the port of state.rs's build_http_client /
// build_provider_client. These prove the WIRING F5 depends on: a client built
// here really refreshes-once-and-retries on a 401 (desktop = token endpoint,
// Android = silent provider re-authorize), so the seam is not just a type that
// compiles but a working 401 recovery path.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/authed_api.dart';
import 'package:axiotask/src/auth/desktop_auth.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const _config = OAuthConfig(clientId: 'cid', clientSecret: 'secret');

class _Script {
  _Script(this._handler);
  final http.Response Function(http.Request req, int i) _handler;
  final List<http.Request> requests = <http.Request>[];
  late final http.Client client = MockClient((req) async {
    requests.add(req);
    return _handler(req, requests.length - 1);
  });
}

http.Response _listsReply() => http.Response(
  jsonEncode({
    'items': [
      {'id': 'L1', 'title': 'Inbox', 'updated': '2026-01-01T00:00:00Z'},
    ],
  }),
  200,
  headers: const {'content-type': 'application/json'},
);

void main() {
  test('buildDesktopTasksApi recovers a 401 via the token endpoint', () async {
    final apiClient = _Script(
      (req, i) => i == 0 ? http.Response('', 401) : _listsReply(),
    );
    final refreshClient = _Script(
      (req, i) => http.Response(
        jsonEncode({
          'token_type': 'Bearer',
          'access_token': 'fresh-desktop',
          'expires_in': 3600,
          'scope': 'tasks',
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    final api = buildDesktopTasksApi(
      tokens: const StoredTokens(
        accessToken: 'old',
        refreshToken: 'rt',
        scope: 'tasks',
      ),
      config: _config,
      store: InMemoryTokenStore(),
      apiClient: apiClient.client,
      refreshClient: refreshClient.client,
    );

    final lists = await api.listTasklists();

    expect(lists.single.title, 'Inbox');
    expect(refreshClient.requests.length, 1, reason: 'refreshed once');
    expect(
      apiClient.requests[1].headers['authorization'],
      'Bearer fresh-desktop',
    );
  });

  test(
    'buildAndroidTasksApi recovers a 401 via a silent re-authorize',
    () async {
      final apiClient = _Script(
        (req, i) => i == 0 ? http.Response('', 401) : _listsReply(),
      );
      final provider = FakeTokenProvider.withToken('fresh-android');

      final api = buildAndroidTasksApi(
        accessToken: 'android-old',
        provider: provider,
        apiClient: apiClient.client,
      );

      final lists = await api.listTasklists();

      expect(lists.single.title, 'Inbox');
      expect(provider.calls, <bool>[false], reason: 'one SILENT re-authorize');
      expect(
        apiClient.requests[1].headers['authorization'],
        'Bearer fresh-android',
      );
    },
  );

  // G2 / #203: the safe desktop rebuild reads the bundle back without a
  // force-unwrap. A tokens.json that vanished or was corrupted since the session
  // was established returns null — NOT a crashing `store.load()!` — so the
  // composition root can flip to needs-reauth instead of throwing.
  group('buildDesktopTasksApiFromStore (G2 / #203)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_g2_api'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('builds a client when the persisted bundle is present', () {
      final store = InMemoryTokenStore()
        ..save(
          const StoredTokens(
            accessToken: 'a',
            refreshToken: 'rt',
            scope: 'tasks',
          ),
        );

      expect(
        buildDesktopTasksApiFromStore(store: store, config: _config),
        isNotNull,
      );
    });

    test('returns null (no throw) when tokens.json is gone', () {
      // A FileTokenStore whose file was never written — load() is null.
      final store = FileTokenStore(File(p.join(tmp.path, 'tokens.json')));

      expect(
        buildDesktopTasksApiFromStore(store: store, config: _config),
        isNull,
      );
    });

    test('returns null (no TokenStoreException escapes) when corrupt', () {
      final file = File(p.join(tmp.path, 'tokens.json'))
        ..writeAsStringSync('{ not valid json');
      final store = FileTokenStore(file);
      // Confirm the store itself would throw on this input, so the null is the
      // builder swallowing it, not an empty file.
      expect(store.load, throwsA(isA<Exception>()));

      expect(
        buildDesktopTasksApiFromStore(store: store, config: _config),
        isNull,
      );
    });
  });
}
