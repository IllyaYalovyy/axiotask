// Real [TasksApi] backed by `package:http` against the Google Tasks v1 REST
// API — the Dart port of `api/http.rs`.
//
// Authentication is delegated to [AuthedClient] (the `Authorization` header and
// refresh-on-401). This module owns everything else:
//  - URL construction and query/id URL-encoding,
//  - request/response (de)serialization,
//  - mapping HTTP status → [ApiError] (incl. the load-bearing 403 body split),
//  - pagination to completion on both list endpoints,
//  - exponential backoff (honoring `Retry-After`) on 5xx / 429, and on a
//    transport failure for the idempotent calls only — a create is never
//    replayed at the transport level (#266).
//
// The wire rules below are verified-live invariants (RFC-009); each is pinned
// by a named test in `http_tasks_api_test.dart`. Loosening any of them silently
// breaks production sync while the mocked suite stays green.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../model/page.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'api_error.dart';
import 'authed_client.dart';
import 'tasks_api.dart';

/// The real Google endpoint.
const String _baseUrl = 'https://tasks.googleapis.com/tasks/v1';

/// HTTP-backed Google Tasks client.
class HttpTasksApi implements TasksApi {
  /// Construct against [baseUrl] (defaults to the real Google endpoint). Tests
  /// point [baseUrl] at a scripted fake and set [maxRetries] to 0 to disable
  /// the backoff sleeps.
  HttpTasksApi(this._auth, {this.baseUrl = _baseUrl, this.maxRetries = 4});

  final AuthedClient _auth;

  /// Base URL of the Tasks API (the real endpoint, or a scripted fake in tests).
  final String baseUrl;

  /// Extra attempts on a transient error before giving up (0 disables retry).
  final int maxRetries;

  // ── Auth + retry wrappers ─────────────────────────────────────────────────

  /// Send with retry; on a 401 refresh the token and retry exactly once. A
  /// permanent refresh denial (`invalid_grant`) becomes [AuthExpired] — the
  /// sync engine's abort signal — and the original call is NOT replayed; a
  /// transient refresh failure becomes [Network] so the next run retries.
  ///
  /// A 401 is a RESPONSE, and one refused before the server acted on the
  /// request, so replaying it after a refresh is safe even for a create —
  /// unlike a transport failure, which [idempotent] governs (see
  /// [_sendWithRetry]).
  ///
  /// [build] must produce a FRESH [http.Request] on each call: a request body
  /// is single-shot, and rebuilding lets the post-refresh retry pick up the new
  /// token.
  Future<http.Response> _sendAuthed(
    http.Request Function() build, {
    required bool idempotent,
  }) async {
    try {
      return await _sendWithRetry(build, idempotent: idempotent);
    } on Unauthorized {
      final outcome = await _auth.refreshNow();
      return switch (outcome) {
        RefreshOk() => await _sendWithRetry(build, idempotent: idempotent),
        RefreshDenied(:final message) => throw AuthExpired(message),
        RefreshTransient(:final message) => throw Network(
          'token refresh: $message',
        ),
      };
    }
  }

  /// Retry loop: retry transient STATUSES up to [maxRetries] extra attempts,
  /// honoring a server `Retry-After` else exponential backoff. Non-transient
  /// errors return (throw) immediately.
  ///
  /// Transport failures — no response at all — are retried only when
  /// [idempotent] is true. A lost response is NOT a lost request: when the
  /// socket dies after Google read a create, the insert may already be
  /// committed, and replaying it makes a SECOND task/list under an id we never
  /// learn — a duplicate the in-flight marker can never see, because the call
  /// ends up "succeeding" (#266). So a create raises [Network] on the first
  /// transport failure; that transient is what the engine turns into
  /// `KeepInflight`, which adopts the orphan on the next run (§G). GET, PATCH,
  /// DELETE and move are safe to repeat and keep retrying.
  ///
  /// [idempotent] is deliberately required, with no default: a new endpoint
  /// must state its replay policy rather than inherit a duplicating one.
  Future<http.Response> _sendWithRetry(
    http.Request Function() build, {
    required bool idempotent,
  }) async {
    var attempt = 0;
    while (true) {
      late final http.Response resp;
      try {
        resp = await _auth.send(build());
      } on Exception catch (e) {
        if (!idempotent || attempt >= maxRetries) {
          throw Network(e.toString());
        }
        attempt += 1;
        await Future<void>.delayed(backoff(attempt));
        continue;
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return resp;
      }
      // Read the Retry-After hint before the body decision.
      final retryAfter = _retryAfterFrom(resp.headers);
      // The body is load-bearing on the error path: it tells a quota 403
      // (transient) from a permission 403 (permanent), and — since every real
      // Tasks API error body is JSON — it tells a Google rejection from an
      // interception proxy answering in its place (#270).
      final err = mapStatusWithBody(resp.statusCode, _bodyText(resp));
      // A non-JSON body classifies as [Network] (#270), and it is transient for
      // exactly the reason a dead socket is: Google's answer never reached us,
      // so we cannot know whether the REQUEST reached Google. That makes it a
      // lost response, not a declined one — and a create must not be replayed
      // on a lost response (#266) or the user gets a duplicate under an id this
      // device never learns. It raises here instead, so the in-flight marker
      // survives and the next run adopts the orphan. A 429/5xx stays a genuine
      // "the server declined" and keeps retrying, inserts included.
      final lostResponse = err is Network;
      if (!err.isTransient ||
          attempt >= maxRetries ||
          (lostResponse && !idempotent)) {
        throw err;
      }
      attempt += 1;
      await Future<void>.delayed(retryAfter ?? backoff(attempt));
    }
  }

