// The UI-facing auth/sync state the footer and Account tab render from — a
// small, standalone value object decoupled from the controllers that produce
// it (T6.2). The footer's priority ladder (needsReauth > needsAttention >
// sync) and the Account tab's three-way state both switch on this one type, so
// the priority rules live in ONE place and are unit-testable without pumping a
// widget.
//
// Standalone by design: the real sidebar/Properties wiring is T7.1. The
// [AuthSyncStatus.from] factory is the seam that bridges the live
// [AuthSnapshot] + [SyncStatusView] (+ the transient "a run is in flight"
// signal) into this view — so T7.1 constructs it from providers, and this
// task's widgets and goldens construct it directly from literal states.

import '../../app/sync_status.dart';
import '../../auth/auth_controller.dart';

/// Whether a sync run is currently in flight — the transient activity the
/// scheduler's status record does NOT carry (it holds outcomes, not "running").
/// Drives the "Syncing…/Signing in…" button label and its disabled state.
enum SyncActivity {
  /// No run in flight — the action buttons are live.
  idle,

  /// A run is in flight — the primary button shows progress and is disabled.
  syncing,
}

/// Which primary action the footer offers, derived by the priority ladder.
enum FooterAction {
  /// No session ever: run the full OAuth sign-in.
  signIn,

  /// A dead session (tokens present, refresh denied): re-run sign-in. Never a
  /// Sync button, which could only fail.
  reauth,

  /// A live session: sync now.
  sync,
}

/// The status-line phrase, in priority order. The footer maps each to its
/// user-visible sentence; the dot color follows too.
enum FooterStatus {
  /// Dead session — `needsReauth`. Highest priority.
  sessionExpired,

  /// A stuck permanent failure — `needsAttention`.
  needsAttention,

  /// A surfaced (non-attention, non-auth) sync error.
  error,

  /// A successful sync happened; show how long ago.
  synced,

  /// Authenticated, no sync yet this session.
  ready,

  /// Signed out.
  offline,
}

/// The standalone auth/sync view the footer and Account tab render from.
class AuthSyncStatus {
  const AuthSyncStatus({
    required this.isAuthenticated,
    required this.needsReauth,
    this.needsAttention = false,
    this.hasError = false,
    this.activity = SyncActivity.idle,
    this.lastSynced,
  });

  /// Bridge the live controller state into the UI view (the T7.1 seam).
  ///
  /// `needsReauth` is OR-ed from both sources: the auth snapshot is the source
  /// of truth, but a fresh scheduler failure lands in the sync status first, so
  /// honoring either keeps the footer correct in the window before they agree.
  factory AuthSyncStatus.from({
    required AuthSnapshot auth,
    required SyncStatusView sync,
    SyncActivity activity = SyncActivity.idle,
  }) => AuthSyncStatus(
    isAuthenticated: auth.isAuthenticated,
    needsReauth: auth.needsReauth || sync.needsReauth,
    needsAttention: sync.needsAttention,
    hasError: sync.lastError != null,
    activity: activity,
    lastSynced: sync.lastSynced,
  );

  /// A live session exists (tokens on desktop / grant on mobile). Stays true
  /// across a [needsReauth] transition — a dead session keeps its tokens.
  final bool isAuthenticated;

  /// The stored session is dead; only a fresh sign-in recovers it.
  final bool needsReauth;

  /// A permanent, backed-off sync failure is stuck until the user acts.
  final bool needsAttention;

  /// The last run surfaced a sanitized error (distinct from the two states
  /// above, which own their own affordances).
  final bool hasError;

  /// Whether a run is in flight right now.
  final SyncActivity activity;

  /// RFC-3339 timestamp of the last successful sync, if any.
  final String? lastSynced;

  /// Whether a run is in flight.
  bool get isSyncing => activity == SyncActivity.syncing;

  /// The primary action the footer offers. A dead OR absent session offers
  /// sign-in (never a Sync button that could only fail); otherwise Sync.
  FooterAction get primaryAction => (!isAuthenticated || needsReauth)
      ? (needsReauth ? FooterAction.reauth : FooterAction.signIn)
      : FooterAction.sync;

  /// The status phrase, resolved by the priority ladder.
  FooterStatus get status {
    if (needsReauth) return FooterStatus.sessionExpired;
    if (needsAttention) return FooterStatus.needsAttention;
    if (hasError) return FooterStatus.error;
    if (lastSynced != null) return FooterStatus.synced;
    if (isAuthenticated) return FooterStatus.ready;
    return FooterStatus.offline;
  }
}
