// The app-layer command service — the Dart home of `commands.rs`. With no IPC
// boundary the 29 Tauri commands become plain methods on this service (RFC-011
// §1); the `*_inner` twins disappear because the method IS the logic. Widgets
// call these methods; tests drive the same methods against a real [Store] and
// an in-memory database, asserting the STATE the store persists.
//
// This is the T2.3 slice: create / rename / toggle. Delete+undo (T2.4), due
// dates (T5.1) and the structural moves (T5.2) land in later tasks; the helpers
// they share — [dirtyOp], [nextLocalPosition] — live here from the start.
//
// Time comes from `package:clock` (never DateTime.now — the gate bans it) and
// local ids from an injectable generator so a test can pin them.

import 'package:clock/clock.dart';

import '../model/dates.dart'
    show DateMove, applyDateMove, normalizeDue, nowUtcString;
import '../model/task.dart';
import '../model/task_list.dart';
import '../store/store.dart';
import '../store/stored.dart';
import 'ids.dart' show newLocalId;

/// Pending-op for a field edit. A row that was never pushed (no etag) must stay
/// a `create` — flipping it to `update` would make the push patch a
/// non-existent remote id, 404, and delete the task (data loss). Otherwise the
/// edit is an `update`. Port of `commands.rs::dirty_op`.
String dirtyOp(String? etag) => etag == null ? 'create' : 'update';

// A strictly monotonic tick, mirroring the reference's atomic `LAST_TICK`, so
// two creates in the same microsecond still get distinct, ordered positions.
int _lastPositionTick = 0;

// The largest 19-digit base value, so `_positionBase - tick` stays a positive
// int64 that pads to exactly 19 digits (matching the reference's `u64::MAX -
// tick` placeholder).
const int _positionBase = 9223372036854775807; // 2^63 - 1

/// A distinct, ordered placeholder position for a freshly created row. Port of
/// `commands.rs::next_local_position`.
///
/// A local task has no server-assigned position until it syncs (a local-only
/// list never syncs at all). Handing every new row the SAME constant made a
/// later reorder's position-swap a no-op (#80), so each row gets a distinct,
/// ordered value. The `!` prefix sorts before Google's numeric positions, so a
/// new row lands at the top of its list — matching how Google inserts new tasks
/// — and a larger tick yields a smaller value, so newer rows sort ahead of
/// older ones.
String nextLocalPosition() {
  final nowMicros = clock.now().toUtc().microsecondsSinceEpoch;
  final tick = nowMicros > _lastPositionTick
      ? nowMicros
      : _lastPositionTick + 1;
  _lastPositionTick = tick;
  return '!${(_positionBase - tick).toString().padLeft(19, '0')}';
}