  // ── Status mapping + backoff (static; pinned by the enumerated wire tests) ─

  /// Map an HTTP status to an [ApiError] with an empty body.
  static ApiError mapStatus(int status) => mapStatusWithBody(status, '');

  /// Map an HTTP status to an [ApiError], using the error body to split 403:
  /// Google signals per-user rate limiting and quota exhaustion as 403 (reasons
  /// like `rateLimitExceeded` / `quotaExceeded`), which must be treated as
  /// transient-with-backoff — while a permission 403 (revoked scope) is
  /// permanent. Treating quota 403s as permanent would mark every pending
  /// change "rejected" the moment a burst hits the quota. 409 AND 412 both map
  /// to [PreconditionFailed].
  static ApiError mapStatusWithBody(int status, String body) {
    switch (status) {
      case 401:
        return const Unauthorized();
      case 403:
        if (_isRateLimitBody(body)) return const RateLimited();
        return _notJson(body)
            ? const Network('403 with a non-JSON body')
            : OtherApiError('403 forbidden: ${_bodyReason(body)}');
      case 404:
        return const NotFound();
      case 409:
      case 412:
        return const PreconditionFailed();
      case 429:
        return const RateLimited();
      default:
        if (status >= 500 && status <= 599) {
          return ServerError(status);
        }
        // A status Google would answer with a JSON error body, answered with
        // something else: nothing here came from the Tasks API, so it says
        // nothing about the request and must NOT permanently reject the row
        // (#270). Only the classification differs — the body still never rides
        // on the message (#187).
        return _notJson(body)
            ? Network('$status with a non-JSON body')
            : OtherApiError('unexpected status $status');
    }
  }

  /// 100ms doubling per attempt, capped at 5s (mirrors `http.rs::backoff`).
  static Duration backoff(int attempt) {
    final shift = attempt < 6 ? attempt : 6;
    final ms = 100 * (1 << shift);
    return Duration(milliseconds: ms > 5000 ? 5000 : ms);
  }

  /// Whether [body] is present but is not JSON at all — the signature of a
  /// captive portal or interception proxy answering for Google with an HTML
  /// login page. Every real Tasks API response body, success or error, is JSON.
  /// An EMPTY body is not evidence of anything and stays classified by status.
  static bool _notJson(String body) {
    if (body.trim().isEmpty) return false;
    try {
      jsonDecode(body);
      return false;
    } on FormatException {
      return true;
    }
  }

  static bool _isRateLimitBody(String body) => const [
    'rateLimitExceeded',
    'userRateLimitExceeded',
    'quotaExceeded',
    'dailyLimitExceeded',
  ].any(body.contains);

