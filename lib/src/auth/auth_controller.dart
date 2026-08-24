// The auth controller — the port of `state.rs`'s auth half: the three-state
// machine (signed out / signed in / needs-reauth), silent startup restore,
// the interactive sign-in gesture, and logout. It implements the [AuthState]
// seam the [SyncScheduler] already gates on (T5.9), so wiring the real
// controller under the scheduler is a drop-in.
//
// Design notes carried from the reference and the migration plan:
//  - needs-reauth is a DEAD SESSION, not signed-out: the tokens/grant existed
//    but refresh is permanently denied. The scheduler raises it after an
//    auth-expired sync; a fresh sign-in or a successful sync clears it.
//  - Silent restore must be QUIET on failure: a fresh install (no grant) or a
//    transient outage (no network) start signed out with NO banner — raising
//    "session expired" for someone who never had a session is a UX bug (#175
//    ancestry in RFC-010).
//  - Every transition emits on [changes] so the UI affordance follows the state
//    without polling (#174).
//  - Startup restore + auto-sync run DETACHED after the first frame; a hung
//    restore must never delay first paint (#175 + the geometry-freeze lesson).

import 'dart:async';

import '../app/auth_state.dart';
import '../app/logging.dart';
import 'auth_error.dart';
import 'token_provider.dart';

/// The three auth states (invariant #6).
enum AuthPhase {
  /// No session — the sign-in affordance is primary.
  signedOut,

  /// A live session — background sync may run.
  signedIn,

  /// A dead session (tokens/grant present but refresh permanently denied) — the
  /// "sign in again" affordance is primary. Distinct from [signedOut].
  needsReauth,
}

/// An immutable snapshot of the auth state, emitted on every transition. This
/// is what the UI renders from — the affordance follows [phase] (#174).
class AuthSnapshot {
  const AuthSnapshot({
    required this.isAuthenticated,
    required this.needsReauth,
    this.missingConfigPath,
  });

  /// Whether a session exists (tokens/grant present). Stays true across a
  /// [needsReauth] transition — a dead session keeps its tokens.
  final bool isAuthenticated;

  /// Whether the stored session is dead and only a fresh sign-in recovers it.
  final bool needsReauth;

  /// The config file whose Google credentials are missing, or null when the
  /// platform CAN authenticate (#228). Set the moment the token provider
  /// reports [TokenProviderNotConfigured] — on desktop, an empty `google`
  /// section in `config.json`; never set on Android, where Play Services
  /// identifies the app.
  ///
  /// Orthogonal to [phase]: an install with no credentials is signed OUT, but
  /// its signed-out-ness is a configuration fault the UI must say out loud, not
  /// the quiet idle of someone who simply has not signed in yet.
  final String? missingConfigPath;

  /// Whether the app has no credentials to authenticate with at all.
  bool get notConfigured => missingConfigPath != null;

  /// The single derived state the UI switches on.
  AuthPhase get phase => needsReauth
      ? AuthPhase.needsReauth
      : (isAuthenticated ? AuthPhase.signedIn : AuthPhase.signedOut);

  @override
  bool operator ==(Object other) =>
      other is AuthSnapshot &&
      other.isAuthenticated == isAuthenticated &&
      other.needsReauth == needsReauth &&
      other.missingConfigPath == missingConfigPath;

  @override
  int get hashCode =>
      Object.hash(isAuthenticated, needsReauth, missingConfigPath);

  @override
  String toString() => notConfigured
      ? 'AuthSnapshot(${phase.name}, not configured)'
      : 'AuthSnapshot(${phase.name})';
}

/// Owns the auth state machine over a [TokenProvider].
class AuthController implements AuthState {
  AuthController(this._provider);

  final TokenProvider _provider;
  final StreamController<AuthSnapshot> _changes =
      StreamController<AuthSnapshot>.broadcast();

  bool _isAuthenticated = false;
  bool _needsReauth = false;
  String? _accessToken;
  String? _missingConfigPath;

  @override
  bool get isAuthenticated => _isAuthenticated;

