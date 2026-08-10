// The token-provider seam — the port of `MobileTokenProvider` generalized to
// both platforms (MIGRATION-PLAN §2 auth). It is the single abstraction the
// [AuthController] drives: acquire an access token silently (startup restore /
// background) or interactively (the sign-in gesture), and drop the session.
//
// Desktop plugs in [DesktopTokenProvider] (loopback PKCE over a token file);
// Android plugs in the Play Services provider in Step 9. Tests use
// [FakeTokenProvider], so the controller's three-state logic is exercised with
// no browser, token file, network, or device.

/// Why an access-token acquisition failed. The split is the one the auth state
/// machine needs: a revoked/absent grant is permanent (sign in again),
/// everything else is a transient outage worth a later retry with no user
/// action. Ported from `TokenProviderError`.
abstract class TokenProviderException implements Exception {
  const TokenProviderException();
}

/// The provider needs interactive sign-in — the grant was never granted, or was
/// revoked. Outside a gesture this is a dead session (→ needs-reauth on desktop
/// where a session existed; a quiet signed-out state on a fresh install).
class TokenProviderInteractionRequired extends TokenProviderException {
  const TokenProviderInteractionRequired();

  @override
  String toString() => 'TokenProviderInteractionRequired';
}

/// A transient failure: no network, a 5xx, Play Services updating. Worth
/// retrying later without bothering the user.
class TokenProviderUnavailable extends TokenProviderException {
  const TokenProviderUnavailable(this.message);

  final String message;

  @override
  String toString() => 'TokenProviderUnavailable: $message';
}

/// A source of Google access tokens for the `tasks` scope.
abstract interface class TokenProvider {
  /// Acquire a fresh access token.
  ///
  /// `interactive == false` MUST NOT show any UI — it is the startup restore
  /// and background-refresh path; it returns a token when the grant is live and
  /// throws [TokenProviderInteractionRequired] when it is not.
  ///
  /// `interactive == true` is the sign-in gesture: it may open the browser /
  /// account picker and await its result.
  Future<String> authorize({required bool interactive});

  /// Drop the session so the next sign-in starts fresh.
  Future<void> signOut();
}

/// A scripted [TokenProvider] for tests — the port of `FakeTokenProvider`.
/// Records every `authorize(interactive)` call so a test can prove the restore
/// path never asked for UI, and whether [signOut] ran.
class FakeTokenProvider implements TokenProvider {
  FakeTokenProvider._(this._outcome);

  /// A live grant: hands out [token] on every authorize (silent or interactive).
  factory FakeTokenProvider.withToken(String token) =>
      FakeTokenProvider._(_Token(token));

  /// A grant that needs interactive sign-in (revoked, or never granted).
  factory FakeTokenProvider.needsInteraction() =>
      FakeTokenProvider._(const _NeedsInteraction());

  /// A transient outage (e.g. no network / Play Services updating).
  factory FakeTokenProvider.unavailable(String message) =>
      FakeTokenProvider._(_Unavailable(message));

  _Outcome _outcome;
  final List<bool> _calls = <bool>[];
  bool _signedOut = false;

  /// The `interactive` flag of every authorize call so far, in order.
  List<bool> get calls => List.unmodifiable(_calls);

  /// Whether [signOut] was invoked.
  bool get wasSignedOut => _signedOut;

  /// Switch the outcome future authorize calls return — e.g. simulate a grant
  /// coming alive after an interactive sign-in.
  void setToken(String token) => _outcome = _Token(token);

  @override
  Future<String> authorize({required bool interactive}) async {
    _calls.add(interactive);
    return switch (_outcome) {
      _Token(:final token) => token,
      _NeedsInteraction() => throw const TokenProviderInteractionRequired(),
      _Unavailable(:final message) => throw TokenProviderUnavailable(message),
    };
  }

  @override
  Future<void> signOut() async => _signedOut = true;
}

sealed class _Outcome {
  const _Outcome();
}

class _Token extends _Outcome {
  const _Token(this.token);
  final String token;
}

class _NeedsInteraction extends _Outcome {
  const _NeedsInteraction();
}

class _Unavailable extends _Outcome {
  const _Unavailable(this.message);
  final String message;
}
