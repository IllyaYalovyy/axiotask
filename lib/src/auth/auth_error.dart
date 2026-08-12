// Auth-subsystem exceptions — the Dart analog of `auth::AuthError`, narrowed to
// the variants the Flutter port actually raises. `Result<T, AuthError>` becomes
// a typed exception per MIGRATION-PLAN §1 (Rust `Result` → typed exceptions).
//
// The distinct subclasses are load-bearing: the loopback redirect contract
// needs [AuthUserDenied] and [AuthStateMismatch] to stay separable (a test
// matches on the type), exactly as `parse_redirect` returns distinct
// `AuthError::UserDenied` / `AuthError::StateMismatch` variants in the
// reference.

/// Base for every auth-subsystem failure.
abstract class AuthException implements Exception {
  const AuthException(this.message);

  /// Human-readable detail (never shown raw to the user in product UI).
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The user declined consent on the OAuth screen (an explicit `error=` param on
/// the loopback redirect, or a redirect that carries no authorization code).
class AuthUserDenied extends AuthException {
  const AuthUserDenied([super.message = 'user denied authorization']);
}

/// The `state` returned on the loopback redirect did not match the one we sent
/// — a possible CSRF attempt or a stale redirect. The code is rejected even
/// when one is present.
class AuthStateMismatch extends AuthException {
  const AuthStateMismatch([super.message = 'oauth state mismatch']);
}

/// The token exchange succeeded at the endpoint but returned no refresh token.
/// Without it there is nothing to persist for future sessions, so a sign-in
/// that cannot be resumed is treated as a failure (T6.1 contract).
class RefreshTokenMissing extends AuthException {
  const RefreshTokenMissing([
    super.message = 'sign-in did not return a refresh token',
  ]);
}

/// A token-store read/write failure (malformed JSON on disk, or an IO error).
class TokenStoreException extends AuthException {
  const TokenStoreException(super.message);
}

/// The loopback redirect server received a connection whose (non-empty) HTTP
/// request line could not be parsed — it carried no request-target. Raised
/// instead of a raw `RangeError` so the caller can surface a typed sign-in
/// failure. Neither a dataless connection (a speculative preconnect that sends
/// no request line) nor a well-formed non-redirect request (a favicon probe) is
/// this: the former is dropped as noise and the latter answered `404`, and in
/// both cases the accept-loop keeps waiting.
class AuthMalformedRedirect extends AuthException {
  const AuthMalformedRedirect([
    super.message = 'malformed loopback request line',
  ]);
}

/// The sign-in gesture exceeded its time bound before Google's redirect
/// arrived. The loopback server is cancelled so the ephemeral port is released
/// rather than leaking a listener that waits forever.
class AuthTimeout extends AuthException {
  const AuthTimeout([super.message = 'sign-in timed out']);
}
