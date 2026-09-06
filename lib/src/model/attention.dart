// The pure half of the "Needs attention" view (#296) — what the sync layer has
// left behind for the user to repair.
//
// A `412` the reconciler cannot absorb forks the local edit into a
// "(conflicted copy)" task (RFC-009 P3): the ORIGINAL row keeps the server's
// content and the COPY carries the edit that lost. Nothing is discarded, which
// is the point — but until now nothing said so either, and the pair sat in the
// list looking like the user had typed the same task twice.
//
// ── Why the two rows are linked by a RECORDED id pair ────────────────────────
// The obvious link is the title: the copy is "<something> (conflicted copy)".
// It does not work. The copy's title is the LOCAL edit's, and the original's is
// the one Google holds — a conflict where the user retitled the task (the
// commonest kind) leaves the two with nothing in common, and where the titles DO
// happen to match, the match may be a different task entirely. So the engine
// records the fork it just made ([ConflictLink]) and the view reads that.
//
// The record is SESSION-scoped, for the same reason the poison cap's is (#270):
// the alternative is a new column, and pre-1.0 a schema change wipes and
// re-pulls every user's local cache (RFC-003). A fork can only happen while the
// app is running, so it is always recorded in the session that can act on it;
// what a relaunch loses is the PAIRING, not the data — both rows are still
// there and the copy still says "(conflicted copy)" in the list.

import '../store/stored.dart';

/// The marker `reconcile.conflictedCopy` appends to the forked local edit.
/// Declared here so the fork and the view that resolves it cannot drift apart.
const String kConflictedCopySuffix = ' (conflicted copy)';

/// [title] without the [kConflictedCopySuffix] marker (unchanged when it carries
/// none) — the title a resolution keeps.
String strippedCopyTitle(String title) => title.endsWith(kConflictedCopySuffix)
    ? title.substring(0, title.length - kConflictedCopySuffix.length)
    : title;

/// A row whose push is HELD by the cap — what the run reports and the "Needs
/// attention" view lists (#296).
///
/// The [id] is the row's LOCAL id, and it is the load-bearing half: the status
/// used to carry titles alone, which is enough to NAME the stuck change and not
/// enough to do anything about it. With the id the view can retry it, discard
/// it, or open it.
class QuarantinedRow {
  const QuarantinedRow({required this.id, required this.title});

  /// The held row's local id (a task id, or a list id for a held list).
  final String id;

  /// Its title — the user's own words, safe to show (#187).
  final String title;

  @override
  bool operator ==(Object other) =>
      other is QuarantinedRow && other.id == id && other.title == title;

  @override
  int get hashCode => Object.hash(id, title);

  @override
  String toString() => 'QuarantinedRow($id, $title)';
}

/// One fork the engine made, as it recorded it: the row that stayed canonical
/// and the copy that preserved the local edit.
class ConflictLink {
  const ConflictLink({required this.originalId, required this.copyId});

  /// Local id of the row that took Google's content.
  final String originalId;

  /// Local id of the freshly created "(conflicted copy)" row.
  final String copyId;

  @override
  bool operator ==(Object other) =>
      other is ConflictLink &&
      other.originalId == originalId &&
      other.copyId == copyId;

  @override
  int get hashCode => Object.hash(originalId, copyId);

  @override
  String toString() => 'ConflictLink($originalId → $copyId)';
}

/// A `412` the reconciler could not absorb, as the user sees it: the [original]
/// row (the server's content, canonical) beside the [copy] that preserved the
/// local edit.
class ConflictedPair {
  const ConflictedPair({required this.original, required this.copy});

  /// The canonical row — the content Google holds.
  final StoredTask original;

  /// The forked local edit, marked with [kConflictedCopySuffix].
  final StoredTask copy;

  /// The name the pair goes by — the canonical row's title.
  String get title => original.task.title;
}

/// The forks in [links] that are still live conflicts, resolved against
/// [tasks].
///
/// A link is dropped — silently, and by design — when either row is gone or
/// tombstoned, or when the copy no longer carries [kConflictedCopySuffix]. Those
/// are exactly the states the three resolutions leave behind (delete the copy;
/// take the marker off it), so acting on a pair is what makes it disappear, with
/// no "resolved" flag to keep in step. Duplicate links collapse to one pair.
///
/// Order follows [links], so the view's ordering is the order the conflicts
/// happened in and does not jump between rebuilds.
List<ConflictedPair> conflictedPairs(
  List<StoredTask> tasks,
  Iterable<ConflictLink> links,
) {
  if (links.isEmpty) return const [];
  final live = {
    for (final t in tasks)
      if (t.syncState != SyncState.deleted) t.task.id: t,
  };
  final pairs = <ConflictedPair>[];
  final seen = <String>{};
  for (final link in links) {
    if (!seen.add(link.copyId)) continue;
    final original = live[link.originalId];
    final copy = live[link.copyId];
    if (original == null || copy == null) continue;
    if (!copy.task.title.endsWith(kConflictedCopySuffix)) continue;
    pairs.add(ConflictedPair(original: original, copy: copy));
  }
  return pairs;
}

