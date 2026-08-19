// Android token provider — the port of `play_services_auth.rs`, bridging Play
// Services (through google_sign_in v7) to the platform-agnostic [TokenProvider]
// seam the [AuthController] drives (MIGRATION-PLAN §5 T9.1).
//
// Two layers, mirroring how desktop_auth.dart splits pure logic from runtime
// plumbing:
//
//  - [GoogleSignInTokenProvider] is the pure contract mapper. It turns a
//    [GoogleAuthorization] round-trip into the three-outcome [TokenProvider]
//    contract (token / interaction-required / unavailable) — the exact match
//    arms of the reference's PlayServicesTokenProvider. It is unit-tested with a
//    fake [GoogleAuthGateway]; no Play Services, no device.
//
//  - [GoogleSignInAuthGateway] is the live seam over `GoogleSignIn.instance`. It
//    runs only on Android (Play Services exists nowhere else). It is exercised
//    by injecting a mock `GoogleSignInPlatform`, which pins the two behaviours
//    T9.1 is really about: the SILENT restore path only ever asks for tokens
//    that come back without UI, and the interactive path is the ONLY one that
//    prompts. On-device proof against the real endpoint is the operator's gate
//    (T9.2), not this suite.
//
// Auth-model note (ratified): on Android the app is identified by its package
// name + registered SHA-1, so NO clientId / serverClientId is passed to
// `initialize()` and NO tokens are persisted locally. serverClientId is added
// ONLY if Google refuses an access-token authorization without it — which it
// does not for the `tasks` scope.

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:google_sign_in/google_sign_in.dart';

import 'token_provider.dart';

/// The `tasks` scope — the only authorization this app needs.
const List<String> googleTasksScopes = <String>[
  'https://www.googleapis.com/auth/tasks',
];

/// The outcome of one Play Services authorize round-trip — the seam value
/// between the google_sign_in plugin and the [TokenProvider] contract, mirroring
/// the reference plugin's `AuthorizeResponse`. Either the grant is live and
/// [accessToken] carries the token, or [needsInteraction] is true and the
/// interactive gesture is required.
class GoogleAuthorization {
  const GoogleAuthorization.token(String this.accessToken)
    : needsInteraction = false;

  const GoogleAuthorization.needsInteraction()
    : accessToken = null,
      needsInteraction = true;

  /// The access token, when the grant was serviceable; null when interaction is
  /// required.
  final String? accessToken;

  /// Whether the grant needs the interactive sign-in gesture.
  final bool needsInteraction;
}

/// A transient Play Services failure surfaced by a [GoogleAuthGateway]: GMS
/// absent/outdated, no network, or a misconfiguration. The provider maps it to
/// [TokenProviderUnavailable] so the app degrades to local-only with NO crash
/// and NO retry loop — the same "start quietly signed out" path desktop takes
/// on an outage.
class GoogleAuthUnavailable implements Exception {
  const GoogleAuthUnavailable(this.message);

  final String message;

  @override
  String toString() => 'GoogleAuthUnavailable: $message';
}

/// The platform seam over google_sign_in v7. The real implementation
/// ([GoogleSignInAuthGateway]) runs only on Android; tests inject a fake so the
/// provider's contract mapping is exercised with no Play Services.
abstract interface class GoogleAuthGateway {
  /// Acquire a Play Services access token. `interactive == false` MUST NOT show
  /// UI (startup restore / background); `interactive == true` is the sign-in
  /// gesture and may show the account picker + consent. Throws
  /// [GoogleAuthUnavailable] on a transient GMS failure.
  Future<GoogleAuthorization> authorize({required bool interactive});

  /// Drop the Play Services session.
  Future<void> signOut();
}

/// A [TokenProvider] over Play Services (through a [GoogleAuthGateway]). The
/// port of `PlayServicesTokenProvider`: it maps the gateway's three outcomes
/// onto the same three-state contract the desktop provider satisfies, so the
/// [AuthController] drives Android exactly as it drives desktop.
class GoogleSignInTokenProvider implements TokenProvider {
  GoogleSignInTokenProvider(this._gateway);

  final GoogleAuthGateway _gateway;

  @override
  Future<String> authorize({required bool interactive}) async {
    final GoogleAuthorization result;
    try {
      result = await _gateway.authorize(interactive: interactive);
    } on GoogleAuthUnavailable catch (e) {
      // Transient — a later retry may succeed; the app stays usable offline.
      throw TokenProviderUnavailable(e.message);
    }
    if (result.needsInteraction) {
      throw const TokenProviderInteractionRequired();
    }
    final token = result.accessToken;
    if (token == null || token.isEmpty) {
      // A "success" with no token is a broken response, not a live session.
      throw const TokenProviderUnavailable('empty authorize response');
    }
    return token;
  }

