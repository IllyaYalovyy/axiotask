part of '../commands.dart';

/// Field-level edits to a task: create, retitle, notes, completion and dates —
/// everything that writes a row's CONTENT (as opposed to its place in the tree,
/// which is [TaskStructureCommands], or its existence, which is
/// [TaskLifecycleCommands]). Reached through the [Commands] facade.
class TaskEditCommands extends CommandUnit {
  TaskEditCommands(super.store, super.newId);

  /// Create a task in [listId] (optionally under [parentId]) with [title].
  /// Written as a never-synced dirty `create` (no etag), so the next sync
  /// inserts it. Returns the stored row so the caller can pin/follow it.
  ///
  /// [due] carries the quick-add date (the natural-language preview, or a smart
  /// view's auto-date) as a bare `YYYY-MM-DD` or full timestamp; it is
  /// canonicalized to Google's form and an unparseable value is dropped. A new
  /// top-level task has no subtasks and no parent, so setting the date here is
  /// equivalent to the #164-cascade-aware `set_due`.
  ///
  /// The one-level invariant (#1, RFC-009 §F) is enforced HERE too: creating
  /// under a task that is ITSELF a subtask would make a third level, so it is
  /// refused before any write (F13/#191) — the same gate [TaskStructureCommands.moveTask]
  /// applies, so no create-vs-move door can slip a nest no list view can render
  /// into the store.
  Future<StoredTask> createTask({
    required String listId,
    String? parentId,
    required String title,
    String? due,
  }) async {
    if (parentId != null) {
      final siblings = await _store.listTasks(listId);
      if (siblings.any((s) => s.task.id == parentId && s.task.parent != null)) {
        throw const CommandError(
          'cannot nest under a subtask: subtasks are one level deep',
        );
      }
    }
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
    await _store.upsertTask(
      _markDirty(t, t.task.copyWith(title: title), nowUtcString()),
    );
  }

  /// Overwrite a task's notes and mark it dirty (`''` clears the field, matching
  /// Google's wire contract). Port of `commands.rs::set_notes` — the detail
  /// panel's notes auto-save routes here. [dirtyOp] preserves a `create` for a
  /// still-unsynced row.
  Future<void> setNotes(String id, String notes) async {
    final t = await _findTask(id);
    await _store.upsertTask(
      _markDirty(
        t,
        t.task.copyWith(notes: notes.isEmpty ? null : notes),
        nowUtcString(),
      ),
    );
  }

