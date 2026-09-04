// Which rows are moving this frame, and why — the list's whole choreography,
// lifted out of the pane (#274).
//
// Three things happen to a list slot that is not "a row is simply there":
//
//   • #241 a row was COMPLETED out of a filtered list: instead of popping out
//     it renders once more, ticked, then folds its height to zero;
//   • #251 a row LEFT for any other reason (deleted, rescheduled out of the
//     view, moved to another list, dropped by a sync pull) and folds away, or
//     ARRIVED and grows into place;
//   • #252 a row that was already on screen CHANGED, and the element that
//     changed flashes.
//
// All three are the same question asked of one before/after pair — the rows the
// last build showed against the rows this one shows — which is why they live in
// one object. It is a plain object, not a widget: given the same pair it
// produces the same slots, so the sequencing rules (the row cap, the stagger,
// the expiry of a hold whose row never rendered) can be tested directly instead
// of being inferred from pixels.
//
// Restraint is enforced HERE rather than in the widgets: at most
// [listMotionRowCap] rows are given a motion on any one change and the rest
// simply snap, so a sync that rewrites two hundred rows is over within
// [listMotionWindow] instead of rippling for seconds.

import '../model/task.dart';
import '../store/stored.dart';
import 'commit_flash.dart' show CommitTarget, TaskCommit;
import 'completion_motion.dart';
import 'list_motion.dart';
import 'motion.dart' show MotionDurations;
import 'visible_rows.dart';

/// What a rendered list slot is doing this frame.
enum SlotMotion {
  /// Nothing — the row is simply part of the list.
  none,

  /// The row has just joined and is growing into place (#251).
  entering,

  /// The row was completed out of the filtered list and is playing #241's
  /// settle-then-collapse.
  completing,

  /// The row left for any other reason and is folding away (#251).
  leaving,
}

/// One rendered list slot: a row, what its motion is doing, and where it sits
/// in the stagger.
class RowItem {
  const RowItem(
    this.row, {
    this.motion = SlotMotion.none,
    this.delay = Duration.zero,
  });

  final TaskRowData row;
  final SlotMotion motion;
  final Duration delay;

  String get id => row.id;

  /// Whether the slot is held open only to play a departure — it holds a list
  /// index but no place in the live task order.
  bool get departing =>
      motion == SlotMotion.completing || motion == SlotMotion.leaving;
}

/// A row held for its departure: the snapshot to draw, the row index it
/// occupied when it left, and its place in the stagger.
class _Departing {
  const _Departing(
    this.row,
    this.index,
    this.since, {
    this.delay = Duration.zero,
  });

  final TaskRowData row;
  final int index;

  /// The frame the row left on, so a hold can be expired even if its row is
  /// never built (it departed off-screen) and never reports back.
  final Duration since;

  /// How long this row waits before its fold starts. Always zero for a
  /// completion, which is a one-row event by construction.
  final Duration delay;
}

/// A row that has just arrived and is still growing into place.
class _Arrival {
  const _Arrival(this.delay, this.since);

  final Duration delay;

  /// The frame it arrived on, so an arrival that is never built (it landed
  /// off-screen) is eventually forgotten instead of animating whenever the
  /// user happens to scroll to it.
  final Duration since;
}

/// The list's motion bookkeeping for ONE view. Owned by the list body, which
/// rebuilds itself when a row reports its motion finished — the pane above it
/// (the toolbar, the composer, the bulk bar) never hears about a single row.
class ListChoreographer {
  // Rows kept on screen ONLY to play their completion collapse (#241).
  final Map<String, _Departing> _departing = {};

  // Ids that came BACK while (or just after) collapsing — an Undo inside the
  // 30-second toast. Their row starts folded so it expands into place.
  final Set<String> _returning = {};

  // Rows kept on screen ONLY to play their #251 leave.
  final Map<String, _Departing> _leaving = {};

  // Ids that ARRIVED in the filtered list and are still growing into place.
  final Map<String, _Arrival> _arriving = {};

  // The visible rows of the previous build, so the next one can tell which ids
  // just left the filtered list.
  List<TaskRowData> _lastVisible = const [];

  // Whether a build has already seen this view's contents. The FIRST one never
  // animates: launching the app, or switching to a view, is not eight rows
  // arriving — it is what the view is.
  bool _seenContents = false;

