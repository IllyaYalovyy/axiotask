// Live sync status and running stats — the Dart port of `state.rs`'s
// `SyncStatus` (the internal, full record) and `commands.rs`'s `SyncStatusView`
// (the sanitized, UI-facing DTO).
//
// The split is load-bearing for privacy (#131): [SyncStatus] keeps
// [SyncStatus.lastRawError] — the RAW typed error detail used ONLY to dedup log
// lines across cadence ticks — which can carry raw SQL and must never reach the
// UI. [SyncStatusView] is what the Properties dialog and the sync-updated
// notification render, and it deliberately omits that field.

/// Live sync status and running stats.
///
/// Mutated in place after every sync run (success or failure) and cloned into a
/// snapshot for the notifier stream and the [status] getter — mirroring the
/// reference's `Mutex<SyncStatus>` that is locked, updated, then cloned.
class SyncStatus {
  /// RFC-3339 timestamp of the last *successful* sync, if any.
  String? lastSynced;

  /// Counts from the last successful sync.
  int lastPulled = 0;
  int lastPushed = 0;
  int lastConflicts = 0;
  int lastDeleted = 0;

  /// Number of successful syncs since the app started.
  int totalSyncs = 0;

  /// Message from the most recent sync failure, cleared on the next success.
  /// This is the *sanitized*, user-safe text (#128) — it is what the UI shows.
  String? lastError;

  /// The RAW typed detail (`SyncError.toString()`) of the most recent
  /// *permanent* failure, kept ONLY to dedup log lines across cadence ticks
  /// (#131). Distinct from [lastError]: two different root causes can sanitize
  /// to the same calm sentence, so the dedup key must be the raw detail or a
  /// genuinely new failure would be swallowed as a "repeat" and logged at
  /// DEBUG. May carry raw SQL, so it is NEVER surfaced to the UI (absent from
  /// [SyncStatusView]). Cleared on success.
  String? lastRawError;

  /// A *permanent* (non-transient, non-auth) failure is stuck — store
  /// corruption, a schema mismatch, a deserialization bug. Retrying is
  /// pointless until something changes, so the scheduler has backed off and the
  /// UI surfaces [lastError] as a "sync needs attention" state. Distinct from a
  /// transient blip (silently retried, this stays false) and from a dead
  /// session ([needsReauth], its own state). Cleared by the first success.
  bool needsAttention = false;

  /// The stored session is dead (token refresh permanently denied) — the user
  /// must sign in again. Mirrored into every status snapshot so the notifier
  /// carries it and the UI can surface a re-auth action, not just an error.
  bool needsReauth = false;

  /// A deep copy — the notifier emits snapshots so a later run's mutation can
  /// never retroactively alter what a listener already received.
  SyncStatus clone() => SyncStatus()
    ..lastSynced = lastSynced
    ..lastPulled = lastPulled
    ..lastPushed = lastPushed
    ..lastConflicts = lastConflicts
    ..lastDeleted = lastDeleted
    ..totalSyncs = totalSyncs
    ..lastError = lastError
    ..lastRawError = lastRawError
    ..needsAttention = needsAttention
    ..needsReauth = needsReauth;
}

/// The sanitized, UI-facing projection of [SyncStatus] — the Dart port of
/// `SyncStatusView`. Everything the Properties dialog and the sync-updated
/// notification need, and NOTHING that leaks internals: [SyncStatus.lastRawError]
/// (which may carry raw SQL) is deliberately absent (#131).
class SyncStatusView {
  const SyncStatusView({
    required this.lastSynced,
    required this.lastPulled,
    required this.lastPushed,
    required this.lastConflicts,
    required this.lastDeleted,
    required this.totalSyncs,
    required this.lastError,
    required this.needsAttention,
    required this.needsReauth,
  });

  /// Project a [SyncStatus] to its UI-safe view, dropping the raw error detail.
  factory SyncStatusView.of(SyncStatus s) => SyncStatusView(
    lastSynced: s.lastSynced,
    lastPulled: s.lastPulled,
    lastPushed: s.lastPushed,
    lastConflicts: s.lastConflicts,
    lastDeleted: s.lastDeleted,
    totalSyncs: s.totalSyncs,
    lastError: s.lastError,
    needsAttention: s.needsAttention,
    needsReauth: s.needsReauth,
  );

  final String? lastSynced;
  final int lastPulled;
  final int lastPushed;
  final int lastConflicts;
  final int lastDeleted;
  final int totalSyncs;

  /// The most recent sync error — the *sanitized* text, cleared on next success.
  final String? lastError;
  final bool needsAttention;
  final bool needsReauth;

  /// A "never synced" snapshot — the Properties Sync tab's default before any
  /// sync has run (and the seam value until the scheduler is wired in).
  const SyncStatusView.initial()
    : lastSynced = null,
      lastPulled = 0,
      lastPushed = 0,
      lastConflicts = 0,
      lastDeleted = 0,
      totalSyncs = 0,
      lastError = null,
      needsAttention = false,
      needsReauth = false;
}

/// A live signal about ONE sync run — the transient facts the outcome-carrying
/// [SyncStatusView] deliberately does not hold (#255).
///
/// The status record answers "where does sync stand": it is emitted once, AFTER
/// a run, and a UI reading it can tell neither that a run is in flight nor
/// whether the run that just ended actually moved anything (its counters are
/// left untouched by a failure, so yesterday's numbers survive today's error).
/// The quiet sync line needs the first fact and the footer's check-mark the
/// second, so the scheduler emits this pair of transitions around every run.
///
/// Sanitized by construction: three booleans, no provider text, no counts that
/// could name a list or a task (#131/#187).
class SyncRunEvent {
  /// A run has just STARTED — the line appears.
  const SyncRunEvent.started()
    : running = true,
      changed = false,
      failed = false;

  /// A run has just ENDED, whatever its outcome — the line fills and fades.
  const SyncRunEvent.finished({required this.changed, required this.failed})
    : running = false;

  /// Whether a run is in flight as of this event.
  final bool running;

  /// Whether the finished run MOVED data — anything pulled, pushed or deleted.
  /// A clean no-op poll (by far the common case, once a minute, forever) is
  /// `false`, and the footer stays silent for it.
  final bool changed;

  /// Whether the finished run ended in a failure. Failures keep their existing
  /// toast/status path — the line simply goes, it never turns red — but a
  /// failed run has, by definition, confirmed nothing.
  final bool failed;

  @override
  bool operator ==(Object other) =>
      other is SyncRunEvent &&
      other.running == running &&
      other.changed == changed &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(running, changed, failed);

  @override
  String toString() => running
      ? 'SyncRunEvent.started()'
      : 'SyncRunEvent.finished(changed: $changed, failed: $failed)';
}
