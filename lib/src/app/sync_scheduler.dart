// The background sync scheduler — the Dart port of the scheduler half of
// `state.rs`: the trigger/debounce loop, the permanent-failure backoff, the
// sanitized user messages (#128/#135), the log-dedup that keeps a stuck sync
// from spamming the log (#131), the flush-on-exit, and the notifier stream that
// tells the UI about background runs.
//
// The engine itself is stateless (each `run()` is independent, T5.5–T5.8); this
// layer owns the *policy* around it: WHEN to run, HOW to react to the outcome,
// and WHAT the user is allowed to see about a failure. Everything here is
// unit-testable without a real clock or network — timing flows through
// [waitForSyncTrigger] (driven by fake time in tests) and auth flows through the
// [AuthState] seam.

import 'dart:async';

import '../api/api_error.dart';
import '../api/tasks_api.dart' show TasksApi;
import '../model/dates.dart' show nowUtcString;
import '../store/store.dart';
import '../sync/engine.dart';
import '../sync/sync_error.dart';
import 'auth_state.dart';
import 'logging.dart';
import 'sync_status.dart';

/// Debounce window: coalesce rapid mutations into a single sync.
const Duration kSyncDebounce = Duration(seconds: 2);

/// Periodic sync interval to catch remote changes.
const Duration kSyncPeriod = Duration(seconds: 60);

/// Upper bound on the final sync run when the app is exiting. Exit blocks on
/// this flush, so a hung connection must never hold the window open forever; on
/// timeout, anything unpushed just syncs on the next launch.
const Duration kExitSyncTimeout = Duration(seconds: 10);

/// Ceiling for the exponential backoff applied after a *permanent* sync
/// failure. A dead schema or corrupt store fails identically on every retry, so
/// the periodic cadence stretches from [kSyncPeriod] up to this cap instead of
/// hammering the same failure every minute forever.
const Duration kSyncMaxBackoff = Duration(hours: 1);

/// The periodic delay before the next background sync, given how many
/// consecutive *permanent* failures have occurred. `streak == 0` (healthy, or
/// only transient failures) keeps the base cadence; each permanent failure
/// doubles the delay, capped at [cap]. A mutation trigger still fires promptly
/// (see [waitForSyncTrigger]) — only the idle polling cadence backs off.
Duration backoffPeriod(Duration base, int streak, Duration cap) {
  if (streak == 0) return base;
  final baseSecs = base.inSeconds;
  final capSecs = cap.inSeconds;
  // 2^streak, saturating to the cap. All arithmetic stays in SECONDS and clamps
  // BEFORE building a Duration: Dart Durations are microsecond-backed int64, so
  // a multi-year second-count would overflow if constructed first. The exponent
  // is capped well past where the result already exceeds `cap`, so the shift and
  // multiply can never overflow either.
  final exponent = streak >= 40 ? 40 : streak;
  final factor = 1 << exponent;
  final scaledSecs = baseSecs > capSecs ~/ factor ? capSecs : baseSecs * factor;
  return Duration(seconds: scaledSecs > capSecs ? capSecs : scaledSecs);
}

/// A user-safe description of a sync failure (#128, #135).
///
/// The [SyncStatus.lastError] this produces is rendered verbatim in the "Sync
/// failed" toast and the Properties dialog. Anything that carries internal
/// detail is replaced with a calm sentence pointing at the log — the full typed
/// error is still written to the log at the call site:
///
///  - A store failure carries raw SQL text.
///  - An internal error carries an assertion/bug string.
///  - [Network] carries raw transport text, which can embed the full request
///    URL and its query params (#135).
///
/// The remaining API failures (5xx, rate-limit, precondition, …) are already
/// human and carry no internals, so their text is kept — the user still sees
/// "server error: 503" rather than a generic sentence.
String syncUserMessage(SyncError e) => switch (e) {
  SyncStoreError() =>
    'Sync hit a local database problem — the details are in the log.',
  SyncInternalError() =>
    'Sync hit an unexpected internal error — the details are in the log.',
  SyncApiError(:final error) when error is Network =>
    "Can't reach Google right now — the details are in the log.",
  SyncApiError(:final error) => apiUserText(error),
};