/// Errors a command raises for the caller to surface. The user-facing
/// sanitization allowlist (#128/#135) is a later task (T7.8); for now a missing
/// task is the only command-level failure and carries the reference's exact
/// `"task {id} not found"` shape (the sanitizer keys on it).
class CommandError implements Exception {
  const CommandError(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// A descendant captured in a [DeleteToken], so undo can rebuild the whole
/// subtree even after the parent's delete pushed — the server cascades child
/// deletion when a parent dies (verified live, #106) and the local FK mirrors
/// it, so the row is gone by undo time and must be recreated from the snapshot.
/// Port of `commands.rs::SubtreeEntry`.
class SubtreeEntry {
  const SubtreeEntry({
    required this.id,
    this.parentId,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    required this.position,
  });

  /// The descendant's id at delete time.
  final String id;

  /// Its parent id (the deleted root, or a mid-level node).
  final String? parentId;

  /// Display title.
  final String title;

  /// Free-form notes.
  final String? notes;

  /// Completion status (Google's wire string).
  final TaskStatus status;

  /// Due date (RFC 3339), if any.
  final String? due;

  /// Lex-sortable position string.
  final String position;
}

/// The undo handle returned by [Commands.deleteTask]: everything needed to put
/// the task — and its whole subtree — back exactly as it was. Held in memory by
/// the caller (the undo toast, T7.8); there is no IPC boundary, so unlike the
/// reference's serialized struct this is a plain value. Port of
/// `commands.rs::DeleteToken`.
class DeleteToken {
  const DeleteToken({
    required this.id,
    required this.listId,
    this.parentId,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    required this.position,
    required this.hadEtag,
    this.subtree = const [],
  });

  /// The deleted task's id.
  final String id;

  /// The list it belonged to.
  final String listId;

  /// Its parent id (`null` for a top-level task).
  final String? parentId;

  /// Display title at delete time.
  final String title;

  /// Notes at delete time.
  final String? notes;

  /// Completion status at delete time.
  final TaskStatus status;

  /// Due date at delete time.
  final String? due;

  /// Lex-sortable position at delete time.
  final String position;

  /// Whether the task had ever been pushed (drives revive-vs-recreate only as a
  /// diagnostic; undo re-checks the live row instead of trusting this flag).
  final bool hadEtag;

  /// Descendants captured at delete time, parents before children.
  final List<SubtreeEntry> subtree;
}

/// The undo handle returned by [Commands.toggleComplete]. A completion that
/// cascades (a parent completing its open descendants — Google does this
/// server-side, #106) records EXACTLY the ids this call flipped: the toggled
/// row plus every descendant it completed. Undo reopens precisely that set, so a
/// descendant that was ALREADY completed before the swipe stays completed and
/// the pre-swipe state is restored to the row (F11/#184). A reopen never
/// cascades, so its token carries an empty [cascadedReopenIds] and undo simply
/// re-completes the one row.
class CompleteToken {
  const CompleteToken({
    required this.id,
    required this.wasCompleting,
    this.cascadedReopenIds = const [],
  });

  /// The toggled task's id.
  final String id;

  /// True when this call COMPLETED the task (so undo reopens); false when it
  /// reopened it (so undo re-completes).
  final bool wasCompleting;

  /// The descendant ids this completion cascaded — the exact set undo reopens
  /// alongside [id]. Empty for a reopen, or for a leaf/childless completion.
  final List<String> cascadedReopenIds;
}

/// The undo handle returned by [Commands.moveTaskToList]. A cross-list move is a
/// delete-from-old + create-in-new (Google has no native cross-list move), so
/// undo removes the freshly created clone subtree ([newRootId], in
/// [targetListId]) and restores the pre-move subtree from [original] — the same
/// snapshot a delete captures, replayed through [Commands.undoDelete] (F11/#185).
class MoveToListToken {
  const MoveToListToken({
    required this.newRootId,
    required this.targetListId,
    required this.original,
  });

  /// The clone root created in the target list; deleting it removes the whole
  /// moved subtree (Google's own DELETE cascade takes the descendants).
  final String newRootId;

  /// The list the subtree was moved INTO.
  final String targetListId;

  /// The pre-move subtree snapshot, restored in the original list on undo.
  final DeleteToken original;
}

/// One row's due date as it stood BEFORE a [Commands.setDue] edit, captured so
/// the edit and its parent/subtask cascade revert together as a single undo unit
/// (#164). Port of `commands.rs::DueUndoEntry`.
class DueUndoEntry {
  const DueUndoEntry({required this.id, this.due});

  /// The row whose date to restore.
  final String id;

  /// The value to restore; `null` means "no explicit date".
  final String? due;
}

/// Outcome of a [Commands.setDue] edit. Beyond the edit itself it reports the
/// parent/subtask consistency cascade (#164): the undo unit covering the edited
/// row and every row the cascade moved, and enough about the cascade for the UI
/// to phrase its toast. Port of `commands.rs::SetDueResult`.
class SetDueResult {
  const SetDueResult({
    required this.undo,
    required this.cascaded,
    required this.cascadedParent,
  });

  /// The edited row's prior date first, then each cascaded row's prior date.
  /// Feed straight to [Commands.undoSetDue] to revert the whole edit as one unit.
  final List<DueUndoEntry> undo;

  /// How many OTHER rows the cascade moved (0 = no cascade, no toast).
  final int cascaded;

  /// True when the cascade pulled the PARENT down (a child was set earlier);
  /// false when it pulled CHILDREN up (a parent was set later). Selects the
  /// toast wording.
  final bool cascadedParent;
}

/// The mutation surface the UI drives. Cheap to hold; wraps the [Store].
class Commands {
  /// Build over an open [store]; [newId] is injectable so tests pin the local
  /// ids a create assigns.
  Commands(this._store, {String Function()? newId})
    : _newId = newId ?? newLocalId;

  final Store _store;
  final String Function() _newId;

  /// The task the UI is holding, for the sync engine's held-create deferral.
  /// Process memory only — never persisted (see [setEditing]).
  String? _editingTaskId;

  /// Create a task in [listId] (optionally under [parentId]) with [title].
  /// Written as a never-synced dirty `create` (no etag), so the next sync
  /// inserts it. Returns the stored row so the caller can pin/follow it.
  ///
  /// [due] carries the quick-add date (the natural-language preview, or a smart
  /// view's auto-date) as a bare `YYYY-MM-DD` or full timestamp; it is
  /// canonicalized to Google's form and an unparseable value is dropped. A new
  /// top-level task has no subtasks and no parent, so setting the date here is
  /// equivalent to the #164-cascade-aware `set_due` (which lands in T5.1).
  Future<StoredTask> createTask({
    required String listId,
    String? parentId,
    required String title,
    String? due,
  }) async {
    final now = nowUtcString();
    final stored = StoredTask(
      task: Task(
        id: _newId(),
        parent: parentId,
        position: nextLocalPosition(),
        title: title,
        status: TaskStatus.needsAction,
        due: due == null ? null : normalizeDue(due),
        updated: now,
      ),
      listId: listId,
      syncState: SyncState.dirty,
      localUpdated: now,
      pendingOp: 'create',
    );
    await _store.upsertTask(stored);
    return stored;
  }

  /// Retitle a task and mark it dirty. [dirtyOp] preserves a `create` for a
  /// still-unsynced row so an offline create+edit never flips to `update`.
  Future<void> renameTask(String id, String title) async {
    final t = await _findTask(id);
    final now = nowUtcString();
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(title: title),
        listId: t.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: dirtyOp(t.task.etag),
      ),
    );
  }