  static String _bodyReason(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = (decoded as Map?)?['error'];
      final message = (error as Map?)?['message'];
      if (message is String) {
        return message;
      }
    } on FormatException {
      // Fall through to the default.
    }
    return 'permission denied';
  }

  static Duration? _retryAfterFrom(Map<String, String> headers) {
    final value = headers['retry-after'];
    if (value == null) {
      return null;
    }
    final seconds = int.tryParse(value);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  // ── Request builders ──────────────────────────────────────────────────────

  http.Request _get(Uri uri) => http.Request('GET', uri);

  http.Request _delete(Uri uri) => http.Request('DELETE', uri);

  http.Request _json(String method, Uri uri, Map<String, Object?> body) {
    final req = http.Request(method, uri)
      ..headers['content-type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode(body);
    return req;
  }

  // ── Body decoding ─────────────────────────────────────────────────────────

  String _bodyText(http.Response resp) =>
      utf8.decode(resp.bodyBytes, allowMalformed: true);

  Map<String, Object?> _decodeMap(http.Response resp, String label) {
    Object? decoded;
    try {
      decoded = jsonDecode(_bodyText(resp));
    } on FormatException catch (e) {
      // A 200 whose body is not JSON did not come from the Tasks API — it came
      // from whatever is between us and Google (a captive portal's login page).
      // That is a TRANSPORT fault, transient: it clears itself when the user
      // signs in to the network, and classifying it as a permanent rejection
      // marked their pending changes "rejected by the server" and drove the
      // needs-attention backoff for a condition no user action here can fix
      // (#270). A body that IS json but the wrong shape is a real API contract
      // break and stays permanent — see _taskFromWire below.
      //
      // Use the FormatException MESSAGE, never its toString(): toString()
      // appends an excerpt of the offending SOURCE — here that excerpt IS the
      // response body, and the message rides into the log (G6 / #204, #187).
      throw Network('decode $label: ${e.message}');
    }
    return (decoded as Map?)?.cast<String, Object?>() ??
        const <String, Object?>{};
  }

  Task _taskFromWire(Map<String, Object?> json, String label) {
    try {
      return Task.fromJson(json);
    } on FormatException catch (e) {
      throw OtherApiError('decode $label: ${e.message}');
    }
  }

  // ── TasksApi implementation ───────────────────────────────────────────────

  @override
  Future<List<TaskList>> listTasklists() async {
    // Paginate to completion: ghost detection treats this as the COMPLETE set
    // of remote lists — silently dropping a page would delete the missing lists
    // locally, tasks and all. maxResults=100 keeps the request count low.
    final out = <TaskList>[];
    String? pageToken;
    while (true) {
      final buffer = StringBuffer('$baseUrl/users/@me/lists?maxResults=100');
      if (pageToken != null) {
        buffer.write('&pageToken=${_enc(pageToken)}');
      }
      final url = Uri.parse(buffer.toString());
      final resp = await _sendAuthed(() => _get(url), idempotent: true);
      final map = _decodeMap(resp, 'lists');
      final items = (map['items'] as List?) ?? const [];
      for (final item in items) {
        out.add(TaskList.fromJson((item as Map).cast<String, Object?>()));
      }
      final next = map['nextPageToken'];
      if (next is String) {
        pageToken = next;
      } else {
        return out;
      }
    }
  }

  @override
  Future<TaskList> insertTasklist(String title) async {
    final url = Uri.parse('$baseUrl/users/@me/lists');
    // NOT idempotent: a replayed list create leaves the user with two lists of
    // the same name and no way to tell which one the app adopted (#266).
    final resp = await _sendAuthed(
      () => _json('POST', url, {'title': title}),
      idempotent: false,
    );
    return TaskList.fromJson(_decodeMap(resp, 'list insert'));
  }

  // NOTE: no If-Match — the tasklists endpoint IGNORES it (a stale etag still
  // returns 200; verified live, probe 8/#106), so list renames are
  // last-writer-wins by server design and list conflict detection is impossible
  // (forces D6). Sending the header would dress up a guarantee the server does
  // not offer.
  @override
  Future<TaskList> patchTasklist(String id, String title) async {
    final url = Uri.parse('$baseUrl/users/@me/lists/${_enc(id)}');
    final resp = await _sendAuthed(
      () => _json('PATCH', url, {'title': title}),
      idempotent: true,
    );
    return TaskList.fromJson(_decodeMap(resp, 'list patch'));
  }

  @override
  Future<void> deleteTasklist(String id) async {
    final url = Uri.parse('$baseUrl/users/@me/lists/${_enc(id)}');
    await _sendAuthed(() => _delete(url), idempotent: true);
  }

  @override
  Future<Page<Task>> listTasks(String listId, {String? pageToken}) async {
    // maxResults=100 (the maximum): the default page size is 20. Both
    // showCompleted AND showHidden are required — Google auto-hides completed
    // tasks, and dropping either param makes them vanish from the pull, at which
    // point ghost detection would delete the local completed history.
    final buffer = StringBuffer(
      '$baseUrl/lists/$listId/tasks?showCompleted=true&showHidden=true&maxResults=100',
    );
    if (pageToken != null) {
      buffer.write('&pageToken=${_enc(pageToken)}');
    }
    final url = Uri.parse(buffer.toString());
    final resp = await _sendAuthed(() => _get(url), idempotent: true);
    final map = _decodeMap(resp, 'tasks');
    final rawItems = (map['items'] as List?) ?? const [];
    final items = <Task>[];
    for (final item in rawItems) {
      items.add(_taskFromWire((item as Map).cast<String, Object?>(), 'tasks'));
    }
    final next = map['nextPageToken'];
    return Page(items: items, nextPageToken: next is String ? next : null);
  }

  @override
  Future<Task> insertTask(String listId, NewTask task) async {
    final buffer = StringBuffer('$baseUrl/lists/$listId/tasks');
    final parent = task.parent;
    final previous = task.previous;
    if (parent != null) {
      buffer.write('?parent=${_enc(parent)}');
      if (previous != null) {
        buffer.write('&previous=${_enc(previous)}');
      }
    } else if (previous != null) {
      buffer.write('?previous=${_enc(previous)}');
    }
    final url = Uri.parse(buffer.toString());
    // parent/previous ride the query string; the body carries the fields
    // (explicit nulls mirror the reference wire — Google ignores them).
    final body = <String, Object?>{
      'title': task.title,
      'notes': task.notes,
      'due': task.due,
      'status': (task.status ?? TaskStatus.needsAction).apiStr,
    };
    // NOT idempotent: the create is the one call a transport retry can
    // duplicate server-side. A lost response leaves the engine's in-flight
    // marker to adopt the orphan on the next run (#266).
    final resp = await _sendAuthed(
      () => _json('POST', url, body),
      idempotent: false,
    );
    return _taskFromWire(_decodeMap(resp, 'insert'), 'insert');
  }

  @override
  Future<Task> getTask(String listId, String id) async {
    final url = Uri.parse('$baseUrl/lists/${_enc(listId)}/tasks/${_enc(id)}');
    final resp = await _sendAuthed(() => _get(url), idempotent: true);
    return _taskFromWire(_decodeMap(resp, 'get'), 'get');
  }

  @override
  Future<Task> patchTask(
    String listId,
    String id,
    TaskPatch patch, {
    String? etag,
  }) async {
    final url = Uri.parse('$baseUrl/lists/$listId/tasks/$id');
    // Idempotent: re-applying the same field set lands the same state, and
    // with If-Match a replay that raced a committed first attempt answers 412
    // rather than writing twice.
    final resp = await _sendAuthed(() {
      final req = _json('PATCH', url, patch.toJson());
      if (etag != null) {
        req.headers['if-match'] = etag;
      }
      return req;
    }, idempotent: true);
    return _taskFromWire(_decodeMap(resp, 'patch'), 'patch');
  }

  @override
  Future<void> deleteTask(String listId, String id) async {
    // Deliberately unconditional: no If-Match (P4). Google's DELETE *does*
    // honor If-Match (a stale etag → 412), but we send none so a concurrent
    // remote edit can never block a delete the user asked for.
    final url = Uri.parse('$baseUrl/lists/$listId/tasks/$id');
    await _sendAuthed(() => _delete(url), idempotent: true);
  }

  @override
  Future<Task> moveTask(
    String listId,
    String id, {
    String? parent,
    String? previous,
  }) async {
    final buffer = StringBuffer('$baseUrl/lists/$listId/tasks/$id/move');
    var sep = '?';
    if (parent != null) {
      buffer.write('${sep}parent=${_enc(parent)}');
      sep = '&';
    }
    if (previous != null) {
      buffer.write('${sep}previous=${_enc(previous)}');
    }
    final url = Uri.parse(buffer.toString());
    // Bodyless POST — the move endpoint takes everything in the query string.
    // The live endpoint answers 411 Length Required to a POST without a
    // Content-Length; package:http emits Content-Length: 0 for an empty body
    // natively (unlike reqwest, which omits it — the reference had to set it by
    // hand). The empty body is the contract; the move_task test pins it.
    // A POST, but idempotent: move is a placement, not a creation — repeating
    // it puts the same task in the same slot.
    final resp = await _sendAuthed(
      () => http.Request('POST', url),
      idempotent: true,
    );
    return _taskFromWire(_decodeMap(resp, 'move'), 'move');
  }

  /// URL-encode a path/query component. `Uri.encodeComponent` percent-encodes
  /// with `%20` for space (never `+`), matching the reference `urlencoding`
  /// crate closely enough that page tokens with `+`/`/`/`=` round-trip.
  String _enc(String s) => Uri.encodeComponent(s);
}