  // The last write the STORE confirmed for each visible row, and which element
  // of it changed (#252). Read straight off the store's own emissions, so it
  // covers every surface that can commit one.
  final Map<String, TaskCommit> _commits = {};

  // Monotonic id for the next commit. It is what makes a REPEAT legible: two
  // identical writes in a row are two commits, so the second restarts the flash
  // instead of being swallowed as "nothing changed".
  int _commitSeq = 0;

  // Ids a bulk action is currently applying to, so their commits flash the
  // WHOLE row rather than one badge (#252).
  final Set<String> _bulkChanging = {};

  /// Whether a build has already seen this view's contents — what the
  /// first-snapshot gate opens on (#260). Set by [choreograph], so it is true
  /// from the frame the first snapshot is rendered, not the one after.
  bool get seenContents => _seenContents;

  /// The commit flash owed to [id] this frame, if any.
  TaskCommit? commitFor(String id) => _commits[id];

  /// Whether [id] is a row that folded away and came straight back (an Undo
  /// inside the toast) — its collapse reverses rather than replaying.
  bool isReturning(String id) => _returning.contains(id);

  /// Start again from nothing: another view's rows are not this view's rows
  /// arriving and leaving.
  void reset() {
    _seenContents = false;
    _lastVisible = const [];
    _arriving.clear();
    _leaving.clear();
    _departing.clear();
    _returning.clear();
    _commits.clear();
    _bulkChanging.clear();
  }

  /// Declare the rows a bulk action is about to write, so their commits flash
  /// the whole row (#252). Replaces any previous op's ids — two bulk actions
  /// never overlap from the user's side, and an id nothing ever changed must
  /// not colour a later single-field edit.
  void expectBulkChanges(Iterable<String> ids) => _bulkChanging
    ..clear()
    ..addAll(ids);

  /// Publish a commit the store cannot report by itself: a REORDER, the one
  /// confirmed write that changes no field of the task (#252/#256).
  void flashRow(String id) =>
      _commits[id] = TaskCommit(CommitTarget.row, ++_commitSeq);

  /// A row finished growing in. Nothing on screen depends on the flag once the
  /// row has arrived, so this needs no rebuild.
  void entered(String id) => _arriving.remove(id);

  /// A row finished its #251 fold. Returns whether a slot was actually
  /// released — i.e. whether the list must rebuild without it.
  bool left(String id) => _leaving.remove(id) != null;

  /// A row finished its #241 collapse. Returns whether a slot was released.
  bool departed(String id) => _departing.remove(id) != null;

  /// A returning row finished expanding back into place.
  void returned(String id) => _returning.remove(id);

