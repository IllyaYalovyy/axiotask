// The composition root for auth + sync (F5, #176) — the Dart analog of the
// reference's `AppState::new` auth/sync half plus `lib.rs::run`'s startup task.
//
// This is the ONE place the three long-lived actors are assembled and handed
// the seams the widget tree drives:
//
//  - the [AuthController] over a platform [TokenProvider] (desktop tokens.json /
//    Android Play Services),
//  - the [SyncScheduler] over the store, the current authed [TasksApi], and the
//    auth state,
//  - the [Commands] used for the local half of a fresh-sync.
//
// The ordered STARTUP task ([start]) mirrors the reference and the migration
// plan: silent restore → (if a session came back AND auto-sync-on-start) an
// auto-sync → the background loop. It is DETACHED after the first frame by the
// entry point, so a hung `authorize` or a slow first sync can never delay first
// paint (#175 + the geometry-freeze lesson). [restoreAndAutoSync] is the
// awaitable ordered prefix (restore → auto-sync) so tests exercise the ordering
// without spawning the never-ending loop; [start] runs it then launches the
// loop.
//
// The client is rebuilt on every (re)login/restore and read through the
// scheduler's `TasksApi Function()` getter, so a re-login swaps the client under
// the scheduler with no reconstruction — exactly the seam `authed_api.dart`
// documents. Everything platform- or network-touching is injected
// ([tokenProvider], [buildClient]), so the whole root is exercised in widget
// tests over a fake token provider and the in-memory fake API.

import 'dart:async';

import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:flutter_riverpod/misc.dart' show Override;

import '../api/tasks_api.dart' show TasksApi;
import '../auth/auth_controller.dart';
import '../auth/token_provider.dart';
import '../store/store.dart';
import '../sync/sync_error.dart';
import '../ui/auth/sidebar_auth_sync_footer.dart';
import '../ui/toast.dart';
import '../ui/user_message.dart';
import 'commands.dart';
import 'config_controller.dart';
import 'logging.dart';
import 'providers.dart';
import 'sync_scheduler.dart';
import 'sync_status.dart';

/// Assembles the auth controller, sync scheduler, and production client seam,
/// and exposes the provider [overrides] + lifecycle the entry point mounts.
class AuthSyncRuntime {
  AuthSyncRuntime({
    required Store store,
    required TokenProvider tokenProvider,
    // `this._config` / `this._buildClient` are initializing formals: callers
    // still pass `config:` / `buildClient:` (the underscore is stripped from the
    // external name) while the private fields are seeded directly.
    required this._config,
    required this._buildClient,
    Duration debounce = kSyncDebounce,
    Duration period = kSyncPeriod,
  }) : auth = AuthController(tokenProvider) {
    scheduler = SyncScheduler(
      store: store,
      client: _currentClient,
      auth: auth,
      pushEnabled: () => _config.pushEnabled,
      debounce: debounce,
      period: period,
    );
    // The ONE Commands instance the app drives (mounted via commandsProvider):
    // every local mutation kicks the scheduler's debounced trigger, so a local
    // change syncs within seconds while the periodic cycle exists to pick up
    // REMOTE edits (#209 — the reference fires schedule_sync() after every
    // mutating command; the port had dropped all of those call sites).
    _commands = Commands(store, onMutation: scheduler.scheduleSync);
  }

  final ConfigController _config;
  final TasksApi? Function(String accessToken) _buildClient;
  late final Commands _commands;

  /// The auth state machine (signed out / signed in / needs-reauth). Public so
  /// the entry point and tests can read the live state.
  final AuthController auth;

  /// The background sync scheduler. Public so the entry point and tests can read
  /// its sanitized status and drive a run.
  late final SyncScheduler scheduler;

  /// The Tasks client for the current live session, rebuilt on every
  /// (re)login/restore. Null while signed out — the scheduler only reads it
  /// through [_currentClient] on the authed path.
  TasksApi? _client;

  TasksApi _currentClient() {
    final c = _client;
    if (c == null) {
      throw StateError('no authenticated Tasks client (signed out)');
    }
    return c;
  }

  void _rebuildClient() {
    final token = auth.accessToken;
    if (token == null) return;
    final client = _buildClient(token);
    if (client == null) {
      // The persisted session vanished or corrupted between restore/sign-in and
      // this rebuild (desktop reads the bundle back from tokens.json, which can
      // be deleted or mangled out from under us). We cannot build a client, so
      // flip to the dead-session state WITH an emission instead of leaving a
      // signed-in-without-client hole that fails every later sync — never a
      // throw off the detached startup task or the sign-in gesture (G2 / #203).
      _client = null;
      auth.setNeedsReauth(true);
      return;
    }
    _client = client;
  }

  /// The provider overrides that mount this runtime into the widget tree: the
  /// live auth/status streams (seeded then subscribed), the four action seams,
  /// and the real sidebar footer.
  List<Override> get overrides => [
    authSnapshotProvider.overrideWith((ref) => _authSnapshots()),
    syncStatusStreamProvider.overrideWith((ref) => _syncStatuses()),
    refreshActionProvider.overrideWithValue(refresh),
    freshSyncActionProvider.overrideWithValue(freshSync),
    // Built from the scope's Ref so the gesture can raise a toast on the ONE
    // feedback surface the UI already renders (#212) — a failed sign-in must
    // never be a silent no-op.
    signInActionProvider.overrideWith(
      (ref) => _signInAction(ref.read(toastControllerProvider)),
    ),
    signOutActionProvider.overrideWithValue(_signOutAction),
    sidebarFooterProvider.overrideWithValue(const SidebarAuthSyncFooter()),
    // Mount THE mutation-triggering Commands (#209): without this override the
    // UI would build its own untriggered instance from the default provider and
    // local changes would wait out the periodic cycle.
    commandsProvider.overrideWithValue(_commands),
  ];