/// The human, internals-free text of an API error — the Dart port of the
/// reference's `ApiError` `Display`. Only the variants that carry no internal
/// detail are surfaced this way (see [syncUserMessage]).
///
/// [AuthExpired] (a refresh-denial string) and [Network] (transport text that
/// can embed the full request URL + query params, #135) are both intercepted
/// upstream before they could reach here — [AuthExpired] by the reauth branch
/// in [SyncScheduler._recordOutcome], [Network] by [syncUserMessage]'s own arm
/// — so those arms are dead. They are kept OFF this surface deliberately: were
/// a future caller to route one through, it must still get a calm, log-pointing
/// sentence, never the raw detail (#187).
String apiUserText(ApiError e) => switch (e) {
  Unauthorized() => 'unauthorized',
  NotFound() => 'not found',
  PreconditionFailed() => 'precondition failed (etag mismatch)',
  RateLimited() => 'rate limited',
  ServerError(:final status) => 'server error: $status',
  OtherApiError(:final message) => 'other: $message',
  AuthExpired() ||
  Network() => 'Sync hit an error — the details are in the log.',
};

/// How to log one permanent sync failure, and what to remember for the next run.
class PermanentFailureLog {
  const PermanentFailureLog({
    required this.logAtError,
    required this.rawDetail,
    required this.userMsg,
  });

  /// Log this occurrence at ERROR (a first-time or *changed* failure) rather
  /// than DEBUG (an identical repeat that would otherwise spam the log every
  /// cadence tick).
  final bool logAtError;

  /// The full typed detail (`SyncError.toString()`): written to the log AND kept
  /// as the dedup key for the next run. May carry raw SQL — never shown to the
  /// user.
  final String rawDetail;

  /// The sanitized, user-safe message for [SyncStatus.lastError] (#128).
  final String userMsg;
}

/// Decide how to log a permanent sync failure and dedup it against the last one.
///
/// Dedup is keyed on the RAW typed detail, NOT the sanitized display message
/// (#131). Every store failure sanitizes to one calm sentence and every internal
/// failure to another, so two *distinct* root causes routinely collapse to
/// identical user-facing text. Keying the dedup on that sanitized text would
/// swallow a genuinely new failure as a "repeat" and bury it at DEBUG. Keying on
/// the raw detail gives every distinct failure its own first-time ERROR line,
/// while an *identical* failure that repeats every cadence tick still drops to
/// DEBUG so it stops burying everything else.
PermanentFailureLog classifyPermanentFailure(
  bool prevAttention,
  String? prevRawError,
  SyncError e,
) {
  final rawDetail = e.toString();
  final logAtError = !prevAttention || prevRawError != rawDetail;
  return PermanentFailureLog(
    logAtError: logAtError,
    rawDetail: rawDetail,
    userMsg: syncUserMessage(e),
  );
}

/// A single-permit notification, the Dart analog of tokio's `Notify`: a mutation
/// calls [notifyOne]; the loop awaits [notified]. Multiple notifications before
/// the next wait COALESCE into one permit — a burst of edits triggers a single
/// sync, not one per edit.
class SyncNotify {
  Completer<void>? _waiter;
  bool _pending = false;

  /// Store a permit (or wake the current waiter). Idempotent while a permit is
  /// already pending — this is what makes rapid mutations coalesce.
  void notifyOne() {
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete();
    } else {
      _pending = true;
    }
  }

  /// Await the next permit. Returns immediately if one is already pending
  /// (consuming it); otherwise completes when [notifyOne] is next called.
  Future<void> notified() {
    if (_pending) {
      _pending = false;
      return Future<void>.value();
    }
    return (_waiter = Completer<void>()).future;
  }
}

