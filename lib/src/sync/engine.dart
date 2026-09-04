// Sync engine: push local changes, pull remote changes, resolve conflicts —
// the Dart port of `sync/engine.rs`. Design: RFC-004; conflict matrix: RFC-009.
// Single entry point [SyncEngine.run]. All conflict resolution follows
// "remote wins" for the MVP.
//
// This module is the IO half of sync: it **observes** (store reads, API calls),
// asks [reconcile] to **decide**, and **applies** the decision to the store.
// Every branch that is a *choice* rather than a write lives in `reconcile.dart`
// as a pure function, so RFC-009's matrix rows are testable without an engine,
// a fake, or a database.
//
// Kill-safety (MIGRATION-PLAN §2): the reference guarantees atomic individual
// store mutations, durable in-flight markers, and convergent retry — NOT
// one-transaction-per-phase. `push_create` records the in-flight marker durably
// BEFORE the non-idempotent insert and `finish_create` learns the remote id +
// marks clean in ONE store transaction, so a crash either re-inserts (no orphan)
// or adopts the orphan (no duplicate). Every private pass is a resume point:
// re-running `run()` after a kill converges.
//
// IDENTITY (#224): every id inside the store — `tasks.id`, `task_lists.id`,
// `parent_id`, `pending_moves` — is a LOCAL id, minted once and immutable for
// the row's lifetime. Google's ids live only in `remote_id`. This engine is the
// ONLY translator: every outbound call resolves the wire ids it needs from
// `remote_id`, and every response (and every pulled row) is translated back
// into local-id space before it reaches the store. Nothing below the engine
// ever sees a Google id.

import '../api/api_error.dart';
import '../api/tasks_api.dart';
import '../app/ids.dart' show newLocalId;
import '../model/base_snapshot.dart';
import '../model/page.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import '../store/store.dart';
import '../store/store_error.dart';
import '../store/stored.dart';
import 'reconcile.dart' as reconcile;
import 'reconcile.dart'
    show
        ConflictResolution,
        ClearInflight,
        DeleteFailed,
        HardDeleteLocal,
        InflightBase,
        KeepInflight,
        ListDeleteAction,
        ListPullAdoptLocalCreate,
        ListPullKeepLocal,
        ListPullUpsert,
        ListRenameDeleteLocal,
        ListRenameFailed,
        MoveAdoption,
        MoveDrop,
        MoveFailure,
        MoveRefs,
        MoveRefuse,
        MoveSend,
        MoveWait,
        PullRowAction,
        PullRowContext,
        PushFailure,
        RefState,
        RefetchFailure,
        UpdateDeleteLocal,
        UpdateFailed,
        UpdateResolveConflict;
import 'sync_error.dart';

/// Counters and changed-data scope from a single sync run.
class SyncOutcome {
  /// Tasks pulled from the server (new or updated locally).
  int pulled = 0;

  /// Tasks pushed to the server.
  int pushed = 0;

  /// Conflicts resolved (412 responses / D7 repairs).
  int conflicts = 0;

  /// Tasks hard-deleted locally (confirmed by the server or ghost detection).
  int deleted = 0;

  /// Rows whose push was rejected by the server (e.g. a 400). The row stays
  /// dirty and the run continues — one poisoned row must not stop the other
  /// pushes, or the pull.
  int errors = 0;

  /// Task lists whose task rows changed locally during this run.
  final List<String> changedListIds = [];

  /// The task-list collection or list metadata changed, so callers must
  /// refresh list metadata before replacing task rows.
  bool listsChanged = false;

  /// Dedup-append a list id to [changedListIds].
  void markListChanged(String listId) {
    if (!changedListIds.contains(listId)) changedListIds.add(listId);
  }
}

/// Configuration for a sync engine instance.
class SyncConfig {
  const SyncConfig({this.pushEnabled = false, this.heldCreateId});

  /// Whether to push local changes to the server.
  final bool pushEnabled;

  /// Hold the CREATE push of exactly this one task this run: the id of the row
  /// the UI is actively holding (the inline editor's row, or the open detail
  /// panel's task).
  ///
  /// This used to exist because a landing create REWROTE the row's id, which
  /// invalidated every reference the UI held. That rewrite is gone (#224): ids
  /// are immutable, so a create landing under an open editor is now harmless.
  /// The hold is kept as a pure quiescence measure — a row under active editing
  /// does not have its half-typed first version pushed — and its removal is a
  /// product decision, not an implementation one. Every OTHER create still
  /// pushes; updates/deletes/moves always push.
  final String? heldCreateId;
}

/// The sync engine. Stateless — each [run] is independent.
class SyncEngine {
  /// Create a new sync engine with the default config (push off).
  SyncEngine(this._client, this._store, {String Function()? newId})
    : _config = const SyncConfig(),
      _newId = newId ?? newLocalId;

  /// Create with an explicit push flag.
  SyncEngine.withPush(
    this._client,
    this._store,
    bool pushEnabled, {
    String Function()? newId,
  }) : _config = SyncConfig(pushEnabled: pushEnabled),
       _newId = newId ?? newLocalId;

  SyncEngine._(this._client, this._store, this._config, this._newId);

  final TasksApi _client;
  final Store _store;
  final SyncConfig _config;

  /// Fresh id generator for conflicted copies (injectable for deterministic
  /// tests; defaults to a v4 UUID).
  final String Function() _newId;

  /// The store this engine writes to — exposed for tests that assert on the
  /// persisted state (the reference tests read `eng.store` directly).
  Store get store => _store;

  /// Return a copy holding the CREATE push of this one task id this run (see
  /// [SyncConfig.heldCreateId]). `null` holds nothing.
  SyncEngine holdCreateId(String? id) => SyncEngine._(
    _client,
    _store,
    SyncConfig(pushEnabled: _config.pushEnabled, heldCreateId: id),
    _newId,
  );

  /// Execute a full sync cycle: push then pull. Always writes to sync_log.
  Future<SyncOutcome> run() async {
    final started = Stopwatch()..start();
    final out = SyncOutcome();
    Object? error;
    try {
      await _execute(out);
    } catch (e) {
      error = e;
    }
    started.stop();
    await _store.writeSyncLog(
      pulled: out.pulled,
      pushed: out.pushed,
      conflicts: out.conflicts,
      durationMs: started.elapsedMilliseconds,
      failure: error == null ? null : _asSyncError(error).failureKind,
    );
    if (error != null) throw _asSyncError(error);
    return out;
  }