  @override
  bool get needsReauth => _needsReauth;

  /// The most recently acquired access token (for wiring the authed API client
  /// after sign-in/restore), or null when signed out.
  String? get accessToken => _accessToken;

  /// The config file whose Google credentials are missing, or null when the
  /// platform can authenticate (#228).
  String? get missingConfigPath => _missingConfigPath;

  /// The current state as a snapshot.
  AuthSnapshot get snapshot => AuthSnapshot(
    isAuthenticated: _isAuthenticated,
    needsReauth: _needsReauth,
    missingConfigPath: _missingConfigPath,
  );

  /// The derived state the UI switches on.
  AuthPhase get phase => snapshot.phase;

  /// Emitted on every transition so the UI affordance follows without polling.
  Stream<AuthSnapshot> get changes => _changes.stream;

  /// Flag or clear the dead-session state (the [AuthState] seam the scheduler
  /// drives). Emits only on an actual change so an unchanged run is silent.
  @override
  void setNeedsReauth(bool value) {
    if (_needsReauth == value) return;
    _needsReauth = value;
    _emit();
  }

  /// The interactive sign-in gesture. On success the session goes live and any
  /// re-auth banner clears. An EXPECTED auth-flow failure (cancelled/denied,
  /// interaction-required, transient outage) propagates to the caller with the
  /// state left EXACTLY as it was — a cancelled gesture must never flip the app
  /// to a false signed-in state (invariant #6). An UNEXPECTED failure — the
  /// session could not be persisted ([TokenStoreException] from a tokens.json
  /// write/chmod IO error), or any other stray error — never escapes raw: it is
  /// logged and mapped to a clean signed-out state WITH an emission, so the
  /// gesture can never crash the app with an unhandled async error (F9 / #189).
  Future<void> signIn() async {
    try {
      final token = await _provider.authorize(interactive: true);
      _accessToken = token;
      _isAuthenticated = true;
      _needsReauth = false;
      _missingConfigPath = null;
      _emit();
    } on TokenProviderNotConfigured catch (e) {
      // There are no credentials to sign in WITH, so the flow never started —
      // no browser was opened and nothing dead-ended in Google's 400 (#228).
      // Record the fault and EMIT it so the persistent attention state appears
      // even if the caller only shows a transient toast, then rethrow so the
      // gesture reports it. Must precede the TokenProviderException clause
      // below, which would otherwise swallow this subtype into a bare rethrow.
      Log.warn(
        'sign-in: Google credentials are not configured (${e.configPath})',
      );
      _missingConfigPath = e.configPath;
      _emit();
      rethrow;
    } on TokenStoreException catch (e) {
      // The gesture reached the endpoint but the session could not be PERSISTED
      // (a tokens.json write / chmod IO failure). We cannot claim a live
      // session that won't survive a restart, so degrade to a clean signed-out
      // state WITH an emission rather than letting a raw store error escape the
      // gesture unobserved (F9 / #189).
      Log.warn('sign-in could not persist the session ($e); signed out');
      _resetToSignedOut();
    } on AuthException {
      // A genuine auth-flow failure (denied consent, state mismatch, no refresh
      // token): surface to the caller with state untouched — a cancelled
      // gesture must never flip the app to a false signed-in state (#6).
      rethrow;
    } on TokenProviderException {
      // Interaction-required / a transient outage: surface to the caller with
      // state untouched; the UI's guarded action logs it.
      rethrow;
    } catch (e) {
      // Truly unexpected — never let the gesture crash with an unhandled async
      // error; degrade to signed-out WITH an emission.
      Log.warn('sign-in failed unexpectedly ($e); signed out');
      _resetToSignedOut();
    }
  }