/// Wait until it is time to run a sync: either a mutation arrives (then wait out
/// the [debounce] so a burst coalesces) or the idle [period] elapses. Mirrors
/// the reference's `tokio::select!`: whichever arm resolves first wins, and a
/// single guarded [Completer] makes the loser fire into the already-completed
/// guard. Scheduling goes through [Future.delayed] — no raw `Timer` — so the
/// loop stays fully controllable under fake time.
///
/// Unlike tokio's `select!`, the losing arm's future is NOT dropped here — Dart
/// has no cancellation — so the [notify] waiter this call registers survives the
/// idle-arm win still armed inside [SyncNotify]. If a [SyncNotify.notifyOne]
/// then lands on that stale waiter, its permit would be spent completing a
/// completer nobody awaits and silently lost (#186). The notified arm guards
/// against exactly that: when it fires into an already-decided race, it re-arms
/// the notifier so the queued mutation is handed to the NEXT
/// [waitForSyncTrigger] instead of vanishing.
Future<void> waitForSyncTrigger(
  SyncNotify notify,
  Duration debounce,
  Duration period,
) async {
  final result = Completer<bool>(); // true = mutation, false = idle period.
  unawaited(
    Future<void>.delayed(period).then((_) {
      if (!result.isCompleted) result.complete(false);
    }),
  );
  unawaited(
    notify.notified().then((_) {
      if (!result.isCompleted) {
        result.complete(true);
      } else {
        // The idle arm already decided this cycle; this permit arrived for a
        // waiter that lost the race. Dropping it would swallow the mutation
        // (#186) — re-arm the notifier so the next waitForSyncTrigger sees it
        // and fires as a mutation trigger rather than waiting out another full
        // idle period. notifyOne coalesces, so this can never over-count.
        notify.notifyOne();
      }
    }),
  );

  final triggered = await result.future;
  if (triggered) {
    await Future<void>.delayed(debounce);
  }
}

/// Owns the policy around the stateless [SyncEngine]: the trigger loop, the
/// permanent-failure backoff, the sanitized status, and the notifier stream.
class SyncScheduler {
  SyncScheduler({
    required this.store,
    required this.client,
    required this.auth,
    required this.pushEnabled,
    this.debounce = kSyncDebounce,
    this.period = kSyncPeriod,
  });

  /// The local cache this engine syncs against (public, mirroring the
  /// reference's `pub store`).
  final Store store;

  /// The current Tasks API client — a getter so a re-login can swap it under the
  /// scheduler without reconstructing it.
  final TasksApi Function() client;

  /// The auth seam: is a session live, and is it dead (needs-reauth)?
  final AuthState auth;

  /// Whether local changes are pushed (read-write) vs pulled only (read-only).
  final bool Function() pushEnabled;

  /// Debounce window and idle poll cadence (injectable for deterministic tests).
  final Duration debounce;
  final Duration period;

  final SyncNotify _notify = SyncNotify();
  final SyncStatus _status = SyncStatus();
  final StreamController<SyncStatusView> _statusController =
      StreamController<SyncStatusView>.broadcast();
  final StreamController<SyncRunEvent> _runController =
      StreamController<SyncRunEvent>.broadcast();

  /// Serializes sync runs — only one runs at a time (prevents double-push
  /// races). The tail of the currently-running (or last) run.
  Future<void>? _guard;

  /// Consecutive *permanent* failures — drives [nextSyncPeriod]'s backoff. Reset
  /// to 0 by the first success; a transient failure or dead session leaves it
  /// untouched (they have their own handling).
  int _attentionStreak = 0;

  /// The id of the one task the UI is actively holding (inline editor row or
  /// open detail panel). Its CREATE push is held so an id remap can't invalidate
  /// the id the UI operates on. `null` when nothing is being edited.
  String? _heldCreateId;

  /// A snapshot of the current sync status — the UI-safe projection. It carries
  /// the sanitized [SyncStatusView.lastError] and NEVER the raw error detail:
  /// [SyncStatus.lastRawError] (which may hold raw SQL / a request URL) stays
  /// private to the scheduler as its log-dedup key (#131/#187).
  SyncStatusView get status => SyncStatusView.of(_status);

  /// Emitted once after every sync run so the UI can react to background syncs,
  /// not just manual "Sync now" clicks. Each event is an independent, sanitized
  /// snapshot — the same projection [status] returns, so no raw error text can
  /// ride the stream to a subscriber (#131/#187).
  Stream<SyncStatusView> get statuses => _statusController.stream;

  /// Emitted at the START and again at the END of every run — the transient
  /// signal the quiet sync line and the footer check-mark ride (#255).
  /// [statuses] cannot serve: it fires only after a run, so nothing on it can
  /// say "a run is happening now", and its counters survive a failure.
  ///
  /// Broadcast and non-replaying: a subscriber that mounts mid-run misses the
  /// start, which is right — it has no line up to take down.
  Stream<SyncRunEvent> get runs => _runController.stream;

  /// Wake the background loop (a mutation happened). A no-op unless the loop is
  /// running and — via its own auth gate — actually authenticated.
  void scheduleSync() => _notify.notifyOne();

  /// Record the id of the task the UI is holding, or `null` when nothing is
  /// being edited. Only that one task's create push is held; every other create
  /// still syncs.
  void setEditingTask(String? id) => _heldCreateId = id;