/// One change the poison cap is HOLDING, resolved against the live rows: the
/// row itself when it is a task ([task]), and the list it lives in.
class HeldChange {
  const HeldChange({
    required this.id,
    required this.title,
    required this.task,
    required this.listTitle,
  });

  /// The held row's local id — what Retry / Discard / Open act on.
  final String id;

  /// Its title.
  final String title;

  /// The task row, or `null` when the held row is a LIST (the cap holds list
  /// pushes too, #270). A list entry can only be retried: there is no task to
  /// open, and no per-row base snapshot to revert to.
  final StoredTask? task;

  /// The name of the list the task lives in — empty for a held list.
  final String listTitle;
}

/// Everything the "Needs attention" view shows, and nothing else.
///
/// [count] is the badge: held changes + conflicted pairs + the header card, if
/// any. When it is 0 the view does not exist — no sidebar entry, no badge — so
/// [isEmpty] is the single question the shell asks.
class AttentionItems {
  const AttentionItems({
    required this.held,
    required this.conflicts,
    required this.needsReauth,
    required this.needsAttention,
    required this.syncMessage,
  });

  /// An empty view — nothing to repair.
  static const AttentionItems none = AttentionItems(
    held: [],
    conflicts: [],
    needsReauth: false,
    needsAttention: false,
    syncMessage: null,
  );

  /// The rows the cap is holding.
  final List<HeldChange> held;

  /// The unresolved conflicted copies.
  final List<ConflictedPair> conflicts;

  /// The session is dead — the header card offers a sign-in.
  final bool needsReauth;

  /// Sync is stuck on a permanent failure — the header card offers a retry and
  /// the sanitized cause.
  final bool needsAttention;

  /// The sanitized failure text behind [needsAttention] / [needsReauth] (#128).
  final String? syncMessage;

  /// Whether the view carries the header card at all.
  bool get hasHeader => needsReauth || needsAttention;

  /// The badge count — every entry the view shows, the header card included
  /// (it is a thing to act on, so it counts once).
  int get count => held.length + conflicts.length + (hasHeader ? 1 : 0);

  /// Nothing to repair: the view is HIDDEN, not empty.
  bool get isEmpty => count == 0;
}

/// Everything the "Needs attention" view shows, resolved from the live rows and
/// the sync layer's session state.
///
/// A quarantined entry is dropped when its row no longer carries an unpushed
/// change — the row went clean (discarded, or a later push landed) or is gone.
/// The status list is only republished by a RUN, and offline there may not be
/// another one, so the view cannot wait for it to catch up.
AttentionItems attentionItems({
  required List<StoredTask> tasks,
  required List<StoredTaskList> lists,
  required List<QuarantinedRow> quarantined,
  required List<ConflictLink> links,
  required bool needsReauth,
  required bool needsAttention,
  String? syncMessage,
}) {
  // The overwhelmingly common case, re-evaluated on every task write in the
  // app: nothing is held, nothing is forked, sync is fine. Answer it without
  // indexing every row.
  if (quarantined.isEmpty && links.isEmpty && !needsReauth && !needsAttention) {
    return AttentionItems.none;
  }
  final byId = {for (final t in tasks) t.task.id: t};
  final listTitles = {for (final l in lists) l.list.id: l.list.title};
  final held = <HeldChange>[];
  for (final row in quarantined) {
    final task = byId[row.id];
    if (task != null) {
      if (task.syncState == SyncState.clean) continue;
      held.add(
        HeldChange(
          id: row.id,
          title: task.task.title,
          task: task,
          listTitle: listTitles[task.listId] ?? '',
        ),
      );
    } else if (listTitles.containsKey(row.id)) {
      held.add(
        HeldChange(id: row.id, title: row.title, task: null, listTitle: ''),
      );
    }
  }
  return AttentionItems(
    held: held,
    conflicts: conflictedPairs(tasks, links),
    needsReauth: needsReauth,
    needsAttention: needsAttention,
    syncMessage: syncMessage,
  );
}