  /// Coerce any thrown error into a [SyncError] (mirrors the reference's
  /// `From<ApiError>`/`From<StoreError>` conversions on `?`).
  SyncError _asSyncError(Object e) => switch (e) {
    SyncError() => e,
    ApiError() => SyncApiError(e),
    StoreError() => SyncStoreError(e),
    _ => SyncInternalError(e.toString()),
  };

  Future<void> _execute(SyncOutcome out) async {
    if (_config.pushEnabled) {
      await _pushAll(out);
    }
    await _pullAll(out);
    // D7 flatten (invariant #1) runs over the LOCAL store after EVERY sync, not
    // just inside pull_list: a push-side 412 resolution can adopt a server
    // demote onto our canonical row and leave our subtask a third level, and
    // the same run's pull can be skipped whole by a transient list_tasklists
    // fault (#150). Only the corrective server move inside repairThirdLevel is
    // gated on push (#137).
    for (final list in await _store.allLists()) {
      final rows = await _store.listTasks(list.list.id);
      final thirdLevel = reconcile.thirdLevelIds(rows);
      await _repairThirdLevel(list, thirdLevel, out);
    }
  }

  // ─── Push ──────────────────────────────────────────────────────────────────

  /// Push all dirty rows: creates (parents first), then remaining ops.
  Future<void> _pushAll(SyncOutcome out) async {
    // Recover any creates interrupted by a crash before pushing new ones.
    await _recoverInflightCreates(out);
    // A marker recovery that could NOT resolve (its list fetch died
    // transiently, so the orphan — if any — was invisible) still means "this
    // insert may already have landed". Re-pushing it now is exactly the
    // duplicate H1 exists to prevent, so the create waits for a run with a
    // complete remote view. Every other create pushes as usual.
    final unresolvedCreates = <String>{
      for (final (localId, _) in await _store.inflightCreates()) localId,
    };

    // List CREATES first — tasks reference lists, so the list must exist (with
    // its remote id) before we push tasks into it. Held while the user is
    // editing (a list-id remap would disrupt the row the UI holds), but never
    // blocks the task creates below.
    if (_config.heldCreateId == null) {
      await _pushListCreates(out);
    }

    // Creates, in dependency order. A child insert names its parent's REMOTE id
    // in the request, so a create is pushable only once its parent has one. Each
    // finishCreate teaches the parent its remote id, so looping until no
    // progress resolves arbitrary nesting depth; the rest stays dirty.
    // Attempt each create at most once per run: a create whose response times
    // out after the server committed would otherwise be double-inserted
    // (in-flight orphan recovery only runs at the start of a run).
    final attempted = <String>{};
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (final row in await _store.drainDirty()) {
        if (!reconcile.createIsEligible(
          row.pendingOp,
          row.task.id,
          attempted,
          unresolvedCreates,
          _config.heldCreateId,
        )) {
          continue;
        }
        if (!reconcile.parentIsPushable(await _refStateOf(row.task.parent))) {
          continue;
        }
        attempted.add(row.task.id);
        await pushCreate(row, out);
        progressed = true;
      }
    }

    // Updates and deletes name the row's REMOTE id — except when the row's own
    // create is still unresolved in flight, in which case there is no server id
    // yet and the mutation waits for the run that resolves the marker.
    for (final row in await _store.drainDirty()) {
      if (!reconcile.mutationIsPushable(row.task.id, unresolvedCreates)) {
        continue;
      }
      switch (row.pendingOp) {
        case 'update':
          // No remote id and no in-flight marker: the server has never seen
          // this row, so there is nothing to patch. It stays dirty; its own
          // create pass is what makes it pushable.
          if (row.remoteId == null) continue;
          await _pushUpdate(row, out);
        case 'delete':
          await _pushDelete(row, out);
      }
    }

    // Then position/parent moves via the move API.
    await _pushMoves(out);

