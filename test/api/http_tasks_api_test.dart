// Port of `api/http.rs`'s in-file `mod tests`: the full enumerated wire-contract
// suite for the real Google Tasks client, driven against a scripted fake
// `http.Client` (see support/fake_authed_client.dart) instead of wiremock.
//
// Each test pins one verified-live wire rule (RFC-009). These are the ONLY
// guard against "optimizations" that keep the mocked suite green while silently
// breaking production sync — the If-Match policy split, the 403 body split, the
// showCompleted+showHidden requirement, pagination-to-completion, the bodyless
// move, and URL-encoding of page tokens.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/authed_client.dart';
import 'package:axiotask/src/api/http_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fake_authed_client.dart';

const String _base = 'https://mock.test/tasks/v1';

({FakeAuthedClient auth, HttpTasksApi api}) _build(
  ReplyHandler handler, {
  RefreshOutcome Function()? refresh,
  String token = 'token',
}) {
  final auth = FakeAuthedClient(handler, refresh: refresh, token: token);
  // maxRetries: 0 disables the backoff sleeps — every wire test runs instantly
  // and deterministically (parity with the reference's with_max_retries(0)).
  final api = HttpTasksApi(auth, baseUrl: _base, maxRetries: 0);
  return (auth: auth, api: api);
}

/// Run [action] and return whatever it throws (or null on success) — used where
/// a test needs both the error TYPE and a side effect (request count).
Future<Object?> _caught(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } on ApiError catch (e) {
    return e;
  }
}

