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
