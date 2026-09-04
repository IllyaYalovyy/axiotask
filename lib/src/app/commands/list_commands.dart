part of '../commands.dart';

/// Task-list CRUD (RFC-009 §I) plus the whole-cache reset a fresh sync needs.
/// Reached through the [Commands] facade.
class ListCommands extends CommandUnit {
  ListCommands(super.store, super.newId);

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
        remoteId: l.remoteId,
      ),
    );
  }

  /// Delete list [id]; returns whether anything was deleted (a missing list is
  /// a no-op). A list the server has seen (has a remote id) is TOMBSTONED so
  /// the deletion reaches Google — which cascades to its tasks server-side —
  /// and its local task rows go with it. A never-synced list is hard-deleted
  /// outright. Both cases are ONE transaction ([Store.deleteListWithTasks]):
  /// dropping the tasks first and the list second left, on a kill in between,
  /// every never-pushed task destroyed under a list still sitting in the
  /// sidebar (#271). Port of `state.rs::delete_list`.
  Future<bool> deleteList(String id) async {
    final lists = await _store.allLists();
    final match = lists.where((l) => l.list.id == id);
    if (match.isEmpty) return false; // already gone
    final l = match.first;
    await _store.deleteListWithTasks(
      l,
      tombstone: l.remoteId != null,
      now: nowUtcString(),
    );
    return true;
  }

  /// Drop all synced local data so the next sync rebuilds it from Google (the
  /// source of truth). Local-only lists exist nowhere else and a fresh pull
  /// cannot recreate them, so they survive. Port of the local half of
  /// `commands.rs::fresh_sync`; the re-pull it triggers is the sync engine's
  /// job, driven by the caller after this clears the cache.
  Future<void> freshSync() => _store.clearSynced();

  /// Find a list by id or raise the reference's `"list not found"` shape.
  Future<StoredTaskList> _findList(String id) async {
    final lists = await _store.allLists();
    final match = lists.where((l) => l.list.id == id);
    if (match.isEmpty) throw const CommandError('list not found');
    return match.first;
  }
}
