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

import '../model/dates.dart' show normalizeDue, nowUtcString;
import '../model/task.dart';
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

/// The mutation surface the UI drives. Cheap to hold; wraps the [Store].
class Commands {
  /// Build over an open [store]; [newId] is injectable so tests pin the local
  /// ids a create assigns.
  Commands(this._store, {String Function()? newId})
    : _newId = newId ?? newLocalId;

  final Store _store;
  final String Function() _newId;

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
  Future<void> toggleComplete(String id) async {
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
    if (!completing) return;

    // Cascade to open descendants. One level of nesting is the invariant, but
    // walk a frontier anyway so the rule holds even if bad data nests deeper.
    final siblings = await _store.listTasks(t.listId);
    final frontier = <String>[id];
    while (frontier.isNotEmpty) {
      final pid = frontier.removeLast();
      for (final child in siblings.where((c) => c.task.parent == pid)) {
        frontier.add(child.task.id);
        if (child.task.status == TaskStatus.completed) continue;
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

    // Snapshot the descendants (BFS → parents before children) so undo can
    // rebuild them after the delete's server-side cascade destroys them.
    final list = await _store.listTasks(t.listId);
    final subtree = <SubtreeEntry>[];
    final frontier = <String>[id];
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

    final token = DeleteToken(
      id: t.task.id,
      listId: t.listId,
      parentId: t.task.parent,
      title: t.task.title,
      notes: t.task.notes,
      status: t.task.status,
      due: t.task.due,
      position: t.task.position,
      hadEtag: t.task.etag != null,
      subtree: subtree,
    );

    if (await _store.serverMayHold(id)) {
      final descendantIds = [for (final e in subtree) e.id];
      await _store.tombstoneSubtree(id, descendantIds, nowUtcString());
    } else {
      await _store.deleteTaskHard(id);
    }
    return token;
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
