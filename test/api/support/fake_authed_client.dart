// A scripted fake [AuthedClient] backed by a fake `http.Client`, for the
// `http_tasks_api` wire-contract tests — the Dart analog of the reference's
// wiremock + `build_test_client`/`counting_refresh` helpers.
//
// The fake records every request it is asked to send (after the bearer token is
// applied) so tests can assert on the exact wire shape — method, URL, query
// params, headers (`If-Match`, `Content-Length`), and body — and drives a
// scripted refresh so the 401-refresh-once paths can be exercised without a
// real token endpoint.

import 'dart:convert';

import 'package:axiotask/src/api/authed_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Handler that produces the scripted response for the [callIndex]-th request
/// (0-based). Inspect [request] to route by method / path / query.
typedef ReplyHandler =
    http.Response Function(http.Request request, int callIndex);

/// A JSON response body with the given [status].
http.Response jsonReply(Object json, {int status = 200}) => http.Response(
  jsonEncode(json),
  status,
  headers: const {'content-type': 'application/json'},
);

/// An empty-body response (e.g. a 204 delete, or a bare error status).
http.Response emptyReply(
  int status, {
  Map<String, String> headers = const {},
}) => http.Response('', status, headers: headers);

/// Decode a recorded request body into a JSON map for wire assertions.
Map<String, Object?> jsonDecodeMap(String body) =>
    (jsonDecode(body) as Map).cast<String, Object?>();

/// Scripted [AuthedClient]. Construct with a [ReplyHandler]; the recorded
/// [requests] are the finalized requests (with body + all headers) exactly as
/// they would go on the wire.
class FakeAuthedClient implements AuthedClient {
  FakeAuthedClient(this._handler, {this.token = 'token', this.refresh}) {
    _client = MockClient((request) async {
      requests.add(request);
      return _handler(request, requests.length - 1);
    });
  }

  final ReplyHandler _handler;

  /// Scripted refresh outcome; null means a plain successful refresh.
  final RefreshOutcome Function()? refresh;

  /// Current access token, applied as the bearer header on each [send].
  String token;

  /// Every request that reached the transport, in order.
  final List<http.Request> requests = <http.Request>[];

  /// How many times [refreshNow] was invoked.
  int refreshCount = 0;

  late final http.Client _client;

  @override
  Future<http.Response> send(http.Request request) async {
    request.headers['authorization'] = 'Bearer $token';
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<RefreshOutcome> refreshNow() async {
    refreshCount += 1;
    final outcome = refresh?.call() ?? const RefreshOk();
    if (outcome is RefreshOk) {
      // A successful refresh adopts the new access token (parity with the
      // reference's counting_refresh, which returns a fresh "refreshed-token").
      token = 'refreshed-token';
    }
    return outcome;
  }
}
