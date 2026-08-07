// The auth seam [HttpTasksApi] layers its 401-refresh-once behavior on top of —
// the Dart analog of the reference's `auth::AuthedClient` as consumed by
// `api/http.rs`.
//
// http.rs owns the actual 401-replay (refresh once, then retry the call), and
// the auth module only supplies this seam. At T3.1 the concrete, sign-in-backed
// implementation does not exist yet (Step 6, `googleapis_auth`), so this file
// defines the minimal contract http needs and nothing more: send a request with
// the current `Authorization` header applied, and refresh the token once on
// demand. Tests drive it through a fake backed by a scripted `http.Client`.

import 'package:http/http.dart' as http;

/// The outcome of a single token refresh — the Dart port of the reference's
/// `Result<(), RefreshError>`. The classification is load-bearing:
///
///  - [RefreshOk] → retry the original call once with the fresh token.
///  - [RefreshDenied] (`invalid_grant`/`invalid_client`/`unauthorized_client`)
///    → the session is dead; http maps it to `AuthExpired` and the original
///    call is NOT replayed.
///  - [RefreshTransient] (a token-endpoint hiccup) → http maps it to `Network`
///    so the next sync run simply tries again.
sealed class RefreshOutcome {
  const RefreshOutcome();
}

/// Refresh succeeded; the [AuthedClient] now holds a fresh access token.
final class RefreshOk extends RefreshOutcome {
  const RefreshOk();
}

/// Refresh was permanently denied. The caller must NOT replay the request.
final class RefreshDenied extends RefreshOutcome {
  const RefreshDenied(this.message);

  /// The refusal detail (e.g. the `invalid_grant` message).
  final String message;
}

/// Refresh failed transiently (network / 5xx at the token endpoint).
final class RefreshTransient extends RefreshOutcome {
  const RefreshTransient(this.message);

  /// The transient-failure detail.
  final String message;
}

/// Sends HTTP requests with the current access token applied, and refreshes
/// that token on demand. [HttpTasksApi] builds each request without an
/// `Authorization` header and hands it here; the implementation attaches the
/// bearer token and dispatches it through its transport. Rebuilding a fresh
/// request per attempt (http does this) means a post-refresh retry naturally
/// picks up the new token.
abstract interface class AuthedClient {
  /// Attach the current bearer token to [request] and send it.
  Future<http.Response> send(http.Request request);

  /// Refresh the access token once. On [RefreshOk] the new token is applied to
  /// subsequent [send] calls.
  Future<RefreshOutcome> refreshNow();
}