  @override
  Future<void> signOut() => _gateway.signOut();
}

/// The live [GoogleAuthGateway] over `GoogleSignIn.instance`. Android-only
/// runtime plumbing: it lazily initializes the plugin, then services a silent
/// or interactive authorize. Not run on the desktop host at product runtime;
/// its branching is covered by tests through a mock `GoogleSignInPlatform`.
class GoogleSignInAuthGateway implements GoogleAuthGateway {
  GoogleSignInAuthGateway({this.scopes = googleTasksScopes});

  final List<String> scopes;
  bool _initialized = false;

  GoogleSignIn get _signIn => GoogleSignIn.instance;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // No clientId / serverClientId — the package name + registered SHA-1
    // identify the app on Android (ratified auth decision).
    await _signIn.initialize();
    _initialized = true;
  }

  @override
  Future<GoogleAuthorization> authorize({required bool interactive}) async {
    try {
      await _ensureInitialized();

      // AUTHORIZATION-ONLY, deliberately skipping `authenticate()`: the v7
      // authentication step is Credential Manager, which hard-requires a
      // serverClientId on Android ("serverClientId must be provided on
      // Android") — but this app never needs identity tokens, only a `tasks`
      // access token. The instance-level authorization client is the Play
      // Services Authorization API — the exact surface the reference's
      // play_services_auth.rs used — and is serviced by package + registered
      // SHA-1 alone, so the ratified no-client-id model holds.
      if (interactive) {
        // The sign-in gesture: an interactive authorization — Play Services
        // runs the combined account-picker + consent flow as needed. The ONLY
        // path allowed to prompt.
        final authz = await _signIn.authorizationClient.authorizeScopes(scopes);
        return GoogleAuthorization.token(authz.accessToken);
      }

      // Silent restore: never prompt. A null means the grant needs the
      // interactive gesture.
      final authz = await _signIn.authorizationClient.authorizationForScopes(
        scopes,
      );
      if (authz == null) return const GoogleAuthorization.needsInteraction();
      return GoogleAuthorization.token(authz.accessToken);
    } on GoogleSignInException catch (e) {
      // A user cancel / interruption / no-UI-available is not a hard failure:
      // the grant still just needs interaction, so the caller stays put
      // (sign-in) or quietly signed out (restore) — never crashing or looping.
      // Everything else (GMS absent/outdated, misconfig) is a transient outage.
      return switch (e.code) {
        GoogleSignInExceptionCode.canceled ||
        GoogleSignInExceptionCode.interrupted ||
        GoogleSignInExceptionCode.uiUnavailable =>
          const GoogleAuthorization.needsInteraction(),
        // The plugin's `description` is raw Play-Services text that can carry
        // account/config specifics, and this message is logged verbatim
        // upstream (auth_controller.restore) — so classify by the STABLE error
        // code only and never let the raw description ride into the log (#187).
        _ => throw GoogleAuthUnavailable(e.code.name),
      };
    } on MissingPluginException {
      // The google_sign_in plugin is not registered on this host (a non-Android
      // target, or a build that stripped it): an environmental unavailability,
      // not a dead grant. Degrade to the transient-outage path instead of
      // letting the raw error escape into the app (#189).
      throw const GoogleAuthUnavailable('google_sign_in plugin unavailable');
    } on PlatformException catch (e) {
      // A raw method-channel failure from Play Services (a GMS crash, transport
      // error, or misconfiguration): NOT a GoogleSignInException, so it would
      // otherwise escape raw. Classify by the STABLE `code` only — the raw
      // `message` can carry account/config specifics and is logged verbatim
      // upstream (auth_controller.restore), so it must never ride out (#187).
      throw GoogleAuthUnavailable('platform error: ${e.code}');
    }
  }

  @override
  Future<void> signOut() async {
    if (!_initialized) return;
    // Wrap the raw drop in the SAME platform-exception translation authorize
    // uses (G6 / #204): a GMS crash, a method-channel PlatformException, or a
    // missing plugin must surface as a typed [GoogleAuthUnavailable] classified
    // by the STABLE code only — never a raw error escaping (whose message can
    // carry account specifics that are logged verbatim upstream, #187) and
    // never a swallowed throw that makes Sign out a silent no-op.
    try {
      await _signIn.signOut();
    } on GoogleSignInException catch (e) {
      throw GoogleAuthUnavailable(e.code.name);
    } on MissingPluginException {
      throw const GoogleAuthUnavailable('google_sign_in plugin unavailable');
    } on PlatformException catch (e) {
      throw GoogleAuthUnavailable('platform error: ${e.code}');
    }
  }
}
