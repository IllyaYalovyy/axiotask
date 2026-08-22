// One recorded sync run, as the Sync activity screen shows it (#218), plus the
// closed vocabulary of failure classifications that screen renders.
//
// PRIVACY (#131/#187): a run's failure is persisted and displayed as a
// CLASSIFICATION — a value from [SyncFailureKind] — never as provider or API
// text. The raw typed detail of a failure goes to the log and nowhere else; it
// can embed a request URL with query params (#135), a refresh-denial string, raw
// SQL, or the body of a captive-portal login page. A closed enum cannot leak any
// of that no matter what the provider returned.
//
// Pure Dart: no Flutter, no drift, no error types (the mapping from a typed
// [SyncError] to its kind lives with the errors, in `sync/sync_error.dart`).

/// How a sync run failed, in a fixed vocabulary that carries no provider text.
enum SyncFailureKind {
  /// Google was unreachable (transport failure, captive portal, no route).
  network,

  /// The stored session is dead — the user must sign in again.
  auth,

  /// The request was rejected as unauthorized (scopes/credentials).
  unauthorized,

  /// Google rate-limited us.
  rateLimited,

  /// Google answered with a server-side error (5xx).
  server,

  /// A list or task the run asked for is gone from Google.
  notFound,

  /// An etag precondition failed (someone else changed the row first).
  precondition,

  /// The local database could not be read or written.
  store,

  /// An internal invariant broke — a bug on our side.
  internal,

  /// Anything else. Deliberately the catch-all for provider text we refuse to
  /// persist or display.
  unknown;

  /// Parse the value persisted in `sync_log.error`. `null`/empty means the run
  /// SUCCEEDED (no failure recorded); an unrecognized code is [unknown] rather
  /// than a crash — a row is data, and data can be wrong.
  static SyncFailureKind? parse(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final k in SyncFailureKind.values) {
      if (k.name == code) return k;
    }
    return SyncFailureKind.unknown;
  }
}

/// The user-facing sentence for a failure classification. Internals-free by
/// construction: it is a function of the enum alone, so no provider text can
/// reach it (#131/#187).
String syncFailureLabel(SyncFailureKind kind) => switch (kind) {
  SyncFailureKind.network => "Couldn't reach Google",
  SyncFailureKind.auth => 'Google session expired — sign in again',
  SyncFailureKind.unauthorized => 'Not authorized',
  SyncFailureKind.rateLimited => 'Rate limited by Google',
  SyncFailureKind.server => 'Google had a server problem',
  SyncFailureKind.notFound => 'Something was missing on Google',
  SyncFailureKind.precondition => 'Changed elsewhere first (etag mismatch)',
  SyncFailureKind.store => 'Local database problem',
  SyncFailureKind.internal => 'Unexpected internal error',
  SyncFailureKind.unknown => 'Sync failed — the details are in the log',
};

/// One row of `sync_log`: what a single sync run did, and how it ended.
class SyncRun {
  const SyncRun({
    required this.id,
    required this.ranAt,
    required this.durationMs,
    required this.pulled,
    required this.pushed,
    required this.conflicts,
    required this.failure,
  });

  /// The row's autoincrement id — also the run order (newest = highest).
  final int id;

  /// When the run finished, as a UTC instant. `null` only when the stored
  /// timestamp is unparseable; the UI renders such a run without a time rather
  /// than dropping it, because a run that happened is worth showing.
  final DateTime? ranAt;

  /// How long the run took, in milliseconds.
  final int durationMs;

  /// Tasks pulled from Google, pushed to Google, and conflicts resolved.
  final int pulled;
  final int pushed;
  final int conflicts;

  /// The failure classification, or `null` when the run succeeded.
  final SyncFailureKind? failure;

  /// Whether this run ended in a failure.
  bool get failed => failure != null;
}
