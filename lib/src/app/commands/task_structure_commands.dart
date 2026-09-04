part of '../commands.dart';

/// A task's PLACE in the tree: reparenting and ordering. Structural moves ride
/// their own sync axis (`pending_moves`, pushed via the Tasks move API), so
/// these commands leave a row's field-level `syncState`/`pendingOp` alone.
/// Reached through the [Commands] facade.
class TaskStructureCommands extends CommandUnit {
  TaskStructureCommands(super.store, super.newId);

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
        remoteId: t.remoteId,
      ),
    );
    await _store.recordMove(id, t.listId, parentId, previousId);
  }

  /// Move [id] so it immediately FOLLOWS [previousId] among its siblings (same
  /// parent + list, in position order), or to the FRONT when [previousId] is
  /// null — in a SINGLE transaction: reassign the affected rows' `position`
  /// strings so the new order renders at once, then record ONE `pending_moves`
  /// row naming the sibling the task now follows. Collapses what used to be N
  /// awaited single-step swaps (F20 #199) into one command and one queued move.
  /// Returns whether anything actually moved.
  ///
  /// The anchor is resolved against the store's OWN position ordering — the same
  /// order the list view derived its rows from — so a drop stays unambiguous
  /// even when HIDDEN completed rows interleave the visible ones, or a view
  /// (Focus) lifts an overdue bucket to the front. The UI passes the id of the
  /// visible neighbour the row was dropped after (never a slot index measured in
  /// a different ordering), which is exactly the sibling the move must land
  /// behind — locally and on the wire (Google's move API also targets a
  /// `previous` sibling). This closes the G1 (#202) index-space corruption where
  /// a display-order slot applied to the position-order list silently rewrote
  /// "My order" while the drag rendered as a no-op.
  ///
  /// A drop that leaves the row following the sibling it already follows is a
  /// no-op — no write, nothing queued. An anchor that is not a sibling (or the
  /// row itself) resolves to no move. The moved row lands right after the anchor
  /// and every row it passes shifts one slot to fill the gap: the SET of
  /// `position` strings is preserved and reassigned by slot, identical in net
  /// effect to N adjacent swaps. Field-level sync state is preserved (order
  /// pushes via the move axis, not a patch). Evolution of
  /// `commands.rs::reorder_task_inner`.
  Future<bool> reorderTaskAfter(String id, String? previousId) async {
    if (previousId == id) return false; // a row cannot follow itself
    final t = await _findTask(id);
    final all = await _store.listTasks(t.listId);
    final siblings = all.where((s) => s.task.parent == t.task.parent).toList();
    final from = siblings.indexWhere((s) => s.task.id == id);
    if (from < 0) return false;

    // Already following the anchor → nothing to do.
    final currentPrevious = from == 0 ? null : siblings[from - 1].task.id;
    if (previousId == currentPrevious) return false;

    // Rebuild the order with the row lifted out, then reinsert it right after
    // the anchor (or at the front). An anchor absent from the siblings is not a
    // slot we can resolve, so leave the order untouched.
    final reordered = [...siblings]..removeAt(from);
    final int insertAt;
    if (previousId == null) {
      insertAt = 0;
    } else {
      final anchor = reordered.indexWhere((s) => s.task.id == previousId);
      if (anchor < 0) return false;
      insertAt = anchor + 1;
    }
    reordered.insert(insertAt, siblings[from]);

    // Reassign the position strings by slot: same set, new order.
    final positions = [for (final s in siblings) s.task.position];
    final now = nowUtcString();
    final repositioned = <StoredTask>[];
    for (var i = 0; i < reordered.length; i++) {
      final row = reordered[i];
      final desired = positions[i];
      if (row.task.position == desired) continue; // slot unaffected by the move
      repositioned.add(
        StoredTask(
          task: row.task.copyWith(position: desired),
          listId: row.listId,
          syncState: row.syncState,
          localUpdated: now,
          pendingOp: row.pendingOp,
          remoteId: row.remoteId,
        ),
      );
    }

    // An unchanged order (the row already follows this anchor) is the doc'd
    // no-op: no position write, no queued wire move, no sync trigger. A real
    // move always repositions at least the moved row itself.
    if (repositioned.isEmpty) return false;

    // The sibling the moved task now follows in the NEW order (== previousId,
    // recomputed here so the front/removal cases share one path).
    final newPrevious = insertAt == 0 ? null : reordered[insertAt - 1].task.id;
    await _store.reorderSiblings(
      repositioned,
      taskId: id,
      listId: t.listId,
      parentId: t.task.parent,
      previousId: newPrevious,
    );
    return true;
  }
}
