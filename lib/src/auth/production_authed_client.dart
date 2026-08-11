// The production [AuthedClient] — the 401→refresh-once→retry seam backed for
// real on both platforms. The Dart port of `auth/client.rs`'s `AuthedClient`
// (in-memory access token + write-back to the [TokenStore], refresh once on
// 401) plus its `parse_refresh_response` classification and state.rs's two
// refresh functions (desktop token-endpoint / Android provider).
//
// One class, two [RefreshFn]s — exactly the reference shape:
//  - [desktopRefreshFn] exchanges the stored refresh token for a fresh access
//    token at Google's token endpoint (through googleapis_auth), classifying
//    invalid_grant/invalid_client/unauthorized_client as a permanent denial and
//    everything else as transient, and persisting the refreshed bundle.
//  - [providerRefreshFn] re-runs a SILENT Play Services authorize on 401
//    ([TokenProvider.authorize] with `interactive: false`); a silent
//    interaction-required is the Android shape of a dead session (→ denial).
//
// [HttpTasksApi] owns the actual replay: it calls [send], and on a 401 calls
// [refreshNow] once and retries. This client owns token freshness: it applies
// the current bearer, refreshes reactively when [refreshNow] is invoked, and
// refreshes proactively inside [send] when the access token's expiry has
// already passed (skipping a guaranteed-401 round trip). A denial classified
// here becomes `RefreshDenied` → `AuthExpired` → the sticky `needsReauth`
// state; that mapping is the ONLY origin of re-auth, so its correctness is
// pinned by tests, never trusted to a library.

import 'package:clock/clock.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

import '../api/authed_client.dart';
import 'desktop_auth.dart';
import 'token_provider.dart';
import 'token_store.dart';

/// Acquire a fresh token bundle given the current refresh token. Returns the
/// new [StoredTokens] (access token, expiry, and the — possibly rotated —
/// refresh token) on success, or throws a [RefreshException] carrying the
/// permanent/transient split. Mirrors the reference's
/// `Fn(String) -> Result<StoredTokens, RefreshError>`.
typedef RefreshFn = Future<StoredTokens> Function(String refreshToken);

/// A refresh that did not yield a fresh token. [denied] is the load-bearing
/// split: `true` is a dead grant (the user must sign in again — becomes
/// `AuthExpired`), `false` is a transient outage worth a later retry.
///
/// The [message] is a sanitized detail built from the OAuth error code /
/// provider reason ONLY — it never carries token material.
class RefreshException implements Exception {
  const RefreshException.denied(this.message) : denied = true;
  const RefreshException.transient(this.message) : denied = false;

  final bool denied;
  final String message;

  @override
  String toString() =>
      'RefreshException(${denied ? 'denied' : 'transient'}): '
      '$message';
}

/// Grant-level OAuth error codes: a refresh that returns one of these can never
/// succeed again, so the session is dead. (RFC 6749 §5.2; verified live for
/// Google's `invalid_grant` on an expired/revoked refresh token.)
const _deniedOauthErrors = {
  'invalid_grant',
  'invalid_client',
  'unauthorized_client',
};

/// The single scope the app ever asks for — the token bundles the Android
/// refresh path stamps (Play Services holds no persisted scope string).
const _tasksScope = 'https://www.googleapis.com/auth/tasks';

