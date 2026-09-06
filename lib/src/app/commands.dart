// The app-layer command service — the Dart home of `commands.rs`. With no IPC
// boundary the 29 Tauri commands become plain methods on this service (RFC-011
// §1); the `*_inner` twins disappear because the method IS the logic. Widgets
// call these methods; tests drive the same methods against a real [Store] and
// an in-memory database, asserting the STATE the store persists.
//
// [Commands] is a FACADE (#271). The work lives in four units, split by what a
// command does to a task — its content ([TaskEditCommands]), its existence
// ([TaskLifecycleCommands]), its place in the tree ([TaskStructureCommands]) —
// plus the lists themselves ([ListCommands]). They are parts of this one
// library, so `_markDirty` and `_findTask` are shared without becoming public
// API, and every caller keeps importing exactly this file.
//
// The facade owns TWO things the units deliberately do not:
//   * the mutation trigger — fired here, once per public mutation, and only
//     AFTER the unit's write has landed (#209/#271);
//   * the public surface — the UI and the test doubles see one class.
//
// A multi-row command writes through [Store.writeTasks] /
// [Store.deleteListWithTasks], so it lands whole or not at all: the process can
// be killed at any await on Android, and half a cascade, a half-restored
// subtree or a list whose tasks are gone are all corruption the user cannot see
// or repair.
//
// Time comes from `package:clock` (never DateTime.now — the gate bans it) and
// local ids from an injectable generator so a test can pin them.

import 'package:clock/clock.dart';

import '../model/attention.dart' show strippedCopyTitle;
import '../model/dates.dart'
    show DateMove, applyDateMove, normalizeDue, nowUtcString;
import '../model/task.dart';
import '../model/task_list.dart';
import '../store/store.dart';
import '../store/stored.dart';
import 'ids.dart' show newLocalId;

part 'commands/command_tokens.dart';
part 'commands/command_unit.dart';
part 'commands/list_commands.dart';
part 'commands/sync_repair_commands.dart';
part 'commands/task_edit_commands.dart';
part 'commands/task_lifecycle_commands.dart';
part 'commands/task_structure_commands.dart';

/// The mutation surface the UI drives. Cheap to hold; wraps the [Store].
class Commands {
  /// Build over an open [store]; [newId] is injectable so tests pin the local
  /// ids a create assigns. Callers pass `onMutation:` — the underscore is
  /// stripped from the initializing formal's external name.
  Commands(Store store, {String Function()? newId, this._onMutation})
    : _edit = TaskEditCommands(store, newId ?? newLocalId),
      _lifecycle = TaskLifecycleCommands(store, newId ?? newLocalId),
      _structure = TaskStructureCommands(store, newId ?? newLocalId),
      _lists = ListCommands(store, newId ?? newLocalId) {
    _repair = SyncRepairCommands(store, newId ?? newLocalId, _lifecycle);
  }

  final TaskEditCommands _edit;
  final TaskLifecycleCommands _lifecycle;
  final TaskStructureCommands _structure;
  final ListCommands _lists;

  /// The sync-repair unit (#296). Built in the constructor body because it
  /// borrows [_lifecycle] — a repair that removes a row must delete it the one
  /// correct way, not a second copy of the rule.
  late final SyncRepairCommands _repair;

  /// Fired after every successful state-changing command (#209). The
  /// composition root points this at the sync scheduler's trigger, so a local
  /// change starts the debounced sync instead of waiting out the periodic
  /// cycle — the Dart seat of the reference's per-command `schedule_sync()`.
  /// Fires are coalesced downstream; no-op commands stay silent.
  final void Function()? _onMutation;

  /// Announce a completed mutation. Called ONLY from this facade, ONLY after
  /// the unit's write returned: raised from inside a command (as the delete's
  /// subtree snapshot used to) it can wake a sync that drains the store before
  /// the write is in it, and a composed command notifies once per inner write
  /// instead of once per user action (#271).
  void _notifyMutation() => _onMutation?.call();

  // ── task content ──────────────────────────────────────────────────────────

  /// Create a task — see [TaskEditCommands.createTask].
  Future<StoredTask> createTask({
    required String listId,
    String? parentId,
    required String title,
    String? due,
  }) async {
    final created = await _edit.createTask(
      listId: listId,
      parentId: parentId,
      title: title,
      due: due,
    );
    _notifyMutation();
    return created;
  }

  /// Retitle a task — see [TaskEditCommands.renameTask].
  Future<void> renameTask(String id, String title) async {
    await _edit.renameTask(id, title);
    _notifyMutation();
  }

  /// Overwrite a task's notes — see [TaskEditCommands.setNotes].
  Future<void> setNotes(String id, String notes) async {
    await _edit.setNotes(id, notes);
    _notifyMutation();
  }

  /// Flip a task's completion — see [TaskEditCommands.toggleComplete].
  Future<CompleteToken> toggleComplete(String id) async {
    final token = await _edit.toggleComplete(id);
    _notifyMutation();
    return token;
  }

  /// Revert a completion toggle — see [TaskEditCommands.undoToggleComplete].
  Future<void> undoToggleComplete(CompleteToken token) async {
    await _edit.undoToggleComplete(token);
    _notifyMutation();
  }

