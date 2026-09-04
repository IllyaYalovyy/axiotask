part of '../commands.dart';

/// A task's EXISTENCE: delete and undo, clearing a list's completed rows, and
/// the cross-list move (which is a delete plus a create, Google having no
/// native move between lists) with its undo. Reached through the [Commands]
/// facade.
class TaskLifecycleCommands extends CommandUnit {
  TaskLifecycleCommands(super.store, super.newId);

  /// Delete every fully-completed task in [listId]; returns the count cleared.
  /// Port of `commands.rs::clear_completed_inner`.
  ///
  /// Deleting a task deletes its descendants — on Google (verified live) and
  /// locally via the FK cascade. A completed parent can still shelter OPEN
  /// subtasks (completed remotely before its children, or via local edits), so
  /// deleting it would destroy unfinished work — those parents are skipped. Each
  /// cleared row follows the same tombstone-vs-hard-delete rule as [deleteTask]:
  /// only a row the server can never have seen is safe to drop without a
  /// tombstone (invariant #3). The whole clear is ONE transaction — a gesture
  /// that clears "the completed ones" must not half-clear them (#271).
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

    final now = nowUtcString();
    final tombstones = <StoredTask>[];
    final hardDeletes = <String>[];
    for (final t in tasks) {
      if (t.task.status != TaskStatus.completed) continue;
      if (hasOpenDescendant(t.task.id)) continue;
      if (await _store.serverMayHold(t.task.id)) {
        tombstones.add(_tombstone(t, now));
      } else {
        hardDeletes.add(t.task.id);
      }
    }
    if (tombstones.isEmpty && hardDeletes.isEmpty) return 0;
    await _store.writeTasks(tombstones, hardDeletes: hardDeletes);
    return tombstones.length + hardDeletes.length;
  }

  /// Delete a task and return an undo [DeleteToken] capturing its whole subtree.
  /// Port of `commands.rs::delete_task_inner`.
  ///
  /// A row the server may already hold ([Store.serverMayHold] — it has a remote
  /// id, or an in-flight create marker says its insert may have committed) is
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
  ///
  /// A pure READ: it must never announce a mutation (it used to fire the sync
  /// trigger, which put the notify BEFORE the delete it belonged to — #271).
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
      hadEtag: root.remoteId != null,
      subtree: subtree,
    );
  }

  /// Restore a deleted task (and its subtree) from an undo [DeleteToken]. Port of
  /// `commands.rs::undo_delete_inner`.
  ///
  /// If the tombstone is still present (the delete has not pushed), the row is
  /// revived IN PLACE — keeping its id, remote id and etag — so the un-pushed
  /// delete simply
  /// never fires; reviving as a fresh create would leave the original remote
  /// task un-deleted AND make a duplicate. A row already synced comes back a
  /// dirty `update` (not clean): the tombstone may sit on an edit that never
  /// pushed, and reviving clean would silently drop that edit from the queue.
  ///
  /// If the tombstone is gone (the delete already pushed, cascading the row
  /// away) it is recreated as a fresh dirty `create`; a parent that was deleted
  /// separately falls back to top level instead of failing the FK.
  ///
  /// Root and subtree go back in ONE transaction, parents before children: a
  /// half-applied undo would revive the root and leave its subtasks tombstoned —
  /// silent data loss dressed as a successful undo (#271).
  Future<void> undoDelete(DeleteToken token) async {
    final now = nowUtcString();
    final rows = <StoredTask>[];

    final existing = await _store.findTaskAny(token.id);
    if (existing != null) {
      rows.add(
        _markDirty(
          existing,
          existing.task.copyWith(status: token.status, completed: null),
          now,
        ),
      );
    } else {
      // Tombstone gone → recreate. Fall back to top level if the parent is dead.
      final parent =
          (token.parentId != null &&
              await _store.findTaskAny(token.parentId!) != null)
          ? token.parentId
          : null;
      rows.add(
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
    }
    rows.addAll(await _restoredSubtree(token, now));
    await _store.writeTasks(rows);
  }

  /// The captured descendants as rows to restore (parents before children, so
  /// each row's named parent is written first). A descendant still present is a
  /// local-only tombstone the parent's delete has not pushed — revived in place,
  /// mirroring the root; one whose row is gone was cascaded away and is
  /// recreated as a fresh dirty `create`. Port of
  /// `commands.rs::restore_subtree`.
  Future<List<StoredTask>> _restoredSubtree(
    DeleteToken token,
    String now,
  ) async {
    final rows = <StoredTask>[];
    for (final e in token.subtree) {
      final existing = await _store.findTaskAny(e.id);
      if (existing != null) {
        rows.add(
          _markDirty(
            existing,
            existing.task.copyWith(status: e.status, completed: null),
            now,
          ),
        );
        continue;
      }
      rows.add(
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
    return rows;
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
            // Brand-new remote row (invariant #4): no etag, and `remote_id`
            // stays null — the clone is an unpushed create.
            etag: null,
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
  ///
  /// Both halves are ONE transaction. As two writes, a kill in between removes
  /// the clone and never restores the original, so the task is in NEITHER list —
  /// the undo button losing the very task it was pressed to save (#271).
  Future<void> undoMoveToList(MoveToListToken token) =>
      _store.transaction(() async {
        final clone = await _store.findTaskAny(token.newRootId);
        if (clone != null && clone.syncState != SyncState.deleted) {
          await deleteTask(token.newRootId);
        }
        await undoDelete(token.original);
      });

  /// Decide how one original row is removed after its subtree was recreated in
  /// another list, appending to [tombstones] or [hardDeletes] for the caller's
  /// single move transaction. A row the server MAY hold ([Store.serverMayHold]:
  /// it has a remote id, or an in-flight-create marker says its insert may have
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
      tombstones.add(_tombstone(row, now));
    } else {
      hardDeletes.add(row.task.id);
    }
  }

  /// [row] as a pushable tombstone: still the same content, but `deleted` with a
  /// pending `delete` so the next sync removes it from Google.
  StoredTask _tombstone(StoredTask row, String now) => StoredTask(
    task: row.task,
    listId: row.listId,
    syncState: SyncState.deleted,
    localUpdated: now,
    pendingOp: 'delete',
    remoteId: row.remoteId,
  );
}