    // Finally, list renames and deletes (after task ops so a deleted list's
    // task tombstones are pushed first).
    await _pushListMutations(out);
  }

  /// Apply the decision [reconcile.pushFailure] made for one row's push failure.
  void _rowPushFailure(ApiError e, SyncOutcome out, String id, String op) =>
      _applyPushFailure(reconcile.pushFailure(e), e, out, id, op);

  /// Apply an already-classified push failure (used where the decision came
  /// from an op-specific reconciler that had already inspected the error).
  void _applyPushFailure(
    PushFailure failure,
    ApiError e,
    SyncOutcome out,
    String id,
    String op,
  ) {
    switch (failure) {
      case PushFailure.retry:
        // Transient — the row stays dirty and retries next run.
        break;
      case PushFailure.abort:
        throw SyncApiError(e);
      case PushFailure.reject:
        // Server rejected it; the row stays dirty and the run continues.
        out.errors += 1;
    }
  }

  /// Push locally-created lists so their tasks can reference real ids. Adopts an
  /// existing remote list with the same title instead of creating a duplicate.
  Future<void> _pushListCreates(SyncOutcome out) async {
    final creates = [
      for (final l in await _store.drainDirtyLists())
        if (l.pendingOp == 'create') l,
    ];
    if (creates.isEmpty) return;
    // Snapshot remote lists once for adoption matching.
    final List<TaskList> remote;
    try {
      remote = await _client.listTasklists();
    } on ApiError catch (e) {
      if (e.isTransient) return;
      rethrow;
    }
    final trackedRemoteIds = <String>{
      for (final l in await _store.allLists())
        if (l.remoteId != null) l.remoteId!,
    };

    for (final l in creates) {
      // Adopt a remote list with the same title we don't already track.
      final existing = reconcile.adoptableList(
        l.list.title,
        remote,
        trackedRemoteIds,
      );
      if (existing != null) {
        // Record the adoption so a SECOND same-title local create in this batch
        // doesn't claim the same remote id (which the `remote_id` uniqueness
        // constraint would refuse); it inserts a new remote list instead.
        trackedRemoteIds.add(existing.id);
        await _store.finishListCreate(
          l.list.id,
          existing.id,
          existing.etag,
          existing.updated,
        );
        out.listsChanged = true;
        continue;
      }
      try {
        final remoteList = await _client.insertTasklist(l.list.title);
        await _store.finishListCreate(
          l.list.id,
          remoteList.id,
          remoteList.etag,
          remoteList.updated,
        );
        out.pushed += 1;
        out.listsChanged = true;
      } on ApiError catch (e) {
        _rowPushFailure(e, out, l.list.id, 'list create');
      }
    }
  }

  /// Push list renames (update) and deletions.
  Future<void> _pushListMutations(SyncOutcome out) async {
    for (final l in await _store.drainDirtyLists()) {
      // Both branches name Google's id for the list. A dirty list without one
      // has never been acknowledged: its rename folds into its still-pending
      // create (see `Commands.renameList`), and its delete is purely local.
      final listRemoteId = l.remoteId;
      switch (l.pendingOp) {
        case 'update':
          if (listRemoteId == null) continue;
          try {
            final remote = await _client.patchTasklist(
              listRemoteId,
              l.list.title,
            );
            await _store.markListClean(l.list.id, remote.etag, remote.updated);
            out.pushed += 1;
            out.listsChanged = true;
          } on ApiError catch (e) {
            switch (reconcile.onListRenameError(e)) {
              case ListRenameDeleteLocal():
                // The list is gone on the server, so it goes here too (P4) — but
                // the rows it holds that the server has NEVER SEEN must not die
                // with it (P2/D2). Re-home them the same way the pull does.
                final survivors = [
                  for (final s in await _store.allLists())
                    if (s.list.id != l.list.id) s,
                ];
                if (await _rehomeBeforeDropping(l.list.id, survivors, out)) {
                  await _store.deleteListHard(l.list.id);
                } else {
                  // Nowhere to put them: keep the list as an unpushed create so
                  // it is re-created on the server and the rows land in it.
                  await _store.upsertList(
                    StoredTaskList(
                      list: _listAsCreate(l.list),
                      syncState: SyncState.dirty,
                      localUpdated: l.localUpdated,
                      pendingOp: 'create',
                      localOnly: l.localOnly,
                    ),
                  );
                }
                out.listsChanged = true;
              case ListRenameFailed(:final failure):
                _applyPushFailure(failure, e, out, l.list.id, 'list rename');
            }
          }
        case 'delete':
          if (listRemoteId == null) {
            // Never pushed — nothing on Google to delete.
            await _store.deleteListHard(l.list.id);
            out.deleted += 1;
            out.listsChanged = true;
            continue;
          }
          ApiError? error;
          try {
            await _client.deleteTasklist(listRemoteId);
          } on ApiError catch (e) {
            error = e;
          }
          switch (reconcile.planListDelete(error)) {
            case ListDeleteAction.deleteLocal:
              await _store.deleteListHard(l.list.id);
              out.deleted += 1;
              out.listsChanged = true;
            case ListDeleteAction.retry:
              break; // transient — keep the tombstone, retry next run
            case ListDeleteAction.abort:
              throw SyncApiError(error!);
            case ListDeleteAction.revive:
              // Permanently refused — Google will not delete an account's
              // default list, for example. Revive the list (its tasks re-pull)
              // and tell the user via the error count.
              out.errors += 1;
              await _store.upsertList(
                StoredTaskList(
                  list: l.list,
                  syncState: SyncState.clean,
                  localUpdated: l.localUpdated,
                  localOnly: l.localOnly,
                ),
              );
              out.listsChanged = true;
          }
      }
    }
  }

  /// Recover creates interrupted by a crash between the server insert and the
  /// local commit. For each in-flight marker, look for an orphaned remote task
  /// (our content, an id we never recorded) and adopt it instead of
  /// re-inserting — eliminating the duplicate. Scoped strictly to in-flight
  /// creates, so it never merges unrelated tasks.
  Future<void> _recoverInflightCreates(SyncOutcome out) async {
    for (final (localId, listId) in await _store.inflightCreates()) {
      // The create this marker belongs to is held, so its recovery is too:
      // resolving the marker here would push the row past the hold.
      if (_config.heldCreateId == localId) continue;
      // findTaskAny on purpose: a row the user deleted (or moved to another
      // list) while its insert was in flight is a TOMBSTONE, and that tombstone
      // is the only thing that still knows what the committed insert looks like.
      final local = await _store.findTaskAny(localId);
      if (local == null) {
        // Local row really is gone (hard-deleted) — nothing to adopt.
        await _store.clearInflightCreate(localId);
        continue;
      }

      final listRemoteId = await _store.listRemoteId(listId);
      // The list itself has not landed yet, so its tasks cannot have either.
      if (listRemoteId == null) continue;
      final (rawRemote, complete) = await _fetchAllTasks(listRemoteId);
      if (!complete) continue; // incomplete view; retry recovery next run
      // Translate into local-id space so the orphan match compares like with
      // like: a remote row we already track resolves to ITS local id (and is
      // therefore excluded below), an unseen one gets a fresh local id.
      final (remote, remoteIdOf) = await _localizeTasks(rawRemote);
      // Rows we already track locally — a candidate orphan is one that is NOT
      // among them: created on the server but never linked.
      final localIdSet = <String>{
        for (final t in await _store.listTasks(listId)) t.task.id,
      };

      // Orphan: a remote task with our content whose id we never recorded.
      // Match on the base snapshot — the insert payload as sent — so an edit
      // made during the in-flight window still adopts the committed row instead
      // of retrying the create and duplicating it (#122). A row with no base
      // (legacy marker) falls back to current content.
      final base = await _store.baseSnapshot(localId);
      // Adoption keys on the parent we named (#145): the orphan must sit under
      // the same remote parent. A SUBTASK's committed row may also be stored
      // completed by the insert-under-completed-parent cascade (RFC-009 §G).
      final parent = local.task.parent;
      final orphan = base != null
          ? reconcile.findOrphanByBase(base, parent, remote, localIdSet)
          : reconcile.findOrphan(local.task, remote, localIdSet);

      if (orphan != null) {
        // Pass the DRAIN-time local_updated (base_local_updated), not the row's
        // current one: an edit during the window advanced the row's
        // local_updated, so finishCreate's guard misses and keeps the edit as a
        // pending update against the new server id (#122).
        final drained =
            await _store.inflightBaseLocalUpdated(localId) ??
            local.localUpdated;
        await _store.finishCreate(
          localId,
          remoteIdOf[orphan.id]!,
          orphan.etag,
          orphan.updated,
          drained,
          orphan.position,
        );
      } else if (local.syncState == SyncState.deleted) {
        // The insert never landed AND the user has since deleted the row. There
        // is no remote id to name in a DELETE, so drop the tombstone outright.
        await _store.clearInflightCreate(localId);
        await _store.deleteTaskHard(localId);
        out.markListChanged(listId);
      } else {
        // Insert never reached the server — let normal push retry.
        await _store.clearInflightCreate(localId);
      }
    }
  }

  /// How far along the push pipeline a referenced task id is. `null` (the intent
  /// names no such id) is no constraint at all.
  Future<RefState?> _refStateOf(String? id) async {
    if (id == null) return null;
    return RefState.of(await _store.findTaskAny(id));
  }

  /// Undo the optimistic half of a move that will never reach the server. Only
  /// for CLEAN rows: a dirty row's own content push governs its etag, and
  /// clearing it there would turn a guarded If-Match patch into an unconditional
  /// one. Its response body carries the true parent anyway (P6).
  Future<void> _revertLocalMove(StoredTask? before) async {
    if (before != null && before.syncState == SyncState.clean) {
      await _store.upsertTask(
        StoredTask(
          task: _droppedEtag(before.task),
          listId: before.listId,
          syncState: before.syncState,
          localUpdated: before.localUpdated,
          pendingOp: before.pendingOp,
        ),
      );
    }
  }

  /// Everything [reconcile.planMove] needs about the local view of one pending
  /// move: how far along the push pipeline each id it names is, plus the two
  /// facts that decide whether the move would nest a third level (invariant #1).
  Future<MoveRefs> _moveRefs(PendingMove mv, StoredTask? before) async {
    final parentRow = mv.parentId == null
        ? null
        : await _store.findTaskAny(mv.parentId!);
    // Only a demote can deepen the tree; a promote or plain reorder never does.
    final taskHasChildren =
        mv.parentId != null &&
        (await _store.listTasks(
          mv.listId,
        )).any((r) => r.task.parent == mv.taskId);
    return MoveRefs(
      task: RefState.of(before),
      parent: mv.parentId == null ? null : RefState.of(parentRow),
      previous: await _refStateOf(mv.previousId),
      taskHasChildren: taskHasChildren,
      parentIsSubtask: parentRow != null && parentRow.task.parent != null,
    );
  }

  /// Adopt a landed move's response. The snapshot taken *before* the call
  /// decides how much of it is adopted: a clean row takes the whole body (a move
  /// can complete the task server-side — P6), a dirty one only the meta.
  Future<void> _applyMoveResponse(StoredTask? before, Task remote) async {
    if (reconcile.moveAdoption(before) == MoveAdoption.body && before != null) {
      await _store.applyPushedTask(remote, before.localUpdated);
    } else {
      await _store.refreshTaskMeta(remote.id, remote.etag, remote.updated);
    }
  }

  /// Push pending position/parent moves via the Tasks move endpoint.
  Future<void> _pushMoves(SyncOutcome out) async {
    for (final mv in await _store.pendingMoves()) {
      final before = await _store.findTaskAny(mv.taskId);
      final intent = reconcile.planMove(await _moveRefs(mv, before));
      switch (intent) {
        case MoveDrop():
          await _store.clearMove(mv.taskId);
          continue;
        case MoveRefuse():
          await _store.clearMove(mv.taskId);
          await _revertLocalMove(before);
          continue;
        case MoveWait():
          continue;
        case MoveSend():
          break;
      }
      // Wire ids. `planMove` only answers MoveSend once every id the intent
      // names is acknowledged (RefState.synced == it has a remote id), so these
      // resolve; a list whose own create has not landed still leaves the intent
      // queued for the next run.
      final listRemoteId = await _store.listRemoteId(mv.listId);
      final taskRemoteId = before?.remoteId;
      final parentRemoteId = mv.parentId == null
          ? null
          : (await _store.findTaskAny(mv.parentId!))?.remoteId;
      if (listRemoteId == null || taskRemoteId == null) continue;
      var previousId = reconcile.movePreviousId(mv, intent);
      // The degradation ladder (P5): at most two calls — the move as asked,
      // then, if the ambiguous 404 came back, the reparent alone. previousId is
      // null on the second pass, so the loop cannot run a third time.
      while (true) {
        final previousRemoteId = previousId == null
            ? null
            : (await _store.findTaskAny(previousId))?.remoteId;
        Task? remote;
        ApiError? error;
        try {
          remote = await _client.moveTask(
            listRemoteId,
            taskRemoteId,
            parent: parentRemoteId,
            previous: previousRemoteId,
          );
        } on ApiError catch (e) {
          error = e;
        }
        if (error == null) {
          // Clear the intent + adopt the response as ONE atomic pair
          // (MIGRATION-PLAN §5): clearMove first so applyPushedTask's guard lets
          // the server's parent/position land, both under one txn so a kill in
          // the gap rolls back and the move re-pushes next run.
          final landed = await _localizeOne(remote!, mv.taskId);
          await _store.finishMove(
            mv.taskId,
            landed,
            adoptBody: reconcile.moveAdoption(before) == MoveAdoption.body,
            expectedLocalUpdated: before?.localUpdated ?? landed.updated,
          );
          out.pushed += 1;
          break;
        }
        final failure = reconcile.onMoveError(error, previousId != null);
        if (failure == MoveFailure.dropPreviousAndRetry) {
          previousId = null;
          continue;
        }
        switch (failure) {
          case MoveFailure.dropIntent:
            await _store.clearMove(mv.taskId);
            await _revertLocalMove(before);
          case MoveFailure.retry:
            break; // transient — keep the intent, retry next run
          case MoveFailure.abort:
            throw SyncApiError(error);
          case MoveFailure.rejectAndDrop:
            _applyPushFailure(
              PushFailure.reject,
              error,
              out,
              mv.taskId,
              'move',
            );
            await _store.clearMove(mv.taskId);
            await _revertLocalMove(before);
          case MoveFailure.dropPreviousAndRetry:
            break; // handled above
        }
        break;
      }
    }
  }

  /// Push one create: anchor a subtask after its last synced sibling, durably
  /// record the in-flight marker BEFORE the non-idempotent insert, then on
  /// success `finishCreate` atomically remaps id + adopts etag/updated/position
  /// (keeping a mid-flight re-edit dirty as an update); on error KeepInflight
  /// (transient) or ClearInflight + classified failure.
  ///
  /// Public so a test can drive one create while holding the drained snapshot
  /// across the insert await (the mid-flight re-edit case); production callers
  /// reach it through [run].
  Future<void> pushCreate(StoredTask row, SyncOutcome out) async {
    // Wire ids: the list's, and (for a subtask) the parent's. The create pass
    // only reaches a row whose parent is already acknowledged
    // ([reconcile.parentIsPushable]), so a missing one means the LIST create
    // has not landed yet — the row waits for the run that lands it.
    final listRemoteId = await _store.listRemoteId(row.listId);
    if (listRemoteId == null) return;
    final parentRemoteId = row.task.parent == null
        ? null
        : (await _store.findTaskAny(row.task.parent!))?.remoteId;
    if (row.task.parent != null && parentRemoteId == null) return;
    // A subtask insert is anchored after its last already-synced sibling; a
    // top-level create needs no list read at all.
    final previous = row.task.parent == null
        ? null
        : reconcile.createPreviousAnchor(
            row,
            await _store.listTasks(row.listId),
          );
    final payload = reconcile.createPayload(row, previous, parentRemoteId);
    // Durably mark in-flight BEFORE the non-idempotent insert. The drained
    // local_updated is the base snapshot's drain marker (#124): a mid-flight
    // re-edit changes the row's local_updated, so recovery can tell it apart.
    await _store.recordInflightCreate(
      row.task.id,
      row.listId,
      row.localUpdated,
    );
    Task? remote;
    ApiError? error;
    try {
      remote = await _client.insertTask(listRemoteId, payload);
    } on ApiError catch (e) {
      error = e;
    }
    if (error == null) {
      // Atomic: LEARN the remote id AND mark clean in one txn so a crash can't
      // leave a row the server holds still flagged 'create'. The row's own id
      // never moves (#224). The local_updated snapshot keeps a mid-flight
      // re-edit dirty (as an update against the learned remote id). The
      // server-assigned position is adopted.
      await _store.finishCreate(
        row.task.id,
        remote!.id,
        remote.etag,
        remote.updated,
        row.localUpdated,
        remote.position,
      );
      out.pushed += 1;
      out.markListChanged(row.listId);
      return;
    }
    switch (reconcile.onCreateError(error)) {
      case KeepInflight():
        // Insert may or may not have reached the server. The in-flight marker
        // lets the next run adopt an orphan instead of duplicating.
        break;
      case ClearInflight(:final failure):
        await _store.clearInflightCreate(row.task.id);
        _applyPushFailure(failure, error, out, row.task.id, 'create');
    }
  }

  /// Push one content update: patch with If-Match; success adopts the response
  /// BODY (the server can coerce silently); 412 → resolveConflict; 404 →
  /// hard-delete local subtree (P4, D3 rejected); else classified failure.
  Future<void> _pushUpdate(StoredTask row, SyncOutcome out) async {
    final listRemoteId = await _store.listRemoteId(row.listId);
    if (listRemoteId == null) return;
    final patch = reconcile.updatePatch(row);
    Task? remote;
    ApiError? error;
    try {
      remote = await _client.patchTask(
        listRemoteId,
        row.remoteId!,
        patch,
        etag: row.task.etag,
      );
    } on ApiError catch (e) {
      error = e;
    }
    if (error == null) {
      // Adopt the response body, not just the etag: the server can normalize or
      // silently coerce fields, and the matching etag would otherwise block
      // pull from ever correcting the drift (P6). Translated back into local-id
      // space first — the body names Google's ids.
      await _store.applyPushedTask(
        await _localizeOne(remote!, row.task.id),
        row.localUpdated,
      );
      out.pushed += 1;
      out.markListChanged(row.listId);
      return;
    }
    switch (reconcile.onUpdateError(error)) {
      case UpdateResolveConflict():
        await _resolveConflict(row, out);
      case UpdateDeleteLocal():
        // Delete-wins (P4): the FK cascade takes this row and its WHOLE subtree,
        // unpushed subtasks included (RFC-009 D3 REJECTED; no auto-promotion).
        await _store.deleteTaskHard(row.task.id);
        out.markListChanged(row.listId);
      case UpdateFailed(:final failure):
        _applyPushFailure(failure, error, out, row.task.id, 'update');
    }
  }

  /// Resolve a 412 stale-etag conflict without losing the user's edit. Fetch the
  /// canonical remote, then: tombstone/404 → delete-wins; base-snapshot merge
  /// (#118/D8) → keep dirty with fresh etag; else adopt remote (no divergence)
  /// or fork a "(conflicted copy)".
  Future<void> _resolveConflict(StoredTask local, SyncOutcome out) async {
    final listRemoteId = await _store.listRemoteId(local.listId);
    if (listRemoteId == null) return; // stays dirty; nothing to refetch against
    Task remote;
    try {
      final fetched = await _client.getTask(listRemoteId, local.remoteId!);
      // 412×delete race: a tombstone refetch (deleted: true) is P4 delete-wins,
      // no resurrected copy — same outcome as the refetch-404 below.
      if (fetched.deleted) {
        await _store.deleteTaskHard(local.task.id);
        return;
      }
      remote = await _localizeOne(fetched, local.task.id);
    } on ApiError catch (e) {
      switch (reconcile.onConflictRefetchError(e)) {
        case RefetchFailure.deleteLocal:
          // Server deleted it; mirror push_update — the FK cascade takes the
          // whole subtree (RFC-009 D3 REJECTED; no auto-promotion).
          await _store.deleteTaskHard(local.task.id);
          return;
        case RefetchFailure.stayDirty:
          return; // stays dirty, retry next run
        case RefetchFailure.abort:
          throw SyncApiError(e);
      }
    }

    // #118 + D8: the server left the TYPED content unchanged vs our base, so a
    // bare reorder or status cascade bumped the etag — no content divergence.
    // Our typed edit wins, and the checkbox too when the base PROVES the remote
    // never moved it (D8). If anything local survives, keep it and adopt the
    // etag to re-push; else fall through and adopt the row whole (clean).
    final base = await _store.baseSnapshot(local.task.id);
    if (base != null && reconcile.onlyLocalDiverged(remote, base)) {
      var mergedTask = local.task;
      if (remote.status != base.status) {
        mergedTask = mergedTask.copyWith(
          status: remote.status,
          completed: remote.completed,
        );
      }
      if (!reconcile.sameContent(mergedTask, remote)) {
        await _store.upsertTask(
          StoredTask(
            task: mergedTask.copyWith(
              etag: remote.etag,
              updated: remote.updated,
            ),
            listId: local.listId,
            syncState: local.syncState,
            localUpdated: local.localUpdated,
            pendingOp: local.pendingOp,
          ),
        );
        out.markListChanged(local.listId);
        return;
      }
    }

    switch (reconcile.resolveConflict(local.task, remote)) {
      case ConflictResolution.adoptRemote:
        // No real divergence — just normalization/etag drift to absorb.
        await _store.applyPushedTask(remote, local.localUpdated);
      case ConflictResolution.conflictedCopy:
        // Remote becomes canonical, the local edit survives as a copy — landed
        // as ONE atomic store pair (MIGRATION-PLAN §5 kill-window): applying the
        // canonical then inserting the copy across two separate writes has a
        // crash window that overwrites the dirty id and then loses the edit (P3,
        // the reference's real gap). The canonical landing reuses applyPushedTask
        // (not a raw upsert) so a refetch naming a parent this device never
        // pulled DETACHES that unknown parent instead of aborting on the FK
        // (#155); the local_updated match makes it a clean landing that also
        // clears the base snapshot.
        out.conflicts += 1;
        final copy = reconcile.conflictedCopy(local, remote, _newId());
        await _store.resolveConflictedCopy(remote, local.localUpdated, copy);
    }
    out.markListChanged(local.listId);
  }

  /// Push one delete: unconditional (no If-Match, probe 7); success/404 →
  /// hard-delete local (FK cascade takes the subtree); else classified failure.
  ///
  /// The local hard-delete is guarded on the drained `local_updated`: an undo
  /// that revived the row while the DELETE was in flight must not be erased by
  /// the push completing (#267).
  Future<void> _pushDelete(StoredTask row, SyncOutcome out) async {
    final listRemoteId = await _store.listRemoteId(row.listId);
    final taskRemoteId = row.remoteId;
    if (listRemoteId == null || taskRemoteId == null) {
      // The server never acknowledged this row, so there is nothing to delete
      // remotely — the tombstone would otherwise linger in the drain forever.
      // A revive that landed since the drain keeps the row: nothing was deleted
      // anywhere, so its own create pass is what pushes it (#267).
      if (await _store.deleteTaskIfUnchanged(row.task.id, row.localUpdated)) {
        out.deleted += 1;
        out.markListChanged(row.listId);
      }
      return;
    }
    ApiError? error;
    try {
      await _client.deleteTask(listRemoteId, taskRemoteId);
    } on ApiError catch (e) {
      error = e;
    }
    switch (reconcile.planDelete(error)) {
      case HardDeleteLocal():
        if (await _store.deleteTaskIfUnchanged(row.task.id, row.localUpdated)) {
          out.deleted += 1;
          out.markListChanged(row.listId);
          return;
        }
        // An undo revived the row while the DELETE was in flight (#267). The
        // task is gone on Google but back on the user's screen, so hard-
        // deleting it now would lose it on BOTH sides with nothing left to
        // recover it from. Google's cascade took the subtree too, so the whole
        // subtree loses its remote identity and goes back as a fresh create;
        // a row the user re-deleted inside the same window stays a tombstone
        // and completes on the next run's 404.
        if (await _store.demoteSubtreeToCreate(row.task.id) > 0) {
          out.markListChanged(row.listId);
        }
      case final DeleteFailed f:
        _applyPushFailure(f.failure, error!, out, row.task.id, 'delete');
    }
  }

  /// A list the server no longer has is about to disappear locally (P4). Move
  /// the rows it holds that the server has NEVER SEEN into a surviving list
  /// first (P2/D2). Returns `true` when the list may now be dropped, `false`
  /// when there is nowhere to put the rows and the caller must keep it alive.
  Future<bool> _rehomeBeforeDropping(
    String ghost,
    List<StoredTaskList> survivors,
    SyncOutcome out,
  ) async {
    final target = reconcile.rehomeTarget(survivors, ghost);
    if (target != null) {
      final moved = await _store.rehomeUnpushedTasks(ghost, target.list.id);
      if (moved > 0) out.markListChanged(target.list.id);
      return true;
    }
    return !await _store.hasUnpushedTasks(ghost);
  }

  // ─── Pull ──────────────────────────────────────────────────────────────────

  /// Pull all lists and their tasks from the server.
  Future<void> _pullAll(SyncOutcome out) async {
    final List<TaskList> lists;
    try {
      lists = await _client.listTasklists();
    } on ApiError catch (e) {
      if (e.isTransient) return;
      rethrow;
    }

    // Resolve every remote list to its LOCAL row first: an existing row that
    // already carries this `remote_id`, a same-titled local create that adopts
    // it, or a brand-new row under a fresh local id.
    final localListIds = <String, String>{}; // remote list id → local list id
    for (final list in lists) {
      final (localId, changed) = await _upsertList(list);
      localListIds[list.id] = localId;
      if (changed) out.listsChanged = true;
    }

    // List ghost detection: a clean, server-backed local list whose remote id
    // is absent from the server was deleted remotely — remove it (FK cascade
    // drops its tasks).
    final remoteListIds = <String>{for (final l in lists) l.id};
    final ghostLists = [
      for (final (localId, remoteId) in await _store.cleanServerBackedLists())
        if (!remoteListIds.contains(remoteId)) localId,
    ];
    // Only a list that survives THIS pull can take in re-homed rows — otherwise
    // two lists deleted together would just hand the rows to each other and both
    // cascades would still fire.
    final localLists = await _store.allLists();
    final survivors = [
      for (final l in localLists)
        if (!ghostLists.contains(l.list.id)) l,
    ];
    for (final ghost in ghostLists) {
      // D2/P2: the rows the server never saw must not die with the list.
      if (!await _rehomeBeforeDropping(ghost, survivors, out)) {
        // Nowhere to put them: keep the list instead, as an unpushed list
        // create. It is re-created on the server next push (or adopted by
        // title) and the rows land in it — P2 holds even when the account has
        // no other list left.
        StoredTaskList? revived;
        for (final l in localLists) {
          if (l.list.id == ghost) {
            revived = l;
            break;
          }
        }
        if (revived != null) {
          await _store.upsertList(
            StoredTaskList(
              list: _listAsCreate(revived.list),
              syncState: SyncState.dirty,
              localUpdated: revived.localUpdated,
              pendingOp: 'create',
              localOnly: revived.localOnly,
            ),
          );
        }
        out.listsChanged = true;
        continue;
      }
      await _store.deleteListHardIfClean(ghost);
      out.deleted += 1;
      out.listsChanged = true;
    }

    // Compute skip-set after push so remapped ids are current.
    final dirtyIds = await _store.dirtyIds();

    // In-flight creates: a remote task matching one of these by its BASE
    // snapshot is the (possibly committed) result of an interrupted create.
    // Don't pull it as a new clean row — leave it for recoverInflightCreates to
    // adopt via id remap next run (avoids a duplicate / PK collision). Matching
    // on the base (not the live row) survives an edit made during the window
    // (#122) and the completed-parent cascade (RFC-009 §G).
    final inflightByList = <String, List<InflightBase>>{};
    for (final (localId, listId) in await _store.inflightCreates()) {
      final t = await _store.findTaskAny(localId);
      if (t != null) {
        final base =
            await _store.baseSnapshot(localId) ?? BaseSnapshot.of(t.task);
        (inflightByList[listId] ??= []).add(
          InflightBase(base: base, parent: t.task.parent),
        );
      }
    }

    for (final list in lists) {
      final localListId = localListIds[list.id]!;
      final inflight = inflightByList[localListId] ?? const <InflightBase>[];
      await _pullList(list, localListId, dirtyIds, inflight, out);
    }
  }

  /// Pull a single list's tasks, upsert changes, detect ghost rows.
  Future<void> _pullList(
    TaskList list,
    String localListId,
    Set<String> dirtyIds,
    List<InflightBase> inflight,
    SyncOutcome out,
  ) async {
    final (rawTasks, complete) = await _fetchAllTasks(list.id);
    // Everything below this line works in LOCAL id space (#224): a remote row
    // we already hold resolves to its own local id, an unseen one is minted a
    // fresh local UUID here and keeps it for good.
    final (remoteTasks, remoteIdOf) = await _localizeTasks(rawTasks);
    final presentIds = <String>{for (final t in remoteTasks) t.id};

    // Skip dirty rows and orphans of in-flight creates, then order parents
    // before children for FK safety.
    final toUpsert = reconcile.pullBatch(remoteTasks, dirtyIds, inflight);

    // Idempotency: skip rows where the local etag already matches.
    final localEtags = await _buildEtagMap(localListId);
    final knownLocal = <String>{
      for (final t in await _store.listTasks(localListId)) t.task.id,
    };
    final batchIds = <String>{for (final t in toUpsert) t.id};

    final ctx = PullRowContext(
      localEtags: localEtags,
      batchIds: batchIds,
      knownLocal: knownLocal,
    );
    for (var task in toUpsert) {
      switch (reconcile.planPullRow(task, ctx)) {
        case PullRowAction.skip:
          continue;
        case PullRowAction.upsertDetached:
          // A parent that is neither in this batch nor already local would fail
          // the FK. Detach + drop the etag so the row re-links next pull.
          task = _promoted(task, dropEtag: true);
        case PullRowAction.upsert:
          break;
      }
      final stored = StoredTask(
        task: task,
        listId: localListId,
        localUpdated: task.updated,
        syncState: SyncState.clean,
        remoteId: remoteIdOf[task.id],
      );
      // Race-safe: won't clobber a row a live UI edit just dirtied.
      await _store.upsertRemoteTask(stored);
      out.pulled += 1;
      out.markListChanged(localListId);
    }

    // Ghost detection: remove clean local rows absent from the server.
    if (complete) await _removeGhosts(localListId, presentIds, out);
  }

  /// Flatten any server-side third level in this list (RFC-009 §F/§G, D7). Each
  /// grandchild is promoted to top-level; a synced row also gets the corrective
  /// server move (gated on push, #137). Every repair counts as a conflict.
  Future<void> _repairThirdLevel(
    StoredTaskList list,
    List<String> thirdLevel,
    SyncOutcome out,
  ) async {
    final listId = list.list.id;
    for (final id in thirdLevel) {
      final before = await _store.findTaskAny(id);
      if (before == null) continue; // vanished between detection and repair
      if (before.remoteId != null && !_config.pushEnabled) {
        // Read-only sync: flatten LOCALLY now (invariant #1 is absolute) and
        // DROP the clean etag so the next pull re-examines it; the server keeps
        // the nesting until a push-enabled run sends the corrective move.
        await _promoteAndDetach(id);
        out.conflicts += 1;
        out.markListChanged(listId);
      } else if (before.remoteId != null && list.remoteId != null) {
        // A synced grandchild really sits on the server under a subtask. Push
        // the corrective move so the server converges too.
        Task? remote;
        ApiError? error;
        try {
          remote = await _client.moveTask(list.remoteId!, before.remoteId!);
        } on ApiError catch (e) {
          error = e;
        }
        if (error == null) {
          await _applyMoveResponse(before, await _localizeOne(remote!, id));
          // A clean row adopts the move body (parent → None); a row carrying a
          // pending edit only meta-adopts, so make it top-level locally too.
          await _promoteLocalIfNested(id);
          out.conflicts += 1;
          out.markListChanged(listId);
        } else {
          // The corrective move did not land. Either way the LOCAL third level
          // must NOT linger — promote now and DROP the etag so the next pull
          // re-examines the row (transient re-detects and retries; permanent is
          // ghost-removed on the next complete pull).
          await _promoteAndDetach(id);
          out.conflicts += 1;
          out.markListChanged(listId);
        }
      } else {
        // An un-acknowledged subtask create whose parent was demoted out from
        // under it (§G, before the create pushes). Promote it locally so it
        // pushes as a TOP-LEVEL create next.
        await _promoteLocalIfNested(id);
        out.conflicts += 1;
        out.markListChanged(listId);
      }
    }
  }

  /// Set a still-nested local row to top-level, preserving everything else (its
  /// pending edit/create intent, etag, content).
  Future<void> _promoteLocalIfNested(String id) async {
    final row = await _store.findTaskAny(id);
    if (row != null && row.task.parent != null) {
      await _store.upsertTask(
        StoredTask(
          task: _promoted(row.task, dropEtag: false),
          listId: row.listId,
          syncState: row.syncState,
          localUpdated: row.localUpdated,
          pendingOp: row.pendingOp,
        ),
      );
    }
  }

  /// Promote a nested local row to top-level, dropping its etag only for a CLEAN
  /// row (a DIRTY grandchild keeps its etag so its retry stays If-Match-guarded).
  Future<void> _promoteAndDetach(String id) async {
    final row = await _store.findTaskAny(id);
    if (row != null && row.task.parent != null) {
      await _store.upsertTask(
        StoredTask(
          task: _promoted(row.task, dropEtag: row.syncState == SyncState.clean),
          listId: row.listId,
          syncState: row.syncState,
          localUpdated: row.localUpdated,
          pendingOp: row.pendingOp,
        ),
      );
    }
  }

  /// Fetch all pages of tasks for a list. Returns `(tasks, complete)`;
  /// `complete` is false if a transient error interrupted pagination (never
  /// treated as a wipe).
  Future<(List<Task>, bool)> _fetchAllTasks(String listId) async {
    final all = <Task>[];
    String? pageToken;
    while (true) {
      final Page<Task> page;
      try {
        page = await _client.listTasks(listId, pageToken: pageToken);
      } on ApiError catch (e) {
        if (e.isTransient) return (all, false);
        rethrow;
      }
      all.addAll(page.items);
      final next = page.nextPageToken;
      if (next == null) break;
      pageToken = next;
    }
    return (all, true);
  }

  /// Build a map of task_id → etag for idempotency checks. Rows saved before the
  /// web_view_link column existed (link NULL) are excluded, so they re-pull once
  /// to backfill the link without a full fresh sync.
  Future<Map<String, String?>> _buildEtagMap(String listId) async {
    final rows = await _store.listTasks(listId);
    return {
      for (final t in rows)
        if (t.task.webViewLink != null) t.task.id: t.task.etag,
    };
  }

  /// Remove local clean rows that no longer exist on the server.
  Future<void> _removeGhosts(
    String listId,
    Set<String> presentIds,
    SyncOutcome out,
  ) async {
    final localClean = await _store.cleanTaskIdsForList(listId);
    for (final ghostId in localClean) {
      if (presentIds.contains(ghostId)) continue;
      // Clean-guarded: a live edit that re-dirtied the row cancels the ghost
      // delete. The FK cascade takes the whole subtree (RFC-009 D3 REJECTED).
      if (await _store.removeGhostTask(ghostId)) {
        out.deleted += 1;
        out.markListChanged(listId);
      }
    }
  }

  /// Reconcile one remote list into the local store, returning
  /// `(localListId, changed)`. The local id is the row that already carries
  /// this `remote_id`, the same-titled local create that adopts it, or a fresh
  /// UUID for a list this device has never seen.
  Future<(String, bool)> _upsertList(TaskList list) async {
    final locals = await _store.allLists();
    final byRemote = await _store.listIdsByRemoteId();
    final localized = TaskList(
      id: byRemote[list.id] ?? _newId(),
      title: list.title,
      etag: list.etag,
      updated: list.updated,
    );
    switch (reconcile.planListPull(localized, locals)) {
      case ListPullKeepLocal():
        return (localized.id, false);
      case ListPullAdoptLocalCreate(:final localId):
        await _store.finishListCreate(
          localId,
          list.id,
          list.etag,
          list.updated,
        );
        return (localId, true);
      case ListPullUpsert(:final changed):
        // Race-safe: won't clobber a list a live rename just dirtied.
        await _store.upsertRemoteList(
          StoredTaskList(
            list: localized,
            syncState: SyncState.clean,
            localUpdated: list.updated,
            remoteId: list.id,
          ),
        );
        return (localized.id, changed);
    }
  }

  // ─── Id translation (the API boundary, #224) ───────────────────────────────

  /// Translate remote rows into LOCAL id space. Each task's `id` becomes the
  /// local id of the row already carrying that `remote_id`, or a freshly minted
  /// UUID when this device has never seen it; `parent` is resolved the same
  /// way. Returns the translated tasks plus `localId → remoteId`, the reverse
  /// trip a caller needs to persist the mapping or name the row on the wire.
  ///
  /// A parent that is neither in this batch nor known locally is left
  /// unresolved, which is exactly the "unknown parent" the pull's own
  /// [PullRowAction.upsertDetached] branch is there to handle.
  Future<(List<Task>, Map<String, String>)> _localizeTasks(
    List<Task> remote,
  ) async {
    final byRemote = await _store.taskIdsByRemoteId();
    for (final t in remote) {
      byRemote[t.id] ??= _newId();
    }
    final out = <Task>[];
    final remoteIdOf = <String, String>{};
    for (final t in remote) {
      final localId = byRemote[t.id]!;
      remoteIdOf[localId] = t.id;
      final parent = t.parent;
      out.add(
        _withIds(
          t,
          localId,
          parent == null ? null : (byRemote[parent] ?? parent),
        ),
      );
    }
    return (out, remoteIdOf);
  }

  /// One API response translated back into local-id space: it describes the row
  /// with local id [localId], and its `parent` is resolved through the store's
  /// `remote_id` map (an unresolvable parent is left alone — the store's own
  /// detach guard then handles it, RFC-009 §A).
  Future<Task> _localizeOne(Task remote, String localId) async {
    final parent = remote.parent;
    if (parent == null) return _withIds(remote, localId, null);
    return _withIds(
      remote,
      localId,
      await _store.taskIdForRemote(parent) ?? parent,
    );
  }
}