  /// Dirty (unpushed) local changes that a flush/sync would send.
  Future<int> pendingPushCount() => store.pendingPushCount();

  /// The delay before the next *idle* periodic sync — the base cadence while
  /// healthy, backing off exponentially after consecutive permanent failures.
  Duration nextSyncPeriod() =>
      backoffPeriod(period, _attentionStreak, kSyncMaxBackoff);

  /// Run the background sync loop forever. Spawn this once at startup.
  Future<void> runLoop() async {
    while (true) {
      await runSyncCycle();
    }
  }

  /// One iteration of the loop: wait for a trigger, then sync iff the session is
  /// alive. Split out from [runLoop] so the trigger/gate logic is testable
  /// without an infinite loop.
  Future<void> runSyncCycle() async {
    await waitForSyncTrigger(_notify, debounce, nextSyncPeriod());
    // A dead session fails identically on every attempt — don't churn (and spam
    // the token endpoint) until the user signs in again. Manual "Sync now" stays
    // available as an explicit re-check.
    if (auth.needsReauth) {
      Log.debug(
        'background sync skipped: session expired, waiting for re-login',
      );
      return;
    }
    if (auth.isAuthenticated) {
      try {
        await runSyncIfAuthed();
      } catch (e) {
        // run_sync already logged/recorded the failure; a WARN here would just
        // spam the log again from this layer.
        Log.debug('background sync failed: $e');
      }
    }
  }

  /// Run sync only if authenticated. Rejects with a [StateError] when signed
  /// out (async so the failure is always a rejected future, never a synchronous
  /// throw the caller might not be guarding).
  Future<SyncOutcome> runSyncIfAuthed() async {
    if (!auth.isAuthenticated) {
      throw StateError('not authenticated');
    }
    return runSync();
  }

  /// Run sync immediately. Does NOT check authentication (use [runSyncIfAuthed]
  /// for guarded access). Serialized via the guard — a concurrent call waits.
  Future<SyncOutcome> runSync() => _serialized(_runSyncInner);

  Future<SyncOutcome> _runSyncInner() async {
    // While the user is mid-edit, hold ONLY the create of the exact row the UI
    // is holding: a create remaps a local id to the server id, which would
    // invalidate that id. Every other create still pushes.
    final heldCreateId = _heldCreateId;
    final engine = SyncEngine.withPush(
      client(),
      store,
      pushEnabled(),
    ).holdCreateId(heldCreateId);

    SyncOutcome? outcome;
    SyncError? error;
    // The line goes up here and comes down in the `finally` — so it comes down
    // on a failure, on a rethrow, and on an error no arm below catches. A
    // progress line that can outlive its run is worse than no line at all.
    _emitRun(const SyncRunEvent.started());
    try {
      try {
        outcome = await engine.run();
      } on SyncError catch (e) {
        error = e;
      }

      _recordOutcome(outcome, error);
      // Emit the SANITIZED projection, not the raw record: the internal
      // lastRawError (dedup key, may carry SQL) must never reach a subscriber
      // (#131/#187). SyncStatusView.of is an independent snapshot, so a later
      // run's mutation can't retroactively alter what a listener received.
      final snapshot = SyncStatusView.of(_status);
      if (!_statusController.isClosed) _statusController.add(snapshot);
    } finally {
      final moved =
          outcome != null &&
          (outcome.pulled > 0 || outcome.pushed > 0 || outcome.deleted > 0);
      _emitRun(SyncRunEvent.finished(changed: moved, failed: outcome == null));
    }

    if (error != null) throw error;
    return outcome!;
  }

  void _emitRun(SyncRunEvent event) {
    if (!_runController.isClosed) _runController.add(event);
  }