  /// The slots to render for [visible]: the live rows — flagged when they just
  /// ARRIVED — plus the rows that just left, re-inserted where they stood so
  /// they can fold away instead of vanishing.
  ///
  /// [now] is the current frame's timestamp, used only to expire a hold whose
  /// row was never built (it left or arrived off-screen) and therefore never
  /// reported back. Until [hasData] has been true once nothing animates at all:
  /// the first contents a view shows are not an event, they are the view.
  List<RowItem> choreograph({
    required List<TaskRowData> visible,
    required Map<String, StoredTask> byId,
    required bool hasData,
    required Duration now,
  }) {
    final ready = _seenContents;
    _seenContents = _seenContents || hasData;

    _departing.removeWhere(
      (_, r) => now - r.since > completionSequenceDuration * 2,
    );
    _leaving.removeWhere((_, r) => now - r.since > listMotionWindow * 2);
    _arriving.removeWhere((_, a) => now - a.since > listMotionWindow * 2);

    final visibleIds = {for (final r in visible) r.id};
    // A folding row whose task is back in the list rejoins the live rows: a
    // completion collapse reverses into place (#241), and a #251 leave lets go
    // of its slot so the row re-enters as an arrival below.
    for (final id in _departing.keys.toList()) {
      if (visibleIds.contains(id)) {
        _departing.remove(id);
        _returning.add(id);
      }
    }
    _leaving.removeWhere((id, _) => visibleIds.contains(id));

    // One budget for the whole change, shared by the rows leaving and the rows
    // arriving, so a delete-and-insert never doubles the cap.
    var budget = ready ? listMotionRowCap : 0;
    Duration nextSlot() =>
        MotionDurations.rowStagger * (listMotionRowCap - budget--);

    // The PREVIOUS build's rows by id — "was this row already on screen, and if
    // so, in what state". The arrival loop below asks the first half of that
    // question, [_detectCommits] the second.
    final lastById = {for (final r in _lastVisible) r.id: r};
    for (var i = 0; i < _lastVisible.length; i++) {
      final was = _lastVisible[i];
      final id = was.id;
      if (visibleIds.contains(id) ||
          _departing.containsKey(id) ||
          _leaving.containsKey(id)) {
        continue;
      }
      // The row's CURRENT state decides, not the stale snapshot: the very build
      // that drops a ticked row is the one that first sees it completed.
      final current = byId[id];
      if (current != null && current.task.status == TaskStatus.completed) {
        if (!ready) continue;
        _departing[id] = _Departing(was.withStored(current), i, now);
        continue;
      }
      if (budget <= 0) continue;
      // A deleted task is gone from the set entirely — the last snapshot the
      // list held is what folds away.
      _leaving[id] = _Departing(
        current == null ? was : was.withStored(current),
        i,
        now,
        delay: nextSlot(),
      );
    }
    for (final r in visible) {
      if (lastById.containsKey(r.id) || _arriving.containsKey(r.id)) continue;
      if (budget <= 0) break;
      _arriving[r.id] = _Arrival(nextSlot(), now);
    }
    // The #252 commit flash rides the same before/after pair: what CHANGED
    // about a row that was already on screen. A row that has just arrived is
    // not a commit — it has its own entrance above.
    if (ready) _detectCommits(visible, before: lastById);
    _commits.removeWhere((id, _) => !visibleIds.contains(id));
    _lastVisible = visible;

    final items = [
      for (final r in visible)
        RowItem(
          r,
          motion: _arriving.containsKey(r.id)
              ? SlotMotion.entering
              : SlotMotion.none,
          delay: _arriving[r.id]?.delay ?? Duration.zero,
        ),
    ];
    if (_departing.isEmpty && _leaving.isEmpty) return items;
    final folding = [
      for (final r in _departing.values)
        (index: r.index, item: RowItem(r.row, motion: SlotMotion.completing)),
      for (final r in _leaving.values)
        (
          index: r.index,
          item: RowItem(r.row, motion: SlotMotion.leaving, delay: r.delay),
        ),
    ]..sort((a, b) => a.index.compareTo(b.index));
    for (final f in folding) {
      items.insert(f.index.clamp(0, items.length), f.item);
    }
    return items;
  }

  /// Record what the store just CHANGED about each row that was already on
  /// screen — the #252 commit flash's trigger.
  ///
  /// The store's emission is the confirmation: by the time a task arrives here
  /// with a different title, date or list, the write is durable. That is why
  /// this reads the data rather than the call sites — an edit flashes the same
  /// way whether it came from this list, the detail panel, the row menu, or
  /// Google.
  void _detectCommits(
    List<TaskRowData> visible, {
    required Map<String, TaskRowData> before,
  }) {
    for (final row in visible) {
      final after = row.stored;
      final was = before[row.id]?.stored;
      if (was == null) continue;
      final changed = <CommitTarget>[
        if (was.task.title != after.task.title) CommitTarget.title,
        if (was.task.due != after.task.due) CommitTarget.due,
        if (was.listId != after.listId) CommitTarget.listTag,
      ];
      if (changed.isEmpty) continue;
      // Our own edit coming back from Google (dirty → clean): a pull can only
      // land on a row that is already clean (the store's
      // `WHERE sync_state = 'clean'`), so this is the PUSH landing — Google's
      // own formatting of the value we wrote, or an identical-content 412 the
      // engine resolved by adopting the remote. The user saw that commit when
      // it was written; the round trip is not a second one.
      if (was.syncState == SyncState.dirty &&
          after.syncState == SyncState.clean) {
        continue;
      }
      // Spent only by an emission that actually flashes, so a suppressed round
      // trip cannot swallow the mark a bulk write is still waiting to use.
      final bulk = _bulkChanging.remove(row.id);
      // The whole row when the changed element is unknown or several: a bulk
      // action (which hit N rows at once, and where WHICH rows is the thing
      // worth showing), a change the sync pulled in (the row landed clean —
      // nothing local wrote it, and a pull can rewrite any number of fields),
      // or simply more than one field at a time.
      final target =
          bulk || changed.length > 1 || after.syncState == SyncState.clean
          ? CommitTarget.row
          : changed.single;
      _commits[row.id] = TaskCommit(target, ++_commitSeq);
    }
  }
}