  // Seed the CURRENT snapshot first (the `changes` broadcast stream has no
  // initial replay), then follow every transition. Subscription is established
  // at first-frame build, well before the detached restore emits.
  Stream<AuthSnapshot> _authSnapshots() async* {
    yield auth.snapshot;
    yield* auth.changes;
  }

  Stream<SyncStatusView> _syncStatuses() async* {
    yield scheduler.status;
    yield* scheduler.statuses;
  }

  // ── The ordered startup task ────────────────────────────────────────────────

  /// Silent restore, then — only if a session came back AND auto-sync-on-start
  /// is enabled — one auto-sync. The awaitable ordered prefix of [start]; it
  /// never spawns the background loop, so tests can assert the ordering without
  /// a never-ending run.
  Future<void> restoreAndAutoSync() async {
    final restored = await auth.restore();
    if (!restored) return;
    _rebuildClient();
    if (_config.autoSyncOnStart) {
      await _syncNow();
    }
  }

  /// Launch the background sync loop (mutation-debounced + periodic). Runs
  /// forever; the entry point spawns it once, detached.
  void startLoop() => unawaited(scheduler.runLoop());

  /// The ONE detached startup task: restore → (auto-sync) → loop. Spawn after
  /// the first frame; never awaited on the render path.
  Future<void> start() async {
    await restoreAndAutoSync();
    startLoop();
  }

  // ── The UI action seams ─────────────────────────────────────────────────────

  /// Manual refresh (mobile pull-to-refresh, footer/Properties "Sync now"): a
  /// real sync when a live session exists, otherwise a no-op — the reactive
  /// store already keeps every view live, so there is nothing to "reload".
  Future<void> refresh() => _syncNow();

  /// Fresh sync: drop synced local data (local-only lists survive) and re-pull
  /// from Google, the source of truth. The local clear runs regardless; the
  /// re-pull runs only when authed.
  Future<void> freshSync() async {
    await _commands.freshSync();
    await _syncNow();
  }

  /// The interactive sign-in gesture: go live, build the client, and kick off a
  /// first sync so the account's tasks appear without a second gesture.
  Future<void> signIn() async {
    await auth.signIn();
    _rebuildClient();
    await _syncNow();
  }

  /// Drop the session and go offline. The client is discarded so a stale one can
  /// never push after logout.
  Future<void> signOut() async {
    await auth.logout();
    _client = null;
  }

  /// Flush pending local changes to Google before the process exits (desktop
  /// close hook). Delegates to the scheduler, which only acts when it can safely
  /// push (signed in, push enabled, session alive, something pending).
  Future<void> flushOnExit() => scheduler.flushOnExit();

  /// Release the auth + scheduler streams. Call at shutdown.
  Future<void> dispose() async {
    await scheduler.dispose();
    await auth.dispose();
  }

  Future<void> _syncNow() async {
    // Gate on a live client, NOT on needsReauth. A manual "Sync now" is an
    // explicit re-check by the scheduler's documented contract: it stays
    // available in the dead-session state, and a SUCCESS clears needsReauth (the
    // token came alive again, or the flag was a mis-classified transient). The
    // old `|| auth.needsReauth` guard made that success-clears-reauth path
    // unreachable, wedging the banner until a full re-login (G6 / #204). The
    // background loop keeps its own needsReauth skip so it does not churn the
    // token endpoint; this path is only ever reached from an explicit gesture.
    //
    // The client check is what actually protects the signed-out and
    // vanished-session cases: needsReauth flagged by a client-rebuild failure
    // (G2 / #203) leaves `_client == null`, so a manual sync there is still a
    // clean no-op rather than a StateError out of the scheduler.
    if (!auth.isAuthenticated || _client == null) return;
    try {
      await scheduler.runSyncIfAuthed();
    } on SyncError catch (e) {
      // The scheduler already recorded/sanitized the failure into its status
      // (which the UI renders); a rethrow here would only crash the gesture.
      Log.debug('manual sync failed: $e');
    }
  }

  VoidCallback _signInAction(ToastController toasts) =>
      () => unawaited(_guardedSignIn(toasts));
  VoidCallback get _signOutAction =>
      () => unawaited(_guarded(signOut, 'sign-out'));

  // The sign-in gesture is USER-INITIATED, so its failure needs an answer the
  // user can see: `Log.warn` alone is invisible on Android (dart:developer
  // only) and left a config error or a GMS outage looking like an inert button
  // (#212). A failure the user themselves caused — they closed the account
  // picker — stays silent; [signInUserMessage] draws that line and yields a
  // sentence classified from the error TYPE, so raw provider text (which can
  // carry account identifiers or a request URL) reaches the log only, never a
  // toast (#131/#187).
  Future<void> _guardedSignIn(ToastController toasts) async {
    try {
      await signIn();
    } catch (e) {
      Log.warn('sign-in failed: $e');
      final message = signInUserMessage(e);
      if (message != null) toasts.showError(message);
    }
  }

  // The footer/Account buttons are VoidCallbacks; a cancelled/denied gesture or
  // a transient outage must never surface as an unhandled async error — log it
  // and leave the state exactly as the controller left it (invariant #6).
  Future<void> _guarded(Future<void> Function() action, String label) async {
    try {
      await action();
    } catch (e) {
      Log.warn('$label failed: $e');
    }
  }
}