  /// Set a due date by quick move — see [TaskEditCommands.setDue].
  Future<SetDueResult> setDue(String id, DateMove move) async {
    final result = await _edit.setDue(id, move);
    _notifyMutation();
    return result;
  }

  /// Set a due date from a raw string — see [TaskEditCommands.setDueRaw].
  Future<SetDueResult> setDueRaw(String id, String rawDate) async {
    final result = await _edit.setDueRaw(id, rawDate);
    _notifyMutation();
    return result;
  }

  /// Revert a date edit and its cascade — see [TaskEditCommands.undoSetDue].
  Future<void> undoSetDue(List<DueUndoEntry> entries) async {
    await _edit.undoSetDue(entries);
    _notifyMutation();
  }

  // ── task existence ────────────────────────────────────────────────────────

  /// Delete every fully-completed task in a list, returning the count cleared —
  /// see [TaskLifecycleCommands.clearCompleted]. Clearing nothing is a no-op and
  /// stays silent.
  Future<int> clearCompleted(String listId) async {
    final cleared = await _lifecycle.clearCompleted(listId);
    if (cleared > 0) _notifyMutation();
    return cleared;
  }

  // ── sync repairs (the "Needs attention" view, #296) ───────────────────────

  /// Throw away a row's unpushed change and adopt the server's copy — see
  /// [SyncRepairCommands.discardLocalChange].
  Future<DiscardToken> discardLocalChange(String id) async {
    final token = await _repair.discardLocalChange(id);
    _notifyMutation();
    return token;
  }

  /// Put a discarded local change back — see
  /// [SyncRepairCommands.undoDiscardLocalChange].
  Future<void> undoDiscardLocalChange(DiscardToken token) async {
    await _repair.undoDiscardLocalChange(token);
    _notifyMutation();
  }

  /// Resolve a conflicted pair — see [SyncRepairCommands.resolveConflict].
  Future<ConflictToken> resolveConflict({
    required String originalId,
    required String copyId,
    required ConflictChoice choice,
  }) async {
    final token = await _repair.resolveConflict(
      originalId: originalId,
      copyId: copyId,
      choice: choice,
    );
    _notifyMutation();
    return token;
  }

  /// Revert a conflict resolution — see
  /// [SyncRepairCommands.undoResolveConflict].
  Future<void> undoResolveConflict(ConflictToken token) async {
    await _repair.undoResolveConflict(token);
    _notifyMutation();
  }

  /// Delete a task — see [TaskLifecycleCommands.deleteTask].
  Future<DeleteToken> deleteTask(String id) async {
    final token = await _lifecycle.deleteTask(id);
    _notifyMutation();
    return token;
  }

  /// Restore a deleted task — see [TaskLifecycleCommands.undoDelete].
  Future<void> undoDelete(DeleteToken token) async {
    await _lifecycle.undoDelete(token);
    _notifyMutation();
  }

  /// Move a subtree to another list — see
  /// [TaskLifecycleCommands.moveTaskToList]. A task already in the target list
  /// moves nothing and stays silent.
  Future<MoveToListToken?> moveTaskToList(
    String id,
    String targetListId,
  ) async {
    final token = await _lifecycle.moveTaskToList(id, targetListId);
    if (token != null) _notifyMutation();
    return token;
  }

  /// Revert a cross-list move — see [TaskLifecycleCommands.undoMoveToList].
  /// One user action, so ONE trigger, however many inner writes it replays.
  Future<void> undoMoveToList(MoveToListToken token) async {
    await _lifecycle.undoMoveToList(token);
    _notifyMutation();
  }

  // ── task structure ────────────────────────────────────────────────────────

  /// Reparent and/or reposition a task — see [TaskStructureCommands.moveTask].
  Future<void> moveTask(
    String id, {
    String? parentId,
    String? previousId,
  }) async {
    await _structure.moveTask(id, parentId: parentId, previousId: previousId);
    _notifyMutation();
  }

  /// Reorder a task after one of its siblings — see
  /// [TaskStructureCommands.reorderTaskAfter]. A drop onto the slot the row
  /// already occupies writes nothing and stays silent.
  Future<void> reorderTaskAfter(String id, String? previousId) async {
    if (await _structure.reorderTaskAfter(id, previousId)) _notifyMutation();
  }

  // ── lists ─────────────────────────────────────────────────────────────────

  /// Create a task list — see [ListCommands.createList].
  Future<StoredTaskList> createList(
    String title, {
    bool localOnly = false,
  }) async {
    final created = await _lists.createList(title, localOnly: localOnly);
    _notifyMutation();
    return created;
  }

  /// Rename a task list — see [ListCommands.renameList].
  Future<void> renameList(String id, String title) async {
    await _lists.renameList(id, title);
    _notifyMutation();
  }

  /// Delete a task list and its tasks — see [ListCommands.deleteList]. A list
  /// that is already gone is a no-op and stays silent.
  Future<void> deleteList(String id) async {
    if (await _lists.deleteList(id)) _notifyMutation();
  }

  /// Drop the synced local cache — see [ListCommands.freshSync].
  Future<void> freshSync() async {
    await _lists.freshSync();
    _notifyMutation();
  }
}