/// Desktop [RefreshFn]: exchange the stored refresh token for a fresh access
/// token at the token endpoint through googleapis_auth's [refreshCredentials],
/// using [refreshClient] as the transport (a scripted client in tests). The
/// desktop-app `client_secret` rides along via the confidential [ClientId].
RefreshFn desktopRefreshFn({
  required OAuthConfig config,
  required http.Client refreshClient,
}) {
  return (String refreshToken) async {
    final clientId = ClientId(config.clientId, config.clientSecret);
    // A deliberately-expired bundle forces googleapis_auth to exchange the
    // refresh token immediately (the same trick clientViaRefreshToken uses).
    final stale = AccessCredentials(
      AccessToken(
        'Bearer',
        '',
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
      refreshToken,
      config.scopes,
    );
    final AccessCredentials fresh;
    try {
      fresh = await refreshCredentials(clientId, stale, refreshClient);
    } on ServerRequestFailedException catch (e) {
      // The token endpoint answered with an error. Classify from the OAuth
      // `error` code in the parsed response body — NOT the HTTP status — so a
      // grant-level denial is permanent and everything else stays retryable.
      throw _classifyTokenEndpointError(e);
    } on Object {
      // Network down, timeout, non-JSON, socket reset — retry later with the
      // same refresh token. Deliberately no detail interpolated: the underlying
      // error object could, in principle, echo request material.
      throw const RefreshException.transient('token endpoint unreachable');
    }
    return StoredTokens(
      accessToken: fresh.accessToken.data,
      // googleapis_auth preserves the existing refresh token (Google omits a
      // rotated one for the tasks scope); adopt whatever it returns.
      refreshToken: fresh.refreshToken ?? refreshToken,
      accessExpiresAt:
          fresh.accessToken.expiry.millisecondsSinceEpoch ~/
          Duration.millisecondsPerSecond,
      scope: fresh.scopes.isEmpty
          ? config.scopes.join(' ')
          : fresh.scopes.join(' '),
    );
  };
}

RefreshException _classifyTokenEndpointError(ServerRequestFailedException e) {
  final content = e.responseContent;
  if (content is Map) {
    final error = content['error'];
    final desc = content['error_description'];
    final detail = (desc is String && desc.isNotEmpty)
        ? '$error: $desc'
        : '$error';
    if (error is String && _deniedOauthErrors.contains(error)) {
      return RefreshException.denied(detail);
    }
    return RefreshException.transient(detail);
  }
  // No machine-readable OAuth error (5xx HTML, mangled proxy body): transient.
  final status = e.statusCode;
  return RefreshException.transient(
    status == null ? 'token endpoint error' : 'token endpoint returned $status',
  );
}

/// Android [RefreshFn]: Play Services owns the grant, so a "refresh" is a
/// SILENT (never-interactive) re-authorize — a fresh access token is always one
/// quiet call away. The incoming refresh token is ignored (Android holds none).
/// A silent interaction-required is the Android shape of a dead session and
/// maps to a denial; a transient GMS outage stays retryable.
RefreshFn providerRefreshFn(TokenProvider provider) {
  return (String _) async {
    final String token;
    try {
      token = await provider.authorize(interactive: false);
    } on TokenProviderInteractionRequired {
      throw const RefreshException.denied('Google sign-in needs to be renewed');
    } on TokenProviderUnavailable catch (e) {
      throw RefreshException.transient(e.message);
    }
    return StoredTokens(
      accessToken: token,
      // No refresh token exists on Android; nothing is ever persisted from
      // this bundle. Unknown expiry → never a proactive refresh, only on 401.
      refreshToken: '',
      accessExpiresAt: null,
      scope: _tasksScope,
    );
  };
}

/// Authenticated HTTP client. Holds the most recent access token in memory,
/// writes any refresh back to the [TokenStore], and refreshes once on demand.
class ProductionAuthedClient implements AuthedClient {
  // The `this._x` formals keep the fields private while callers still pass the
  // public names (`transport:`/`store:`/`refresh:`) — the analyzer maps them.
  ProductionAuthedClient({
    required this._transport,
    required StoredTokens initialTokens,
    required this._store,
    required this._refresh,
    int Function()? nowEpoch,
  }) : _tokens = initialTokens,
       _nowEpoch = nowEpoch ?? _wallClockEpoch;

  /// Android composition: Play Services owns the grant, so there is no refresh
  /// token and nothing is persisted (the store is a throwaway in-memory one).
  /// The provider supplies the initial [accessToken] and every fresh one.
  factory ProductionAuthedClient.android({
    required http.Client transport,
    required String accessToken,
    required TokenProvider provider,
  }) {
    return ProductionAuthedClient(
      transport: transport,
      initialTokens: StoredTokens(
        accessToken: accessToken,
        refreshToken: '',
        accessExpiresAt: null,
        scope: _tasksScope,
      ),
      store: InMemoryTokenStore(),
      refresh: providerRefreshFn(provider),
    );
  }

  final http.Client _transport;
  final TokenStore _store;
  final RefreshFn _refresh;
  final int Function() _nowEpoch;

  StoredTokens _tokens;

  // Ambient `package:clock` time (never the wall clock) so a test can pin
  // "now" with withClock; the [nowEpoch] seam overrides it directly.
  static int _wallClockEpoch() =>
      clock.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

  /// Whether the in-memory access token is known to be past its expiry.
  /// Conservative: an unknown expiry (Android) is treated as not-expired, so
  /// refresh stays reactive-on-401.
  bool _isAccessExpired() {
    final exp = _tokens.accessExpiresAt;
    return exp != null && _nowEpoch() >= exp;
  }

  @override
  Future<http.Response> send(http.Request request) async {
    // Proactive refresh: when the token is already known-expired, refresh
    // before sending so we skip a guaranteed 401. Best effort — a refresh
    // failure here just falls through to the send, whose 401 the reactive
    // [refreshNow] path (in HttpTasksApi) then classifies. Never loops: a
    // successful refresh moves the expiry into the future.
    if (_isAccessExpired()) {
      await _doRefresh();
    }
    request.headers['authorization'] = 'Bearer ${_tokens.accessToken}';
    final streamed = await _transport.send(request);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<RefreshOutcome> refreshNow() => _doRefresh();

  /// Refresh once, adopting and persisting the fresh bundle on success. A
  /// persist failure is reported transient — the refresh itself succeeded and
  /// the new token is live in memory, so the caller may proceed.
  Future<RefreshOutcome> _doRefresh() async {
    final StoredTokens fresh;
    try {
      fresh = await _refresh(_tokens.refreshToken);
    } on RefreshException catch (e) {
      return e.denied ? RefreshDenied(e.message) : RefreshTransient(e.message);
    }
    _tokens = fresh;
    try {
      _store.save(fresh);
    } on Object {
      return const RefreshTransient('failed to persist refreshed tokens');
    }
    return const RefreshOk();
  }
}