  /// Flip a task's completion. Completing a PARENT cascades completion to its
  /// open descendants — Google does this server-side (verified live, #106), so
  /// we mirror it locally and push the same, keeping subtask progress and date
  /// propagation truthful now instead of after the next pull. Un-completing
  /// never cascades (the server leaves children completed in that direction).
  Future<CompleteToken> toggleComplete(String id) async {
    final t = await _findTask(id);
    final completing = t.task.status == TaskStatus.needsAction;
    final now = nowUtcString();
    final newStatus = completing
        ? TaskStatus.completed
        : TaskStatus.needsAction;
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(
          status: newStatus,
          completed: completing ? now : null,
        ),
        listId: t.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: dirtyOp(t.task.etag),
      ),
    );
    if (!completing) {
      return CompleteToken(id: id, wasCompleting: false);
    }

    // Cascade to open descendants, recording EXACTLY the ids this call flips so
    // undo can reopen that set alone (an already-completed descendant is skipped
    // and must stay completed on undo). One level of nesting is the invariant,
    // but walk a frontier anyway so the rule holds even if bad data nests deeper.
    final siblings = await _store.listTasks(t.listId);
    final cascaded = <String>[];
    final frontier = <String>[id];
    while (frontier.isNotEmpty) {
      final pid = frontier.removeLast();
      for (final child in siblings.where((c) => c.task.parent == pid)) {
        frontier.add(child.task.id);
        if (child.task.status == TaskStatus.completed) continue;
        cascaded.add(child.task.id);
        final cnow = nowUtcString();
        await _store.upsertTask(
          StoredTask(
            task: child.task.copyWith(
              status: TaskStatus.completed,
              completed: cnow,
            ),
            listId: child.listId,
            syncState: SyncState.dirty,
            localUpdated: cnow,
            pendingOp: dirtyOp(child.task.etag),
          ),
        );
      }
    }
    return CompleteToken(
      id: id,
      wasCompleting: true,
      cascadedReopenIds: cascaded,
    );
  }

  /// Revert a [toggleComplete] from its [CompleteToken]. A completion is undone
  /// by reopening EXACTLY the toggled row and the descendants that completion
  /// cascaded ([CompleteToken.cascadedReopenIds]) — restoring the pre-swipe
  /// state without disturbing descendants that were already completed. A reopen
  /// is undone by re-completing the one row (a reopen never cascaded). A row that
  /// has since vanished is skipped — best-effort, matching [undoDelete].
  Future<void> undoToggleComplete(CompleteToken token) async {
    final now = nowUtcString();
    if (token.wasCompleting) {
      for (final id in <String>[token.id, ...token.cascadedReopenIds]) {
        final t = await _store.findTaskAny(id);
        if (t == null || t.syncState == SyncState.deleted) continue;
        await _store.upsertTask(
          StoredTask(
            task: t.task.copyWith(
              status: TaskStatus.needsAction,
              completed: null,
            ),
            listId: t.listId,
            syncState: SyncState.dirty,
            localUpdated: now,
            pendingOp: dirtyOp(t.task.etag),
          ),
        );
      }
      return;
    }
    final t = await _store.findTaskAny(token.id);
    if (t == null || t.syncState == SyncState.deleted) return;
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(status: TaskStatus.completed, completed: now),
        listId: t.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: dirtyOp(t.task.etag),
      ),
    );
  }

  /// Overwrite a task's notes and mark it dirty (`''` clears the field, matching
  /// Google's wire contract). Port of `commands.rs::set_notes` — the detail
  /// panel's notes auto-save routes here. [dirtyOp] preserves a `create` for a
  /// still-unsynced row.
  Future<void> setNotes(String id, String notes) async {
    final t = await _findTask(id);
    final now = nowUtcString();
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(notes: notes.isEmpty ? null : notes),
        listId: t.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: dirtyOp(t.task.etag),
      ),
    );
  }

  /// Set a task's due date via a one-keystroke [move] (RFC-008), resolved
  /// against the current calendar day, then enforce the #164 cascade.
  /// [DateMove.clear] removes the date (and, being date-less, cascades nothing).
  ///
  /// The move resolves against the current CALENDAR day in UTC (day arithmetic
  /// is DST-free and only Y-M-D is ever read back) — the same basis quick-add
  /// uses. Funnels through the shared [_setDue] primitive so no date-entry path
  /// bypasses the invariant.
  Future<SetDueResult> setDue(String id, DateMove move) {
    return _setDue(id, () {
      final now = clock.now();
      final today = DateTime.utc(now.year, now.month, now.day);
      final moved = applyDateMove(today, move);
      if (moved == null) return null; // Clear
      final ymd =
          '${moved.year.toString().padLeft(4, '0')}'
          '-${moved.month.toString().padLeft(2, '0')}'
          '-${moved.day.toString().padLeft(2, '0')}';
      // normalizeDue on a value we just formatted is total; the `!` is safe.
      return normalizeDue(ymd)!;
    });
  }

  /// Set a task's due date from a raw date string (calendar picker / detail
  /// panel), canonicalized to Google's form, then enforce the #164 cascade.
  ///
  /// Google rejects a bare `YYYY-MM-DD` with a permanent 400, which would poison
  /// this row's push on every future sync, so an unparseable value is refused at
  /// the boundary with a [CommandError] and the row is left untouched (the
  /// not-found check runs first, before the parse). Port of the `raw:` arm of
  /// `commands.rs::set_due_inner`.
  Future<SetDueResult> setDueRaw(String id, String rawDate) {
    return _setDue(id, () {
      final normalized = normalizeDue(rawDate);
      if (normalized == null) throw CommandError('invalid due date: $rawDate');
      return normalized;
    });
  }

  /// The single command-layer primitive every date-entry path funnels through.
  /// After writing the edited row's date it enforces the #164 invariant (a
  /// subtask's explicit date is never before its parent's explicit date) with
  /// the editor's intent winning. [resolveDue] runs AFTER the not-found check so
  /// a missing task fails before any parse, and it may throw [CommandError]
  /// (garbage raw date) before any write, leaving the row untouched. Port of
  /// `commands.rs::set_due_inner`.
  Future<SetDueResult> _setDue(String id, String? Function() resolveDue) async {
    final t = await _findTask(id);
    final newDue = resolveDue();

    // The undo unit opens with the edited row's prior date, then grows by one
    // entry per row the cascade moves.
    final undo = <DueUndoEntry>[DueUndoEntry(id: id, due: t.task.due)];
    await _writeDue(t, newDue);

    var cascadedParent = false;
    // Rows without an explicit date never participate — clearing a date, or a
    // parent that has no date, makes the rule inert.
    if (newDue != null) {
      // A task is EITHER a subtask or a possible parent (subtasks are strictly
      // one level, invariant #1), so exactly one arm runs.
      final siblings = await _store.listTasks(t.listId);
      final parentId = t.task.parent;
      if (parentId != null) {
        // Editing a CHILD: if its parent sits later, pull the parent DOWN to
        // match. Other children are all >= the old parent date > newDue, so
        // lowering the parent cannot violate the rule for them.
        for (final parent in siblings.where((p) => p.task.id == parentId)) {
          final pd = parent.task.due;
          if (pd != null && _dueDateBefore(newDue, pd)) {
            undo.add(DueUndoEntry(id: parent.task.id, due: parent.task.due));
            await _writeDue(parent, newDue);
            cascadedParent = true;
          }
        }
      } else {
        // Editing a PARENT: pull UP every child that sits before it. Later
        // children and children with no explicit date never move.
        for (final child in siblings.where((c) => c.task.parent == id)) {
          final cd = child.task.due;
          if (cd != null && _dueDateBefore(cd, newDue)) {
            undo.add(DueUndoEntry(id: child.task.id, due: child.task.due));
            await _writeDue(child, newDue);
          }
        }
      }
    }

    return SetDueResult(
      undo: undo,
      cascaded: undo.length - 1,
      cascadedParent: cascadedParent,
    );
  }

  /// Revert a [setDue] edit and its cascade as one unit by restoring each row's
  /// captured prior date. Restoration deliberately bypasses the consistency
  /// primitive: the pre-edit state was already consistent, so replaying the rule
  /// would be redundant (and, mid-typing, could re-cascade). A row that has
  /// since vanished is skipped — best-effort, matching [undoDelete]. Port of
  /// `commands.rs::undo_set_due_inner`.
  Future<void> undoSetDue(List<DueUndoEntry> entries) async {
    for (final e in entries) {
      final t = await _store.findTaskAny(e.id);
      if (t == null || t.syncState == SyncState.deleted) continue;
      await _writeDue(t, e.due);
    }
  }

  /// Write a new due date onto a row as a local edit and persist it. Marks the
  /// row dirty and sets its pending op via [dirtyOp] (a never-pushed row stays a
  /// `create`); the etag is carried unchanged and `base_due` is managed by
  /// [Store.upsertTask] — a clean→dirty write snapshots the old date, a repeat
  /// dirty write preserves the existing base (invariant #10). Port of
  /// `commands.rs::write_due`.
  Future<void> _writeDue(StoredTask t, String? newDue) async {
    final now = nowUtcString();
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(due: newDue),
        listId: t.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: dirtyOp(t.task.etag),
      ),
    );
  }

  /// Delete every fully-completed task in [listId]; returns the count cleared.
  /// Port of `commands.rs::clear_completed_inner`.
  ///
  /// Deleting a task deletes its descendants — on Google (verified live) and
  /// locally via the FK cascade. A completed parent can still shelter OPEN
  /// subtasks (completed remotely before its children, or via local edits), so
  /// deleting it would destroy unfinished work — those parents are skipped. Each
  /// cleared row follows the same tombstone-vs-hard-delete rule as [deleteTask]:
  /// only a row the server can never have seen is safe to drop without a
  /// tombstone (invariant #3).
  Future<int> clearCompleted(String listId) async {
    final tasks = await _store.listTasks(listId);

    bool hasOpenDescendant(String root) {
      final frontier = <String>[root];
      while (frontier.isNotEmpty) {
        final pid = frontier.removeLast();
        for (final c in tasks.where((c) => c.task.parent == pid)) {
          if (c.task.status != TaskStatus.completed) return true;
          frontier.add(c.task.id);
        }
      }
      return false;
    }

    var count = 0;
    for (final t in tasks) {
      if (t.task.status != TaskStatus.completed) continue;
      if (hasOpenDescendant(t.task.id)) continue;
      if (await _store.serverMayHold(t.task.id)) {
        await _store.tombstoneSubtree(t.task.id, const [], nowUtcString());
      } else {
        await _store.deleteTaskHard(t.task.id);
      }
      count += 1;
    }
    return count;
  }

  /// Delete a task and return an undo [DeleteToken] capturing its whole subtree.
  /// Port of `commands.rs::delete_task_inner`.
  ///
  /// A row the server may already hold ([Store.serverMayHold] — it has an etag,
  /// or an in-flight create marker says its insert may have committed) is
  /// TOMBSTONED so the delete reaches Google; the whole subtree is tombstoned in
  /// one transaction (#138) with only the root carrying a pushable delete —
  /// Google's own DELETE cascade takes the children remotely (invariant #3). A
  /// row the server can never have seen is hard-deleted locally, its subtree
  /// taken by the FK `ON DELETE CASCADE`.
  Future<DeleteToken> deleteTask(String id) async {
    final t = await _findTask(id);
    final list = await _store.listTasks(t.listId);
    final token = _snapshotSubtree(t, list);

    if (await _store.serverMayHold(id)) {
      final descendantIds = [for (final e in token.subtree) e.id];
      await _store.tombstoneSubtree(id, descendantIds, nowUtcString());
    } else {
      await _store.deleteTaskHard(id);
    }
    return token;
  }

  /// Capture [root] and its whole subtree from [list] (BFS → parents before
  /// children) as a [DeleteToken], so undo can rebuild the subtree after a
  /// server-side cascade destroys it. Shared by [deleteTask] and [moveTaskToList]
  /// (whose undo restores the pre-move subtree the same way a delete-undo does).
  DeleteToken _snapshotSubtree(StoredTask root, List<StoredTask> list) {
    final subtree = <SubtreeEntry>[];
    final frontier = <String>[root.task.id];
    while (frontier.isNotEmpty) {
      final pid = frontier.removeLast();
      for (final c in list.where((c) => c.task.parent == pid)) {
        frontier.add(c.task.id);
        subtree.add(
          SubtreeEntry(
            id: c.task.id,
            parentId: c.task.parent,
            title: c.task.title,
            notes: c.task.notes,
            status: c.task.status,
            due: c.task.due,
            position: c.task.position,
          ),
        );
      }
    }
    return DeleteToken(
      id: root.task.id,
      listId: root.listId,
      parentId: root.task.parent,
      title: root.task.title,
      notes: root.task.notes,
      status: root.task.status,
      due: root.task.due,
      position: root.task.position,
      hadEtag: root.task.etag != null,
      subtree: subtree,
    );
  }

  /// Restore a deleted task (and its subtree) from an undo [DeleteToken]. Port of
  /// `commands.rs::undo_delete_inner`.
  ///
  /// If the tombstone is still present (the delete has not pushed), the row is
  /// revived IN PLACE — preserving its etag — so the un-pushed delete simply
  /// never fires; reviving as a fresh create would leave the original remote
  /// task un-deleted AND make a duplicate. A row already synced comes back a
  /// dirty `update` (not clean): the tombstone may sit on an edit that never
  /// pushed, and reviving clean would silently drop that edit from the queue.
  ///
  /// If the tombstone is gone (the delete already pushed, cascading the row
  /// away) it is recreated as a fresh dirty `create`; a parent that was deleted
  /// separately falls back to top level instead of failing the FK.
  Future<void> undoDelete(DeleteToken token) async {
    final now = nowUtcString();

    final existing = await _store.findTaskAny(token.id);
    if (existing != null) {
      final synced = existing.task.etag != null;
      await _store.upsertTask(
        StoredTask(
          task: existing.task.copyWith(status: token.status, completed: null),
          listId: existing.listId,
          syncState: SyncState.dirty,
          localUpdated: now,
          pendingOp: synced ? 'update' : 'create',
        ),
      );
      await _restoreSubtree(token, now);
      return;
    }

    // Tombstone gone → recreate. Fall back to top level if the parent is dead.
    final parent =
        (token.parentId != null &&
            await _store.findTaskAny(token.parentId!) != null)
        ? token.parentId
        : null;
    await _store.upsertTask(
      StoredTask(
        task: Task(
          id: token.id,
          parent: parent,
          position: token.position,
          title: token.title,
          notes: token.notes,
          status: token.status,
          due: token.due,
          updated: now,
        ),
        listId: token.listId,
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: 'create',
      ),
    );
    await _restoreSubtree(token, now);
  }

  /// Restore the captured descendants (parents before children, so each row's
  /// named parent is revived first). A descendant still present is a local-only
  /// tombstone the parent's delete has not pushed — revived in place, mirroring
  /// the root; one whose row is gone was cascaded away and is recreated as a
  /// fresh dirty `create`. Port of `commands.rs::restore_subtree`.
  Future<void> _restoreSubtree(DeleteToken token, String now) async {
    for (final e in token.subtree) {
      final existing = await _store.findTaskAny(e.id);
      if (existing != null) {
        await _store.upsertTask(
          StoredTask(
            task: existing.task.copyWith(status: e.status, completed: null),
            listId: existing.listId,
            syncState: SyncState.dirty,
            localUpdated: now,
            pendingOp: dirtyOp(existing.task.etag),
          ),
        );
        continue;
      }
      await _store.upsertTask(
        StoredTask(
          task: Task(
            id: e.id,
            parent: e.parentId,
            position: e.position,
            title: e.title,
            notes: e.notes,
            status: e.status,
            due: e.due,
            updated: now,
          ),
          listId: token.listId,
          syncState: SyncState.dirty,
          localUpdated: now,
          pendingOp: 'create',
        ),
      );
    }
  }

  // ── list CRUD (§I) ────────────────────────────────────────────────────────

  /// Create a task list titled [title] and return the stored row. A syncable
  /// list is written as a dirty `create` (no etag) so the next sync inserts it;
  /// a [localOnly] list is born clean and never pushes. Port of
  /// `state.rs::create_list`.
  Future<StoredTaskList> createList(
    String title, {
    bool localOnly = false,
  }) async {
    final now = nowUtcString();
    final stored = StoredTaskList(
      list: TaskList(id: _newId(), title: title, updated: now),
      syncState: localOnly ? SyncState.clean : SyncState.dirty,
      localUpdated: now,
      pendingOp: localOnly ? null : 'create',
      localOnly: localOnly,
    );
    await _store.upsertList(stored);
    return stored;
  }

  /// Rename list [id] to [title]. A never-synced list keeps its pending
  /// `create` (the rename folds in — flipping to `update` would patch a
  /// non-existent remote list); otherwise it becomes a dirty `update`, pushed
  /// via `patch_tasklist`. Port of `state.rs::rename_list`.
  Future<void> renameList(String id, String title) async {
    final l = await _findList(id);
    final now = nowUtcString();
    await _store.upsertList(
      StoredTaskList(
        list: TaskList(
          id: l.list.id,
          title: title,
          etag: l.list.etag,
          updated: now,
        ),
        syncState: SyncState.dirty,
        localUpdated: now,
        pendingOp: l.pendingOp == 'create' ? 'create' : 'update',
        localOnly: l.localOnly,
      ),
    );
  }

  /// Delete list [id]. A list the server has seen (has an etag) is TOMBSTONED so
  /// the deletion reaches Google — which cascades to its tasks server-side — and
  /// its local task rows are hard-deleted immediately (nothing stranded). A
  /// never-synced list is hard-deleted outright (its tasks go with the FK
  /// cascade). A missing list is a no-op. Port of `state.rs::delete_list`.
  Future<void> deleteList(String id) async {
    final lists = await _store.allLists();
    final match = lists.where((l) => l.list.id == id);
    if (match.isEmpty) return; // already gone
    final l = match.first;
    // Remove local task rows (the server cascades on its side once the list
    // delete lands).
    for (final t in await _store.listTasks(id)) {
      await _store.deleteTaskHard(t.task.id);
    }
    if (l.list.etag != null) {
      await _store.upsertList(
        StoredTaskList(
          list: l.list,
          syncState: SyncState.deleted,
          localUpdated: nowUtcString(),
          pendingOp: 'delete',
          localOnly: l.localOnly,
        ),
      );
    } else {
      await _store.deleteListHard(id);
    }
  }

  /// Find a list by id or raise the reference's `"list not found"` shape.
  Future<StoredTaskList> _findList(String id) async {
    final lists = await _store.allLists();
    final match = lists.where((l) => l.list.id == id);
    if (match.isEmpty) throw const CommandError('list not found');
    return match.first;
  }

  // ── structural moves (T5.2) ───────────────────────────────────────────────

  /// Reparent and/or reposition [id]. A structural move rides its OWN axis: it
  /// records a `pending_moves` row (pushed via the Tasks move API — Google
  /// reorders through move, not patch) and leaves the row's field-level
  /// `syncState`/`pendingOp` untouched, so a clean synced row stays clean.
  /// Port of `commands.rs::move_task_inner`.
  ///
  /// [parentId] `null` detaches to top level (always allowed). Otherwise the
  /// one-level invariant (#1, RFC-009 §F) is enforced HERE — Google accepts a
  /// deeper nest with 200 (probe 3), so this command is the last gate before
  /// the store records a tree no list view can render. [previousId] names the
  /// sibling the task should follow; the local `position` is pinned so the UI
  /// reflects the order before the push.
  Future<void> moveTask(
    String id, {
    String? parentId,
    String? previousId,
  }) async {
    final t = await _findTask(id);
    if (parentId != null) {
      final siblings = await _store.listTasks(t.listId);
      if (siblings.any((s) => s.task.id == parentId && s.task.parent != null)) {
        throw const CommandError(
          'cannot nest under a subtask: subtasks are one level deep',
        );
      }
      if (siblings.any((s) => s.task.parent == id)) {
        throw const CommandError(
          'cannot make a task with subtasks into a subtask',
        );
      }
    }
    final now = nowUtcString();
    await _store.upsertTask(
      StoredTask(
        // parent may be cleared to null, which copyWith cannot express, so the
        // moved row is rebuilt explicitly.
        task: Task(
          id: t.task.id,
          parent: parentId,
          position: previousId != null ? 'after-$previousId' : '00000000000001',
          title: t.task.title,
          notes: t.task.notes,
          status: t.task.status,
          due: t.task.due,
          completed: t.task.completed,
          etag: t.task.etag,
          updated: t.task.updated,
          webViewLink: t.task.webViewLink,
        ),
        listId: t.listId,
        syncState: t.syncState,
        localUpdated: now,
        pendingOp: t.pendingOp,
      ),
    );
    await _store.recordMove(id, t.listId, parentId, previousId);
  }

  /// Move [id] one step [direction] (`'up'` | `'down'`) among its siblings.
  /// Swaps the two rows' `position` strings so the new order renders at once,
  /// then records a `pending_moves` row naming the sibling the task now follows
  /// (Google reorders through the move API). A step at the list boundary is a
  /// no-op — no write, nothing queued. Field-level sync state is preserved (the
  /// order pushes via the move axis, not a patch). Port of
  /// `commands.rs::reorder_task_inner`.
  ///
  /// The panel measures drag distance against the FULL sibling list, so with
  /// "Hide completed" on it emits as many single-step swaps as needed to cross
  /// hidden completed rows (#90) — each call here is one such step.
  Future<void> reorderTask(String id, String direction) async {
    final t = await _findTask(id);
    final all = await _store.listTasks(t.listId);
    final siblings = all.where((s) => s.task.parent == t.task.parent).toList();
    final idx = siblings.indexWhere((s) => s.task.id == id);
    if (idx < 0) return;

    final int swapIdx;
    if (direction == 'up' && idx > 0) {
      swapIdx = idx - 1;
    } else if (direction == 'down' && idx < siblings.length - 1) {
      swapIdx = idx + 1;
    } else {
      return; // no-op at the boundary
    }

    final other = siblings[swapIdx];
    final now = nowUtcString();
    // Swap the two positions, preserving each row's field-level sync state.
    await _store.upsertTask(
      StoredTask(
        task: t.task.copyWith(position: other.task.position),
        listId: t.listId,
        syncState: t.syncState,
        localUpdated: now,
        pendingOp: t.pendingOp,
      ),
    );
    await _store.upsertTask(
      StoredTask(
        task: other.task.copyWith(position: t.task.position),
        listId: other.listId,
        syncState: other.syncState,
        localUpdated: now,
        pendingOp: other.pendingOp,
      ),
    );

    // The sibling the task now follows: moving up, that is two slots back (or
    // nothing if it reached the top); moving down, it is the row it hopped over.
    final String? newPrevious = direction == 'up'
        ? (idx >= 2 ? siblings[idx - 2].task.id : null)
        : siblings[idx + 1].task.id;
    await _store.recordMove(id, t.listId, t.task.parent, newPrevious);
  }

  /// Move [id]'s whole subtree to [targetListId] and return the new root id.
  /// Google Tasks has no native cross-list move, so this is a delete-from-old +
  /// create-in-new: each node is recreated in the target under a FRESH local id
  /// (parent before child), then each original is removed. Port of
  /// `AppState::move_task_to_list` (P8).
  ///
  /// The subtree moves together — deleting a parent deletes its children both on
  /// Google (verified live) and via the local FK cascade, so leaving subtasks
  /// behind would silently destroy them once the parent's delete pushed.
  Future<MoveToListToken?> moveTaskToList(
    String id,
    String targetListId,
  ) async {
    final old = await _findTask(id);
    // Already there → nothing moved, nothing to undo.
    if (old.listId == targetListId) return null;

    final now = nowUtcString();
    final siblings = await _store.listTasks(old.listId);

    // Snapshot the pre-move subtree BEFORE any removal, so undo can restore the
    // original rows (same machinery as a delete-undo) after this move tombstones
    // or hard-deletes them.
    final original = _snapshotSubtree(old, siblings);

    // Recreate the root, then each descendant level under its recreated
    // parent's new id. A stack visits parents before children, so `clones` is
    // already parent-before-child — the order the FK needs at insert time.
    final recreated = <(StoredTask, String)>[]; // (original node, new id)
    final clones = <StoredTask>[];
    final frontier = <(StoredTask, String?)>[(old, null)];
    while (frontier.isNotEmpty) {
      final (node, newParent) = frontier.removeLast();
      final newId = _newId();
      clones.add(
        StoredTask(
          task: Task(
            id: newId,
            parent: newParent,
            position: node.task.position,
            title: node.task.title,
            notes: node.task.notes,
            status: node.task.status,
            due: node.task.due,
            completed: node.task.completed,
            etag: null, // brand-new remote row (invariant #4)
            updated: node.task.updated,
            webViewLink: null,
          ),
          listId: targetListId,
          syncState: SyncState.dirty,
          localUpdated: now,
          pendingOp: 'create',
        ),
      );
      recreated.add((node, newId));
      for (final child in siblings.where(
        (c) => c.task.parent == node.task.id,
      )) {
        frontier.add((child, newId));
      }
    }
    final newRootId = recreated.firstWhere((e) => e.$1.task.id == id).$2;

    // Classify each original for removal: descendants first, then the root — the
    // root's delete is what cascades the descendants away on the server. The
    // clone-then-remove window is one transaction ([Store.finishCrossListMove]),
    // so a crash can never leave both an original and its clone live (#182/P8).
    final tombstones = <StoredTask>[];
    final hardDeletes = <String>[];
    for (final (node, _) in recreated.skip(1)) {
      await _classifyMovedOriginal(node, now, tombstones, hardDeletes);
    }
    await _classifyMovedOriginal(old, now, tombstones, hardDeletes);

    await _store.finishCrossListMove(
      clones: clones,
      tombstones: tombstones,
      hardDeletes: hardDeletes,
    );
    return MoveToListToken(
      newRootId: newRootId,
      targetListId: targetListId,
      original: original,
    );
  }

  /// Revert a [moveTaskToList] from its [MoveToListToken]. The freshly created
  /// clone subtree (rooted at [MoveToListToken.newRootId]) is deleted — removing
  /// it from the target list (Google's own DELETE cascade takes the descendants)
  /// — and the pre-move subtree is restored in its original list via
  /// [undoDelete], the same snapshot-replay a delete-undo uses. Best-effort: a
  /// clone already gone is skipped.
  Future<void> undoMoveToList(MoveToListToken token) async {
    final clone = await _store.findTaskAny(token.newRootId);
    if (clone != null && clone.syncState != SyncState.deleted) {
      await deleteTask(token.newRootId);
    }
    await undoDelete(token.original);
  }

  /// Decide how one original row is removed after its subtree was recreated in
  /// another list, appending to [tombstones] or [hardDeletes] for the caller's
  /// single move transaction. A row the server MAY hold ([Store.serverMayHold]:
  /// it has an etag, or an in-flight-create marker says its insert may have
  /// committed) is TOMBSTONED, not hard-deleted: the server only cascades the
  /// moved subtree away once the ROOT's delete lands, and if a pull happens first
  /// a hard-deleted row is RESURRECTED from the server, duplicating the moved
  /// subtree (P8). A tombstone pushes its own delete and the pull cannot re-add
  /// it; a redundant server cascade then 404s = success. A row the server has
  /// never seen is hard-deleted. Port of `AppState::remove_moved_original`.
  Future<void> _classifyMovedOriginal(
    StoredTask row,
    String now,
    List<StoredTask> tombstones,
    List<String> hardDeletes,
  ) async {
    if (await _store.serverMayHold(row.task.id)) {
      tombstones.add(
        StoredTask(
          task: row.task,
          listId: row.listId,
          syncState: SyncState.deleted,
          localUpdated: now,
          pendingOp: 'delete',
        ),
      );
    } else {
      hardDeletes.add(row.task.id);
    }
  }

  /// Drop all synced local data so the next sync rebuilds it from Google (the
  /// source of truth). Local-only lists exist nowhere else and a fresh pull
  /// cannot recreate them, so they survive. Port of the local half of
  /// `commands.rs::fresh_sync`; the re-pull it triggers is the sync engine's
  /// job (wired in T5.5+), driven by the caller after this clears the cache.
  Future<void> freshSync() async {
    await _store.clearSynced();
  }

  /// The task the UI is actively holding (inline editor row or open detail
  /// panel), or `null` when nothing is being edited. See [setEditing].
  String? get heldCreateId => _editingTaskId;

  /// Record which task the UI is holding. Only that one task's CREATE push is
  /// held by the sync engine (prevents its local id remapping mid-edit); every
  /// other create — including subtasks born inside the open panel (#85) — keeps
  /// syncing. Pure process memory: it never touches the store, so a relaunch
  /// starts with nothing held and the once-held create pushes on the next sync.
  /// Port of `commands.rs::set_editing` / `AppState::set_editing_task`.
  void setEditing(String? id) => _editingTaskId = id;

  /// Whether calendar date [a] falls strictly before date [b]. Both are the
  /// Google canonical `YYYY-MM-DDT00:00:00.000Z`, so the date is the leading ten
  /// characters and a lexical compare of those equals a chronological one; equal
  /// dates are deliberately NOT "before" (the invariant allows child == parent).
  /// Port of `commands.rs::due_date_before`.
  static bool _dueDateBefore(String a, String b) {
    String head(String s) => s.length >= 10 ? s.substring(0, 10) : s;
    return head(a).compareTo(head(b)) < 0;
  }

  /// Find a VISIBLE task by id (tombstones read as absent). Port of
  /// `commands.rs::find_task`; raises the reference's exact not-found shape.
  Future<StoredTask> _findTask(String id) async {
    final t = await _store.findTaskAny(id);
    if (t == null || t.syncState == SyncState.deleted) {
      throw CommandError('task $id not found');
    }
    return t;
  }
}
