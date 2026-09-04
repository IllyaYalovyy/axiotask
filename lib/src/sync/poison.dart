// The poison-row cap (#270): how many times a push is allowed to be REJECTED
// before the row stops being pushed at all.
//
// A transient failure retries silently and clears itself. A *rejection* — a
// 400 the server will answer identically forever, an invalid field, a row
// Google refuses for a reason no retry changes — does not. Before this, such a
// row stayed dirty and was re-pushed on every cadence tick for the life of the
// install, under a status line promising "will retry" that could never come
// true: a request per minute, per row, forever, and a permanent error banner
// the user had no way to act on.
//
// So a rejection is now counted, and after [kPoisonRejectCap] consecutive runs
// the row is QUARANTINED: its push is held, and the status names it and asks
// for the one thing that can actually fix it — an edit.
//
// The release is the row's own `local_updated`. Every local edit moves it (it
// is the same snapshot the whole push pipeline arbitrates its in-flight races
// on), so an edited row no longer matches the counter's base and gets a fresh
// budget with no explicit "clear" call anywhere in the mutation paths. That is
// the entire release mechanism — there is nothing to forget to call.
//
// The registry is SESSION-scoped, deliberately: it lives in the scheduler and
// is handed to each run's engine. A relaunch is itself a legitimate "try
// again", and the alternative — persisting the counter — is a schema change
// that would wipe and re-pull every user's local cache (RFC-003) to buy a
// backoff that costs at most five requests per launch.

/// Consecutive rejected pushes after which a row is quarantined.
const int kPoisonRejectCap = 5;

class _Entry {
  _Entry(this.baseLocalUpdated) : runs = 0;

  /// The row's `local_updated` when this streak started. A different value
  /// means the user edited the row: the streak is void.
  String baseLocalUpdated;

  /// Consecutive rejections observed against [baseLocalUpdated].
  int runs;
}

/// Counts consecutive push rejections per row and decides when one is
/// quarantined. Owned by the scheduler; passed into every run's engine.
class PoisonRegistry {
  final Map<String, _Entry> _entries = {};

  /// Record that [id]'s push was rejected while the row read [localUpdated],
  /// and return the resulting consecutive-rejection count. A [localUpdated]
  /// that differs from the streak's base restarts the count at 1 — the user
  /// changed the row, so this is a new thing to reject.
  int recordRejection(String id, String localUpdated) {
    final entry = _entries.putIfAbsent(id, () => _Entry(localUpdated));
    if (entry.baseLocalUpdated != localUpdated) {
      entry
        ..baseLocalUpdated = localUpdated
        ..runs = 0;
    }
    return entry.runs += 1;
  }

  /// Whether [id] at [localUpdated] has exhausted its push budget and must not
  /// be sent again until it is edited.
  bool isQuarantined(String id, String localUpdated) {
    final entry = _entries[id];
    return entry != null &&
        entry.baseLocalUpdated == localUpdated &&
        entry.runs >= kPoisonRejectCap;
  }

  /// Drop every entry whose row is not in [liveIds] — it was pushed, deleted,
  /// or is no longer dirty, so its streak is over and its slot is dead weight.
  void retainAll(Set<String> liveIds) =>
      _entries.removeWhere((id, _) => !liveIds.contains(id));
}
