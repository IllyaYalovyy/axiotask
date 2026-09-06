// The forks a session has made — the conflicted-copy analogue of
// [PoisonRegistry] (#296).
//
// When the 412 resolver forks a "(conflicted copy)" it is the ONLY moment at
// which the two rows are known to belong together: the copy is a fresh create
// with a new id, and after it lands there is nothing in the schema tying it back
// (see `model/attention.dart` for why the title cannot). So the fork is recorded
// here, as it happens.
//
// Like the poison registry this is SESSION-scoped and owned by the scheduler,
// then handed to each run's engine — for the same reason: persisting it means a
// new column, and pre-1.0 a schema change wipes and re-pulls every user's local
// cache (RFC-003). Entries are never removed here; the view drops the ones whose
// rows no longer form a conflict, which is what makes resolving one enough to
// clear it.

import '../model/attention.dart';

/// The forks made this session, in the order they happened.
class ConflictRegistry {
  final List<ConflictLink> _links = [];

  /// Every recorded fork, oldest first.
  List<ConflictLink> get links => List.unmodifiable(_links);

  /// Record that [copyId] was forked from [originalId]. Idempotent per copy —
  /// a copy id is minted once, so a repeat can only be a re-record.
  void record({required String originalId, required String copyId}) {
    if (_links.any((l) => l.copyId == copyId)) return;
    _links.add(ConflictLink(originalId: originalId, copyId: copyId));
  }
}
