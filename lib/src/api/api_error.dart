// Typed errors surfaced by [TasksApi] — the Dart port of `api/error.rs`.
//
// The sync engine and scheduler match on these variants to decide whether to
// retry, refresh tokens, or give up. Two distinctions are load-bearing:
//
//  - [Unauthorized] vs [AuthExpired]: `Unauthorized` is the recoverable
//    "refresh and retry once" signal; `AuthExpired` (an `invalid_grant`
//    refresh denial) is a dead session that only a fresh sign-in can fix —
//    it drives the needs-reauth UI state and aborts the whole sync run.
//  - [isTransient]: exactly [RateLimited], [ServerError] and [Network] are
//    worth retrying after a short delay; everything else is terminal.
//
// Pure Dart: no Flutter/HTTP dependency (the status→error mapping lives in
// `http_tasks_api.dart`). Each variant is a value type (`==`/`hashCode`) so
// tests and the sync layer can compare errors directly.

/// API-level errors the sync engine matches on to decide retry/refresh/give-up.
sealed class ApiError implements Exception {
  const ApiError();

  /// Whether the caller should retry after a short delay. True for exactly
  /// [RateLimited], [ServerError] and [Network]; every other variant is
  /// terminal (mirrors `ApiError::is_transient`).
  bool get isTransient =>
      this is RateLimited || this is ServerError || this is Network;
}

/// The request was rejected because the access token was missing, expired, or
/// revoked. The caller should refresh and retry once.
final class Unauthorized extends ApiError {
  const Unauthorized();

  @override
  bool operator ==(Object other) => other is Unauthorized;

  @override
  int get hashCode => (Unauthorized).hashCode;

  @override
  String toString() => 'ApiError.unauthorized';
}

/// Token refresh was permanently denied (`invalid_grant`: the refresh token
/// expired or was revoked). No retry can succeed — the user must sign in
/// again. Distinct from [Unauthorized], the recoverable refresh signal.
final class AuthExpired extends ApiError {
  const AuthExpired(this.message);

  /// The underlying refresh-denial detail (e.g. the `invalid_grant` text).
  final String message;

  @override
  bool operator ==(Object other) =>
      other is AuthExpired && other.message == message;

  @override
  int get hashCode => Object.hash(AuthExpired, message);

  @override
  String toString() => 'ApiError.authExpired($message)';
}

/// The target row no longer exists on the server.
final class NotFound extends ApiError {
  const NotFound();

  @override
  bool operator ==(Object other) => other is NotFound;

  @override
  int get hashCode => (NotFound).hashCode;

  @override
  String toString() => 'ApiError.notFound';
}

/// Optimistic-concurrency failure (`If-Match` etag mismatch, HTTP 409/412).
/// The caller should pull, merge, and retry.
final class PreconditionFailed extends ApiError {
  const PreconditionFailed();

  @override
  bool operator ==(Object other) => other is PreconditionFailed;

  @override
  int get hashCode => (PreconditionFailed).hashCode;

  @override
  String toString() => 'ApiError.preconditionFailed';
}

/// Server is rate-limiting; transient. A `Retry-After` header, when present,
/// is honored directly by the retry loop (see `http_tasks_api.dart`).
final class RateLimited extends ApiError {
  const RateLimited();

  @override
  bool operator ==(Object other) => other is RateLimited;

  @override
  int get hashCode => (RateLimited).hashCode;

  @override
  String toString() => 'ApiError.rateLimited';
}

/// Server returned a 5xx; transient.
final class ServerError extends ApiError {
  const ServerError(this.status);

  /// HTTP status code (500–599).
  final int status;

  @override
  bool operator ==(Object other) =>
      other is ServerError && other.status == status;

  @override
  int get hashCode => Object.hash(ServerError, status);

  @override
  String toString() => 'ApiError.server($status)';
}

/// Network / transport failure; transient.
final class Network extends ApiError {
  const Network(this.message);

  /// Transport-level detail.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is Network && other.message == message;

  @override
  int get hashCode => Object.hash(Network, message);

  @override
  String toString() => 'ApiError.network($message)';
}

/// Anything else — non-retryable by default (the Rust `Other`).
final class OtherApiError extends ApiError {
  const OtherApiError(this.message);

  /// Human-readable detail.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is OtherApiError && other.message == message;

  @override
  int get hashCode => Object.hash(OtherApiError, message);

  @override
  String toString() => 'ApiError.other($message)';
}