  void _recordOutcome(SyncOutcome? outcome, SyncError? error) {
    if (outcome != null) {
      _status.lastSynced = nowUtcString();
      // A working sync proves the session is alive again (e.g. after re-login,
      // or a mis-flagged transient).
      auth.setNeedsReauth(false);
      _status.needsReauth = false;
      // A success also clears any "needs attention" backoff — the stuck failure
      // resolved, so the idle cadence returns to base.
      _attentionStreak = 0;
      _status.needsAttention = false;
      // The stuck failure resolved: forget its raw dedup key so a later,
      // identical permanent failure re-logs at ERROR (#131).
      _status.lastRawError = null;
      _status.lastPulled = outcome.pulled;
      _status.lastPushed = outcome.pushed;
      _status.lastConflicts = outcome.conflicts;
      _status.lastDeleted = outcome.deleted;
      _status.totalSyncs += 1;
      // A row the server rejected stays dirty and would retry silently forever —
      // tell the user instead of hiding it behind a green "synced" state.
      _status.lastError = outcome.errors > 0
          ? '${outcome.errors} change${outcome.errors == 1 ? '' : 's'} '
                'rejected by the server (kept locally, will retry)'
          : null;
      return;
    }

    final e = error!;
    if (e.isAuthExpired) {
      // The refresh token is dead — stop the background retry churn and tell the
      // user what to actually do. Its own state, distinct from needs-attention.
      Log.error('sync failed: session expired — sign in again');
      auth.setNeedsReauth(true);
      _status.needsReauth = true;
      _attentionStreak = 0;
      _status.needsAttention = false;
      _status.lastError =
          'Google session expired — sign in again to resume sync';
    } else if (e.isTransient) {
      // A blip that clears itself (network / 5xx / rate-limit) — keep retrying
      // silently at the base cadence. No attention, no backoff. The full typed
      // error goes to the log; the user only sees the sanitized sentence (#135).
      Log.warn('transient sync failure, will retry: $e');
      _status.lastError = syncUserMessage(e);
    } else {
      // Permanent: fails identically on every retry until something changes.
      // Surface it as "needs attention" and back the idle cadence off. Log at
      // ERROR only the first time a DISTINCT failure appears — keyed on the RAW
      // typed detail (#131) — so a stuck sync repeating the same failure drops
      // to DEBUG. Full typed detail goes to the log; the user only sees the
      // sanitized message (#128).
      final log = classifyPermanentFailure(
        _status.needsAttention,
        _status.lastRawError,
        e,
      );
      if (log.logAtError) {
        Log.error('sync failed (needs attention): ${log.rawDetail}');
      } else {
        Log.debug(
          'sync still failing (unchanged, backing off): ${log.rawDetail}',
        );
      }
      _attentionStreak += 1;
      _status.needsAttention = true;
      _status.lastRawError = log.rawDetail;
      _status.lastError = log.userMsg;
    }
  }

  /// Flush pending local changes to Google before the process exits.
  ///
  /// The background loop dies with the process, and a mutation is only pushed
  /// after the debounce — so a change made and then immediately quit is stranded
  /// dirty until the next launch. On exit we push it now instead.
  ///
  /// Only acts when it can actually push — signed in, push enabled, session
  /// alive, and something pending — otherwise a pointless or destructive round
  /// trip is skipped (a signed-out flush would push to the throwaway offline
  /// client and wrongly mark rows clean). The window is closing, so nothing
  /// holds an id anymore: the held create is released first so it pushes with
  /// everything else. Bounded by [kExitSyncTimeout] so a hung network can never
  /// block the app from closing.
  Future<void> flushOnExit() async {
    if (!auth.isAuthenticated || !pushEnabled() || auth.needsReauth) {
      return;
    }
    // Nothing dirty → don't delay exit on a network round trip.
    if (await pendingPushCount() == 0) return;
    // Release the panel's held create — the panel is gone, so its id may safely
    // remap now — and push everything.
    setEditingTask(null);
    try {
      await runSync().timeout(kExitSyncTimeout);
    } on TimeoutException {
      Log.warn(
        'exit sync timed out after ${kExitSyncTimeout.inSeconds}s; '
        'unpushed changes remain local until next launch',
      );
    } on SyncError catch (e) {
      Log.warn('exit sync failed; unpushed changes remain local: $e');
    }
  }

  /// Release the notifier streams. Call at shutdown.
  Future<void> dispose() async {
    await _statusController.close();
    await _runController.close();
  }

  /// Run [body] after any in-flight run finishes, and make the NEXT caller wait
  /// on this one — a tiny async mutex over the sync guard.
  Future<T> _serialized<T>(Future<T> Function() body) async {
    final prev = _guard;
    final done = Completer<void>();
    _guard = done.future;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {
        // A prior run's failure must not poison the queue — we only wait for it
        // to FINISH, not succeed.
      }
    }
    try {
      return await body();
    } finally {
      done.complete();
      if (identical(_guard, done.future)) _guard = null;
    }
  }
}