void main() {
  // ─── Pure mapping helpers ──────────────────────────────────────────────────

  group('status + backoff mapping', () {
    test('backoff_grows_then_caps', () {
      expect(
        HttpTasksApi.backoff(1),
        greaterThanOrEqualTo(const Duration(milliseconds: 100)),
      );
      expect(
        HttpTasksApi.backoff(10),
        lessThanOrEqualTo(const Duration(seconds: 5)),
      );
      // Grows before the cap kicks in.
      expect(HttpTasksApi.backoff(2), greaterThan(HttpTasksApi.backoff(1)));
    });

    test('map_status_categorizes_correctly', () {
      expect(HttpTasksApi.mapStatus(401), isA<Unauthorized>());
      expect(HttpTasksApi.mapStatus(412), isA<PreconditionFailed>());
      expect(HttpTasksApi.mapStatus(409), isA<PreconditionFailed>());
      expect(HttpTasksApi.mapStatus(429), isA<RateLimited>());
      expect(HttpTasksApi.mapStatus(503), const ServerError(503));
      expect(HttpTasksApi.mapStatus(404), isA<NotFound>());
      expect(HttpTasksApi.mapStatus(418), isA<OtherApiError>());
    });
  });

  // ─── 401 → refresh-once semantics ─────────────────────────────────────────

  group('401 refresh-once', () {
    test('refresh_on_401_then_retry_succeeds', () async {
      final (:auth, :api) = _build(
        (req, i) => i == 0
            ? emptyReply(401)
            : jsonReply({
                'items': [
                  {
                    'id': 'L1',
                    'title': 'Inbox',
                    'updated': '2026-01-01T00:00:00Z',
                  },
                ],
              }),
      );

      final lists = await api.listTasklists();
      expect(lists.single.title, 'Inbox');
      expect(auth.refreshCount, 1, reason: 'exactly one refresh');
      // The retry carried the refreshed token.
      expect(
        auth.requests[1].headers['authorization'],
        'Bearer refreshed-token',
      );
    });

    test('refresh_on_401_still_fails_returns_unauthorized', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(401));

      await expectLater(api.listTasklists(), throwsA(isA<Unauthorized>()));
      expect(auth.refreshCount, 1);
      expect(
        auth.requests.length,
        2,
        reason: 'original + one post-refresh retry',
      );
    });

    test(
      'denied_refresh_surfaces_auth_expired_without_retrying_the_call',
      () async {
        final (:auth, :api) = _build(
          (req, i) => emptyReply(401),
          refresh: () => const RefreshDenied(
            'invalid_grant: Token has been expired or revoked.',
          ),
        );

        final err = await _caught(api.listTasklists);
        expect(err, isA<AuthExpired>());
        expect((err! as ApiError).isTransient, isFalse);
        expect(
          auth.requests.length,
          1,
          reason: 'no replay after a dead refresh',
        );
      },
    );

    test('transient_refresh_failure_maps_to_retryable_network_error', () async {
      final (:auth, :api) = _build(
        (req, i) => emptyReply(401),
        refresh: () => const RefreshTransient('token endpoint returned 503'),
      );

      final err = await _caught(api.listTasklists);
      expect(err, isA<Network>());
      expect((err! as ApiError).isTransient, isTrue);
      expect(auth.requests.length, 1);
    });
  });

  // ─── 403 body split ────────────────────────────────────────────────────────

  group('403 body split', () {
    test('quota_403_is_transient_rate_limit_not_permanent_rejection', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply(status: 403, {
          'error': {
            'code': 403,
            'message': 'Rate Limit Exceeded',
            'errors': [
              {'reason': 'rateLimitExceeded'},
            ],
          },
        }),
      );

      final err = await _caught(() => api.deleteTask('L1', 'T1'));
      expect(err, isA<RateLimited>());
      expect((err! as ApiError).isTransient, isTrue);
    });

    test('permission_403_stays_permanent', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply(status: 403, {
          'error': {
            'code': 403,
            'message': 'Insufficient Permission',
            'errors': [
              {'reason': 'insufficientPermissions'},
            ],
          },
        }),
      );

      final err = await _caught(() => api.deleteTask('L1', 'T1'));
      expect(err, isA<OtherApiError>());
      expect((err! as ApiError).isTransient, isFalse);
    });
  });

  // ─── Task lists ────────────────────────────────────────────────────────────

  group('task lists', () {
    test('list_tasklists_follows_pagination', () async {
      // Ghost detection treats this as the COMPLETE remote set — a dropped page
      // would locally delete the missing lists, tasks and all.
      final (:auth, :api) = _build((req, i) {
        if (req.url.queryParameters['pageToken'] == 'page2') {
          return jsonReply({
            'items': [
              {
                'id': 'L2',
                'title': 'Second',
                'updated': '2026-01-01T00:00:00Z',
              },
            ],
          });
        }
        return jsonReply({
          'items': [
            {'id': 'L1', 'title': 'First', 'updated': '2026-01-01T00:00:00Z'},
          ],
          'nextPageToken': 'page2',
        });
      });

      final lists = await api.listTasklists();
      expect(lists.map((l) => l.title).toList(), ['First', 'Second']);
      expect(auth.requests.length, 2);
    });

    test('insert_tasklist_sends_title_and_parses', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'L-new',
          'title': 'Work',
          'etag': 'e1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      final list = await api.insertTasklist('Work');
      expect(list.id, 'L-new');
      expect(list.title, 'Work');
      expect(list.etag, 'e1');
      expect((jsonDecodeMap(auth.requests.single.body))['title'], 'Work');
    });

    test('patch_tasklist_renames', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'L1',
          'title': 'Renamed',
          'etag': 'e2',
          'updated': '2026-01-02T00:00:00Z',
        }),
      );

      final list = await api.patchTasklist('L1', 'Renamed');
      expect(list.title, 'Renamed');
      expect(list.etag, 'e2');
    });

    test('patch_tasklist_sends_no_if_match', () async {
      // D6 / probe 8 (#106): the tasklists endpoint IGNORES If-Match — a stale
      // etag still returns 200. Sending the header would dress up a guarantee
      // the server does not offer; list renames are last-writer-wins by design.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'L1',
          'title': 'New Name',
          'etag': 'e2',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      await api.patchTasklist('L1', 'New Name');
      final req = auth.requests.single;
      expect(req.method, 'PATCH');
      expect(
        req.headers.containsKey('if-match'),
        isFalse,
        reason: 'list renames are last-writer-wins by server design (D6)',
      );
    });

    test('delete_tasklist_succeeds', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(204));
      await expectLater(api.deleteTasklist('L1'), completes);
      expect(auth.requests.single.method, 'DELETE');
    });

    test('delete_tasklist_404_maps_not_found', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(404));
      expect(await _caught(() => api.deleteTasklist('gone')), isA<NotFound>());
    });
  });

  // ─── Task listing / pagination ─────────────────────────────────────────────

  group('list tasks', () {
    test('list_tasks_parses_response_and_pagination', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'items': [
            {
              'id': 'T1',
              'title': 'first',
              'status': 'needsAction',
              'position': '00001',
              'updated': '2026-01-01T00:00:00Z',
            },
            {
              'id': 'T2',
              'title': 'done',
              'status': 'completed',
              'position': '00002',
              'updated': '2026-01-01T00:00:00Z',
            },
          ],
          'nextPageToken': 'page2',
        }),
      );

      final page = await api.listTasks('L1');
      expect(page.items.length, 2);
      expect(page.items[0].title, 'first');
      expect(page.items[1].status, TaskStatus.completed);
      expect(page.nextPageToken, 'page2');
    });

    test('list_tasks_asks_for_completed_and_hidden_tasks', () async {
      // Google auto-HIDES a completed task; showCompleted alone does not bring
      // it back — showHidden=true does. Drop either and ghost detection deletes
      // the local completed row. Pin both params on the wire.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'items': [
            {
              'id': 'T1',
              'title': 'done and hidden',
              'status': 'completed',
              'hidden': true,
              'position': '00001',
              'updated': '2026-01-01T00:00:00Z',
            },
          ],
        }),
      );

      final page = await api.listTasks('L1');
      expect(page.items.single.status, TaskStatus.completed);

      final q = auth.requests.single.url.queryParameters;
      expect(q['showCompleted'], 'true');
      expect(q['showHidden'], 'true');
      expect(q['maxResults'], '100');
    });

    test('list_tasks_passes_page_token', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({'items': <Object>[]}),
      );
      final page = await api.listTasks('L1', pageToken: 'tok-abc');
      expect(page.items, isEmpty);
      expect(auth.requests.single.url.queryParameters['pageToken'], 'tok-abc');
    });

    test('list_tasks_encodes_special_page_token', () async {
      // Google page tokens can contain +/=/space. They must round-trip, and the
      // encoding must use %20 for space (NOT '+') — the reference uses the
      // urlencoding crate; the wrong Dart encoder (encodeQueryComponent) would
      // emit '+' and both forms decode alike, so pin the raw wire form too.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({'items': <Object>[]}),
      );
      await api.listTasks('L1', pageToken: 'a b+c/d=e');

      final url = auth.requests.single.url;
      expect(
        url.queryParameters['pageToken'],
        'a b+c/d=e',
        reason: 'the special token round-trips',
      );
      expect(
        url.query,
        contains('pageToken=a%20b%2Bc%2Fd%3De'),
        reason: 'space encodes as %20, never +',
      );
    });
  });

  // ─── Single-task CRUD ──────────────────────────────────────────────────────

  group('task CRUD', () {
    test('insert_task_sends_body_and_parses_response', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'remote-1',
          'title': 'new task',
          'status': 'needsAction',
          'position': '00001',
          'etag': 'etag-1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      final task = await api.insertTask('L1', const NewTask(title: 'new task'));
      expect(task.id, 'remote-1');
      expect(task.etag, 'etag-1');

      final body = jsonDecodeMap(auth.requests.single.body);
      expect(body['title'], 'new task');
      expect(
        body['status'],
        'needsAction',
        reason: 'status defaults to needsAction',
      );
    });

    test('insert_task_sends_parent_and_previous_query', () async {
      // Placement rides the query string, not the body.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'T9',
          'title': 'child',
          'status': 'needsAction',
          'position': '1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      await api.insertTask(
        'L1',
        const NewTask(title: 'child', parent: 'P1', previous: 'T0'),
      );
      final q = auth.requests.single.url.queryParameters;
      expect(q['parent'], 'P1');
      expect(q['previous'], 'T0');
    });

    test('get_task_unknown_status_maps_to_other', () async {
      // TryFrom<TaskWire>: an unrecognized status string is a hard decode error,
      // never a silent default — a new Google status must fail loudly.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'T1',
          'title': 'weird',
          'status': 'someFutureStatus',
          'position': '1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      expect(
        await _caught(() => api.getTask('L1', 'T1')),
        isA<OtherApiError>(),
      );
    });

    test('a captive-portal HTML 200 fails to decode WITHOUT leaking the body '
        '(G6 / #204, #187)', () async {
      // A hotel/airport captive portal answers 200 with an HTML login page
      // instead of JSON. The decode fails — but the error message must NOT carry
      // the HTML body: OtherApiError.message rides verbatim onto the public sync
      // status (apiUserText → lastError), so a leaked body would surface a
      // secret-bearing URL to the user. The FormatException's toString() appends
      // an excerpt of the offending source (the body); only its message may ride.
      const captivePortalHtml =
          '<!DOCTYPE html><html><head><title>Wi-Fi Login</title></head>'
          '<body>Please sign in at http://wifi.local/login?token=SECRET'
          '</body></html>';
      final (:auth, :api) = _build(
        (req, i) => http.Response(
          captivePortalHtml,
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );

      final err = await _caught(() => api.listTasklists());
      expect(err, isA<OtherApiError>());
      final message = (err! as OtherApiError).message;
      expect(message, isNot(contains('<html')));
      expect(message, isNot(contains('wifi.local')));
      expect(message, isNot(contains('SECRET')));
      expect(
        message,
        contains('decode'),
        reason: 'still names the failing step for the log',
      );
    });

    test('patch_task_sends_if_match_etag', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'T1',
          'title': 'updated',
          'status': 'needsAction',
          'position': '1',
          'etag': 'etag-new',
          'updated': '2026-01-02T00:00:00Z',
        }),
      );

      final task = await api.patchTask(
        'L1',
        'T1',
        const TaskPatch(title: 'updated'),
        etag: 'etag-xyz',
      );
      expect(task.title, 'updated');
      expect(task.etag, 'etag-new');

      final req = auth.requests.single;
      expect(req.headers['if-match'], 'etag-xyz');
      final body = jsonDecodeMap(req.body);
      expect(body['title'], 'updated');
      expect(body.containsKey('status'), isFalse, reason: 'sparse patch');
    });

    test('patch_task_412_maps_to_precondition_failed', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(412));
      final err = await _caught(
        () => api.patchTask(
          'L1',
          'T1',
          const TaskPatch(title: 'x'),
          etag: 'stale',
        ),
      );
      expect(err, isA<PreconditionFailed>());
    });

    test('delete_task_succeeds', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(204));
      await expectLater(api.deleteTask('L1', 'T1'), completes);
      expect(auth.requests.single.method, 'DELETE');
    });

    test('delete_task_sends_no_if_match', () async {
      // P4: the delete is UNCONDITIONAL by choice — Google's DELETE honors
      // If-Match (stale etag → 412), but we send none so a concurrent edit can
      // never block a delete the user asked for.
      final (:auth, :api) = _build((req, i) => emptyReply(204));
      await api.deleteTask('L1', 'T1');
      expect(auth.requests.single.headers.containsKey('if-match'), isFalse);
    });

    test('delete_task_404_maps_to_not_found', () async {
      final (:auth, :api) = _build((req, i) => emptyReply(404));
      expect(
        await _caught(() => api.deleteTask('L1', 'gone')),
        isA<NotFound>(),
      );
    });
  });

  // ─── Move ──────────────────────────────────────────────────────────────────

  group('move', () {
    test('move_task_sends_parent_and_previous', () async {
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'T1',
          'title': 'moved',
          'status': 'needsAction',
          'parent': 'P1',
          'position': '1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      final task = await api.moveTask('L1', 'T1', parent: 'P1', previous: 'T0');
      expect(task.parent, 'P1');

      final req = auth.requests.single;
      expect(req.method, 'POST');
      expect(req.url.queryParameters['parent'], 'P1');
      expect(req.url.queryParameters['previous'], 'T0');
    });

    test('move_task_sends_an_explicit_content_length', () async {
      // A bodyless move POST must carry Content-Length: 0 (Google 411s without
      // it). package:http emits it natively for an empty body — the contract is
      // that the move sends NO body; pin it so a stray payload is caught.
      final (:auth, :api) = _build(
        (req, i) => jsonReply({
          'id': 'T1',
          'title': 'moved',
          'status': 'needsAction',
          'position': '1',
          'updated': '2026-01-01T00:00:00Z',
        }),
      );

      final task = await api.moveTask('L1', 'T1');
      expect(task.id, 'T1');

      final req = auth.requests.single;
      expect(req.method, 'POST');
      expect(req.body, isEmpty);
      expect(req.contentLength, 0);
    });
  });

  // ─── Transport failure ─────────────────────────────────────────────────────

  test('transport_error_maps_to_network', () async {
    final (:auth, :api) = _build((req, i) {
      throw http.ClientException('connection reset', req.url);
    });
    final err = await _caught(api.listTasklists);
    expect(err, isA<Network>());
    expect((err! as ApiError).isTransient, isTrue);
  });
}