  /// Flip a task's completion. Completing a PARENT cascades completion to its
  /// open descendants — Google does this server-side (verified live, #106), so
  /// we mirror it locally and push the same, keeping subtask progress and date
  /// propagation truthful now instead of after the next pull. Un-completing
  /// never cascades (the server leaves children completed in that direction).
  ///
  /// The row and its whole cascade land in ONE transaction: a half-applied
  /// cascade would leave the parent done above an open subtask (#271).
  Future<CompleteToken> toggleComplete(String id) async {
    final t = await _findTask(id);
    final completing = t.task.status == TaskStatus.needsAction;
    final now = nowUtcString();
    final newStatus = completing
        ? TaskStatus.completed
        : TaskStatus.needsAction;
    final rows = <StoredTask>[
      _markDirty(
        t,
        t.task.copyWith(status: newStatus, completed: completing ? now : null),
        now,
      ),
    ];
    if (!completing) {
      await _store.writeTasks(rows);
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
        rows.add(
          _markDirty(
            child,
            child.task.copyWith(status: TaskStatus.completed, completed: now),
            now,
          ),
        );
      }
    }
    await _store.writeTasks(rows);
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
  /// has since vanished is skipped — best-effort, matching
  /// [TaskLifecycleCommands.undoDelete] — and the rows that remain are restored
  /// as one transaction, so an undo is never half-applied (#271).
  Future<void> undoToggleComplete(CompleteToken token) async {
    final now = nowUtcString();
    final ids = token.wasCompleting
        ? <String>[token.id, ...token.cascadedReopenIds]
        : <String>[token.id];
    final rows = <StoredTask>[];
    for (final id in ids) {
      final t = await _store.findTaskAny(id);
      if (t == null || t.syncState == SyncState.deleted) continue;
      rows.add(
        _markDirty(
          t,
          token.wasCompleting
              ? t.task.copyWith(status: TaskStatus.needsAction, completed: null)
              : t.task.copyWith(status: TaskStatus.completed, completed: now),
          now,
        ),
      );
    }
    await _store.writeTasks(rows);
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
  /// Alongside the edited row's date it enforces the #164 invariant (a
  /// subtask's explicit date is never before its parent's explicit date) with
  /// the editor's intent winning — the edit and its cascade in ONE transaction,
  /// so the store can never hold the half that violates the invariant (#271).
  /// [resolveDue] runs AFTER the not-found check so a missing task fails before
  /// any parse, and it may throw [CommandError] (garbage raw date) before any
  /// write, leaving the row untouched. Port of `commands.rs::set_due_inner`.
  Future<SetDueResult> _setDue(String id, String? Function() resolveDue) async {
    final t = await _findTask(id);
    final newDue = resolveDue();
    final now = nowUtcString();

    // The undo unit opens with the edited row's prior date, then grows by one
    // entry per row the cascade moves.
    final undo = <DueUndoEntry>[DueUndoEntry(id: id, due: t.task.due)];
    final rows = <StoredTask>[_dueRow(t, newDue, now)];

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
            rows.add(_dueRow(parent, newDue, now));
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
            rows.add(_dueRow(child, newDue, now));
          }
        }
      }
    }

    await _store.writeTasks(rows);
    return SetDueResult(
      undo: undo,
      cascaded: undo.length - 1,
      cascadedParent: cascadedParent,
    );
  }

  /// Revert a [setDue] edit and its cascade as one unit by restoring each row's
  /// captured prior date — literally one transaction (#271), so a fault cannot
  /// leave half the dates reverted. Restoration deliberately bypasses the
  /// consistency primitive: the pre-edit state was already consistent, so
  /// replaying the rule would be redundant (and, mid-typing, could re-cascade).
  /// A row that has since vanished is skipped — best-effort, matching
  /// [TaskLifecycleCommands.undoDelete]. Port of
  /// `commands.rs::undo_set_due_inner`.
  Future<void> undoSetDue(List<DueUndoEntry> entries) async {
    final now = nowUtcString();
    final rows = <StoredTask>[];
    for (final e in entries) {
      final t = await _store.findTaskAny(e.id);
      if (t == null || t.syncState == SyncState.deleted) continue;
      rows.add(_dueRow(t, e.due, now));
    }
    await _store.writeTasks(rows);
  }

  /// A row carrying a new due date as a local edit. Marks it dirty via
  /// [_markDirty] (a never-pushed row stays a `create`); the etag is carried
  /// unchanged and `base_due` is managed by [Store.upsertTask] — a clean→dirty
  /// write snapshots the old date, a repeat dirty write preserves the existing
  /// base (invariant #10). Port of `commands.rs::write_due`.
  StoredTask _dueRow(StoredTask t, String? newDue, String now) =>
      _markDirty(t, t.task.copyWith(due: newDue), now);

  /// Whether calendar date [a] falls strictly before date [b]. Both are the
  /// Google canonical `YYYY-MM-DDT00:00:00.000Z`, so the date is the leading ten
  /// characters and a lexical compare of those equals a chronological one; equal
  /// dates are deliberately NOT "before" (the invariant allows child == parent).
  /// Port of `commands.rs::due_date_before`.
  static bool _dueDateBefore(String a, String b) {
    String head(String s) => s.length >= 10 ? s.substring(0, 10) : s;
    return head(a).compareTo(head(b)) < 0;
  }
}