  /// Silent startup restore. Returns true iff a live session was recovered
  /// with NO user gesture. Every failure shape returns false and stays quietly
  /// signed out with no banner: [TokenProviderInteractionRequired] usually
  /// means the user simply never signed in, [TokenProviderUnavailable]
  /// (no network / GMS updating) is transient — the user can still sign in
  /// manually, and nothing loops at startup — and any UNEXPECTED error (a
  /// malformed tokens.json raising [TokenStoreException], or a stray store IO
  /// error) is caught, logged, and mapped to a signed-out emission. This runs
  /// DETACHED after the first frame, so it must NEVER reject: an unobserved
  /// throw would kill the startup task silently (F9 / #189).
  Future<bool> restore() async {
    try {
      final token = await _provider.authorize(interactive: false);
      _accessToken = token;
      _isAuthenticated = true;
      _needsReauth = false;
      _missingConfigPath = null;
      _emit();
      return true;
    } on TokenProviderNotConfigured catch (e) {
      // A startup with no credentials is NOT the quiet "never signed in" idle:
      // the install cannot sync at all and the user has to edit a file to fix
      // it. Stay signed out, but record the fault and emit it so the UI can
      // raise a persistent attention state naming the config (#228).
      Log.warn(
        'startup: Google credentials are not configured (${e.configPath}); '
        'starting signed out',
      );
      _missingConfigPath = e.configPath;
      _resetToSignedOut();
      return false;
    } on TokenProviderInteractionRequired {
      Log.info('no live session to restore; starting signed out');
      return false;
    } on TokenProviderUnavailable catch (e) {
      Log.warn(
        'auth unavailable at startup (${e.message}); starting signed out',
      );
      return false;
    } catch (e) {
      // Unexpected — a malformed tokens.json (TokenStoreException) or any other
      // error reading the store. This runs DETACHED after the first frame, so
      // it must never die unobserved: log, fall to a clean signed-out state
      // WITH an emission, and report "not restored" so auto-sync is skipped
      // (F9 / #189).
      Log.warn('startup restore failed unexpectedly ($e); starting signed out');
      _resetToSignedOut();
      return false;
    }
  }

  /// Sign out: drop the session and return to the offline signed-out state. The
  /// dead-session banner no longer applies.
  ///
  /// The local session is cleared FIRST and unconditionally, THEN the provider's
  /// remote sign-out is attempted. Clearing after the provider call (as it once
  /// was) meant a raw provider failure — a GMS crash on Android, an IO error on
  /// desktop — threw before the local state changed, leaving the app wedged
  /// "signed in": Sign out a silent no-op (G6 / #204). The local state is what
  /// every affordance reads, so once it is cleared and emitted the user IS
  /// signed out; a failed remote drop only leaves the grant lingering
  /// server-side (the next sign-in refreshes it), and is logged, never rethrown
  /// — a thrown gesture would skip the caller's own post-logout cleanup.
  Future<void> logout() async {
    _resetToSignedOut();
    try {
      await _provider.signOut();
    } catch (e) {
      Log.warn('sign-out: provider signOut failed ($e); local session cleared');
    }
  }

  /// Silently restore, then — only if a session came back AND auto-sync on
  /// start is enabled — trigger the startup sync via [onAutoSync], with NO user
  /// gesture (#175). Meant to run DETACHED after the first frame: the caller
  /// (bootstrap's post-first-frame hook) must not await this on the render
  /// path, so a hung [TokenProvider.authorize] can never delay first paint.
  Future<void> restoreThenAutoSync({
    required bool autoSyncOnStart,
    required Future<void> Function() onAutoSync,
  }) async {
    final restored = await restore();
    if (restored && autoSyncOnStart) {
      await onAutoSync();
    }
  }

  /// Fall to a clean signed-out state (no session, no banner) and EMIT it, so a
  /// failure on the detached startup / sign-in path is observable to the UI
  /// stream instead of dying unobserved (F9 / #189).
  ///
  /// [_missingConfigPath] is NOT cleared here: missing credentials are a
  /// property of the config file, not of the session, so they survive every
  /// sign-out and failure (#228). Only a successful authorize clears it.
  void _resetToSignedOut() {
    _accessToken = null;
    _isAuthenticated = false;
    _needsReauth = false;
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  /// Release the change stream. Call at shutdown.
  Future<void> dispose() => _changes.close();
}