/// [t] rebuilt with [id] and [parent] — the id-space translation. Written out
/// because `copyWith` cannot express a `null` parent.
Task _withIds(Task t, String id, String? parent) => Task(
  id: id,
  parent: parent,
  position: t.position,
  title: t.title,
  notes: t.notes,
  status: t.status,
  due: t.due,
  completed: t.completed,
  etag: t.etag,
  updated: t.updated,
  webViewLink: t.webViewLink,
  deleted: t.deleted,
);

// ─── Field-clearing helpers ────────────────────────────────────────────────────
// Neither [Task.copyWith] nor [TaskList] can express clearing `etag`/`parent` to
// null (copyWith uses `?? this.x`), and the reference does these as in-place field
// mutations. Rebuild the value explicitly instead.

/// A list rebuilt as an unpushed create: same id/title/updated, no etag.
TaskList _listAsCreate(TaskList l) =>
    TaskList(id: l.id, title: l.title, updated: l.updated);

/// [t] with its etag dropped, parent kept — the optimistic-move revert (P6).
Task _droppedEtag(Task t) => Task(
  id: t.id,
  parent: t.parent,
  position: t.position,
  title: t.title,
  notes: t.notes,
  status: t.status,
  due: t.due,
  completed: t.completed,
  updated: t.updated,
  webViewLink: t.webViewLink,
  deleted: t.deleted,
);

/// [t] promoted to top-level (parent cleared), dropping the etag when [dropEtag]
/// — the D7 flatten / pull detach shape.
Task _promoted(Task t, {required bool dropEtag}) => Task(
  id: t.id,
  parent: null,
  position: t.position,
  title: t.title,
  notes: t.notes,
  status: t.status,
  due: t.due,
  completed: t.completed,
  etag: dropEtag ? null : t.etag,
  updated: t.updated,
  webViewLink: t.webViewLink,
  deleted: t.deleted,
);
