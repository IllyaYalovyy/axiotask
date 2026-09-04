// Backup export / import orchestration — the Dart port of the `export_backup` /
// `import_backup` commands (commands.rs) plus `build_backup` / `restore_backup`
// (state.rs). It is the seam between the pure [Backup] serialization
// (`store/backup.dart`), the [Store], and the filesystem: it reads every list
// and task, writes a lossless JSON snapshot to a timestamped file, and restores
// one back.
//
// Restore is NON-DESTRUCTIVE by contract (inventory-ui): it ADDS or refreshes,
// never deletes. Rows are matched the way GOOGLE identifies them — by
// `remote_id` (#272), the one identity that survives a device reset, since
// local ids are minted per device and per pull (#224). A row already present is
// left alone unless the backup's copy is NEWER and the local one is clean, in
// which case the backup's content is adopted onto the local row (its local id
// and its place in the tree never move) as a pending update. A row that is
// missing is inserted: with its remote id, etag and sync state when Google
// already holds it, and as a fresh CREATE only when the server has never seen
// it — inserting an acknowledged row as a create would duplicate the user's
// whole account. The push queue that lives outside the task row comes back too:
// base snapshots, queued moves and in-flight create markers. A restored task
// whose parent is absent both locally and in the backup is re-homed to top
// level for FK safety (subtasks are strictly one level; a dangling parent would
// orphan the row). Restore refuses a backup written by a NEWER app version
// rather than silently dropping fields it does not understand.

import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import '../model/dates.dart' show nowUtcString;
import '../model/task.dart';
import '../model/task_list.dart';
import '../store/backup.dart';
import '../store/store.dart';
import '../store/stored.dart';
import 'backup_paths.dart';
import 'ids.dart' show newLocalId;

/// Outcome of an export: where it landed and how much it holds.
class ExportResult {
  const ExportResult({
    required this.path,
    required this.lists,
    required this.tasks,
    required this.bytes,
  });

  /// Absolute path of the file written.
  final String path;

  /// Number of lists exported.
  final int lists;

  /// Number of tasks exported (across all lists).
  final int tasks;

  /// Byte length of the written JSON.
  final int bytes;
}

/// Outcome of an import: which file, how many rows were inserted, and how many
/// already-present rows had the backup's content adopted onto them. The merge
/// is non-destructive and matches on `remote_id`, so restoring what the device
/// already holds legitimately reports zeroes everywhere.
class ImportResult {
  const ImportResult({
    required this.path,
    required this.lists,
    required this.tasks,
    this.listsUpdated = 0,
    this.tasksUpdated = 0,
  });

  /// Absolute path of the file restored.
  final String path;

  /// Number of lists newly inserted.
  final int lists;

  /// Number of tasks newly inserted.
  final int tasks;

  /// Number of existing lists whose title the backup restored.
  final int listsUpdated;

  /// Number of existing tasks whose content the backup restored.
  final int tasksUpdated;
}

/// A user-facing backup failure whose message is safe to show verbatim (the
/// "no backup file found" / "invalid backup file" / "newer than this app
/// supports" strings the reference surfaces in a toast).
class BackupError implements Exception {
  const BackupError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads/writes lossless backups for one instance's [backupsDir].
class BackupService {
  BackupService({required this.store, required this.backupsDir});

  /// The store backups are read from and restored into.
  final Store store;

  /// The instance's backups directory (default export target / restore source).
  final Directory backupsDir;

  /// Write a complete snapshot of every list and task to [to], or to a fresh
  /// timestamped file in the backups dir when omitted. Port of `export_backup`.
  Future<ExportResult> export({File? to}) async {
    final lists = await store.allLists();
    final withTasks = <(StoredTaskList, List<StoredTask>)>[];
    for (final l in lists) {
      withTasks.add((l, await store.listTasks(l.list.id)));
    }
    final backup = Backup.build(
      clock.now().toUtc().toIso8601String(),
      withTasks,
      bases: await store.allBaseSnapshots(),
      moves: {for (final m in await store.pendingMoves()) m.taskId: m},
      inflight: await store.allInflightCreateBases(),
    );
    final json = backup.toJsonPretty();

    final target = to ?? defaultBackupIn(backupsDir);
    // Async IO so a large snapshot never blocks the UI isolate (ANR risk on a
    // phone); the buttons stay disabled via the caller's busy guard meanwhile.
    await target.parent.create(recursive: true);
    await target.writeAsString(json, flush: true);

    return ExportResult(
      path: target.path,
      lists: backup.lists.length,
      tasks: backup.taskCount,
      bytes: utf8.encode(json).length,
    );
  }

  /// Restore from [from], or from the newest backup in the backups dir when
  /// omitted. Non-destructive merge. Port of `import_backup` + `restore_backup`.
  /// Throws [BackupError] when no file is found, the file is unreadable/invalid,
  /// or the backup was written by a newer app version.
  Future<ImportResult> importFrom({File? from}) async {
    final target = from ?? latestBackupIn(backupsDir);
    if (target == null) {
      throw const BackupError('no backup file found to restore');
    }

    final String text;
    try {
      text = await target.readAsString();
    } on FileSystemException catch (e) {
      throw BackupError('invalid backup file: ${e.message}');
    }

    final Backup backup;
    try {
      backup = Backup.fromJson(text);
    } on FormatException catch (e) {
      throw BackupError('invalid backup file: ${e.message}');
    }

    if (backup.version > backupVersion) {
      throw BackupError(
        'backup version ${backup.version} is newer than this app '
        'supports ($backupVersion)',
      );
    }

    return _restore(backup, target.path);
  }

  // The merge. It is NON-DESTRUCTIVE — it adds and refreshes, never deletes —
  // and it matches rows the way GOOGLE identifies them: by `remote_id` (#272).
  //
  // Local ids are minted per device and per pull (#224), so the same Google
  // task carries a different local id after a wipe-and-repull. Matched on the
  // local id, a restore would therefore see every row as missing and insert the
  // user's whole account a second time as pending CREATEs — duplicating every
  // task on Google at the next sync. Matched on `remote_id`, a restore of what
  // Google already holds is a no-op.
  //
  // The whole merge is ONE transaction (#271). Row by row, a fault — or the
  // process dying, which on Android can happen at any await — leaves the user
  // with a list holding only some of its tasks and no way to tell which are
  // missing; worse, the retry is non-destructive, so it SKIPS the rows that did
  // land and the gap becomes permanent. All or nothing. ([Store.writeTasks],
  // the other atomic write path, cannot express this one: the restore READS
  // between its writes — resolving each task's parent and each row's identity —
  // which a prepared row list has no way to say.)
  Future<ImportResult> _restore(Backup backup, String path) =>
      store.transaction(() => _restoreInTransaction(backup, path));

  Future<ImportResult> _restoreInTransaction(Backup backup, String path) async {
    final plan = await _plan(backup);
    return _apply(plan, path);
  }

  /// Decide, for every row in the backup, WHICH local row it is and what to do
  /// with it — before anything is written. Planning first is what lets a
  /// task's parent resolve to a local id whose row is written later (a backup
  /// lists subtasks after their parents, but the parent's identity has to be
  /// known either way) and what keeps the newly claimed ids collision-free.
  Future<_RestorePlan> _plan(Backup backup) async {
    final listByRemote = await store.listIdsByRemoteId();
    final taskByRemote = await store.taskIdsByRemoteId();

    // Every restored task's declared parent, so the normalization pass can walk
    // the ancestry (order-independent, and so a child whose parent is also
    // being restored is NOT wrongly re-homed).
    final backupParent = <String, String?>{
      for (final l in backup.lists)
        for (final t in l.tasks) t.id: t.parent,
    };

    final lists = <_ListPlan>[];
    final tasks = <_TaskPlan>[];
    final taskTarget = <String, String>{};
    final claimedLists = <String>{};
    final claimedTasks = <String>{};

    for (final l in backup.lists) {
      final matchedId = l.remoteId == null ? null : listByRemote[l.remoteId];
      final local = await store.findListAny(matchedId ?? l.id);
      final _ListPlan plan;
      if (local != null && (matchedId != null || l.remoteId == null)) {
        // The same list, found by its Google id — or, for a list Google has
        // never seen, by the local id it was exported under.
        plan = _ListPlan(
          backup: l,
          localId: local.list.id,
          local: local,
          adopt: _adoptsList(l, local),
        );
      } else {
        plan = _ListPlan(
          backup: l,
          localId: _claim(l.id, claimedLists, local != null),
          local: null,
          adopt: false,
        );
      }
      claimedLists.add(plan.localId);
      lists.add(plan);

      for (final t in l.tasks) {
        final matched = t.remoteId == null ? null : taskByRemote[t.remoteId];
        final localTask = await store.findTaskAny(matched ?? t.id);
        final _TaskPlan tp;
        if (localTask != null && (matched != null || t.remoteId == null)) {
          tp = _TaskPlan(
            backup: t,
            localId: localTask.task.id,
            listId: localTask.listId,
            local: localTask,
            adopt: _adoptsTask(t, localTask),
          );
        } else {
          tp = _TaskPlan(
            backup: t,
            localId: _claim(t.id, claimedTasks, localTask != null),
            listId: plan.localId,
            local: null,
            adopt: false,
            localOnlyList: plan.local?.localOnly ?? l.localOnly,
          );
        }
        claimedTasks.add(tp.localId);
        taskTarget[t.id] = tp.localId;
        tasks.add(tp);
      }
    }

    // Parents last: every task's local identity is known by now, so a link can
    // be normalized (one level, no dangling) and then translated in one step.
    for (final tp in tasks) {
      if (tp.local != null) continue; // an existing row keeps its own place
      final normalized = await _normalizeParent(tp.backup.parent, backupParent);
      tp.parentLocalId = normalized == null
          ? null
          : taskTarget[normalized] ?? normalized;
    }

    return _RestorePlan(lists: lists, tasks: tasks, taskTarget: taskTarget);
  }

  /// Write the plan. Lists first (a task's `list_id` is a foreign key), then
  /// the top-level tasks, then the subtasks — a child's `parent_id` is a
  /// foreign key too, and it is checked per statement.
  Future<ImportResult> _apply(_RestorePlan plan, String path) async {
    final now = nowUtcString();
    var listsWritten = 0;
    var tasksWritten = 0;
    var listsUpdated = 0;
    var tasksUpdated = 0;

    for (final lp in plan.lists) {
      if (lp.local == null) {
        await store.upsertList(_insertedList(lp));
        listsWritten += 1;
      } else if (lp.adopt) {
        await store.upsertList(_adoptedList(lp, now));
        listsUpdated += 1;
      }
    }

    final ordered = [
      ...plan.tasks.where((t) => t.parentLocalId == null),
      ...plan.tasks.where((t) => t.parentLocalId != null),
    ];
    for (final tp in ordered) {
      if (tp.local == null) {
        final row = _insertedTask(tp, now);
        await store.upsertTask(row);
        await _restoreQueueState(tp, row, plan.taskTarget);
        tasksWritten += 1;
      } else if (tp.adopt) {
        await store.upsertTask(_adoptedTask(tp, now));
        tasksUpdated += 1;
      }
    }

    return ImportResult(
      path: path,
      lists: listsWritten,
      tasks: tasksWritten,
      listsUpdated: listsUpdated,
      tasksUpdated: tasksUpdated,
    );
  }

  /// The row for a list the store does not have. A list Google has ALREADY
  /// acknowledged (it has a `remote_id`) comes back with its remote id, its
  /// etag and its own sync state: queued as a create it would be created a
  /// SECOND time on the user's account. Only a list the server has never seen
  /// is a pending create.
  StoredTaskList _insertedList(_ListPlan lp) {
    final l = lp.backup;
    final acknowledged = l.remoteId != null;
    var sync = SyncState.parse(l.syncState) ?? SyncState.clean;
    String? op = l.pendingOp;
    if (acknowledged) {
      // `create` against a list Google has named would create it twice; an
      // unpushed rename still has to reach the server, so it stays an update.
      if (op == 'create') op = 'update';
      if (sync == SyncState.clean) op = null;
      if (sync != SyncState.clean && op == null) op = 'update';
    } else if (l.localOnly) {
      if (sync == SyncState.clean) op = null;
    } else {
      sync = SyncState.dirty;
      op = 'create';
    }
    return StoredTaskList(
      list: TaskList(
        id: lp.localId,
        title: l.title,
        etag: acknowledged ? l.etag : null,
        updated: l.updated,
      ),
      syncState: sync,
      localUpdated: l.localUpdated.isEmpty ? l.updated : l.localUpdated,
      pendingOp: op,
      localOnly: l.localOnly,
      remoteId: l.remoteId,
    );
  }

  /// The local list, with the backup's title adopted — a rename that was lost
  /// and now has to reach Google, so it goes back dirty as an `update`.
  StoredTaskList _adoptedList(_ListPlan lp, String now) => StoredTaskList(
    list: TaskList(
      id: lp.localId,
      title: lp.backup.title,
      etag: lp.local!.list.etag,
      updated: lp.local!.list.updated,
    ),
    syncState: SyncState.dirty,
    localUpdated: now,
    pendingOp: lp.local!.remoteId == null ? 'create' : 'update',
    localOnly: lp.local!.localOnly,
    remoteId: lp.local!.remoteId,
  );

  /// The row for a task the store does not have. As with lists, a task Google
  /// already holds comes back with its remote id, its etag and its own sync
  /// state — never as a create, which would insert it a second time. A task the
  /// server has never seen is a pending create, so the sync that follows the
  /// restore puts it on the user's account; only in a local-only list (which
  /// never pushes) does it come back with whatever state it was exported in.
  StoredTask _insertedTask(_TaskPlan tp, String now) {
    final t = tp.backup;
    final acknowledged = t.remoteId != null;
    var sync = SyncState.parse(t.syncState) ?? SyncState.clean;
    String? op = t.pendingOp;
    if (acknowledged) {
      // `create` against a row Google has named would duplicate it.
      if (op == 'create') op = 'update';
      if (sync == SyncState.clean) op = null;
      if (sync != SyncState.clean && op == null) op = 'update';
    } else if (tp.localOnlyList) {
      // A local-only list never pushes anything, so its rows come back exactly
      // as they were — there is no server for their state to be wrong about.
      if (sync == SyncState.clean) op = null;
    } else if (sync != SyncState.deleted) {
      sync = SyncState.dirty;
      op = 'create';
    }
    return StoredTask(
      task: Task(
        id: tp.localId,
        parent: tp.parentLocalId,
        position: t.position,
        title: t.title,
        notes: t.notes,
        status: TaskStatus.parseApi(t.status) ?? TaskStatus.needsAction,
        due: t.due,
        completed: t.completed,
        etag: acknowledged ? t.etag : null,
        updated: t.updated,
        // Not exported: a restored row starts without a web link and un-deleted.
      ),
      listId: tp.listId,
      syncState: sync,
      localUpdated: t.localUpdated.isEmpty ? now : t.localUpdated,
      pendingOp: op,
      remoteId: t.remoteId,
    );
  }

  /// The local row with the backup's CONTENT adopted. Its identity and its
  /// place in the tree are local (ids are immutable, #224; order is Google's),
  /// so only the user-visible fields move — as a pending update, because the
  /// content the backup holds is content the server does not have.
  StoredTask _adoptedTask(_TaskPlan tp, String now) {
    final t = tp.backup;
    final local = tp.local!;
    return StoredTask(
      task: Task(
        id: local.task.id,
        parent: local.task.parent,
        position: local.task.position,
        title: t.title,
        notes: t.notes,
        status: TaskStatus.parseApi(t.status) ?? TaskStatus.needsAction,
        due: t.due,
        completed: t.completed,
        etag: local.task.etag,
        updated: local.task.updated,
        webViewLink: local.task.webViewLink,
      ),
      listId: local.listId,
      syncState: SyncState.dirty,
      localUpdated: now,
      pendingOp: local.remoteId == null ? 'create' : 'update',
      remoteId: local.remoteId,
    );
  }

  /// Restore the queue state that lives OUTSIDE the task row: the base snapshot
  /// a 412 is resolved against, the queued structural move, and the in-flight
  /// create marker that stops a create whose answer never arrived from being
  /// inserted on Google twice. Only for rows this restore INSERTED — a row
  /// already here owns its own queue state, and clobbering it would push work
  /// the user never asked for.
  Future<void> _restoreQueueState(
    _TaskPlan tp,
    StoredTask row,
    Map<String, String> taskTarget,
  ) async {
    final t = tp.backup;
    // A base belongs to a row with unpushed content; a clean row must carry
    // none (schema invariant §B).
    if (t.base != null && row.syncState != SyncState.clean) {
      await store.setBaseSnapshot(row.task.id, t.base!);
    }
    final move = t.move;
    if (move != null) {
      await store.recordMove(
        row.task.id,
        row.listId,
        _translate(move.parent, taskTarget),
        _translate(move.previous, taskTarget),
      );
    }
    // A marker means "an insert is outstanding", which can only be true of a
    // row Google has not named yet.
    if (t.inflight != null && row.remoteId == null) {
      await store.writeInflightCreate(
        row.task.id,
        row.listId,
        t.inflight!.baseLocalUpdated,
      );
    }
  }

  /// A backup id in local id space; ids the backup does not describe (a row
  /// that was already local when it was written) pass through unchanged.
  String? _translate(String? backupId, Map<String, String> taskTarget) =>
      backupId == null ? null : taskTarget[backupId] ?? backupId;

  /// Claim a local id for a row being inserted: the id it was exported under
  /// when that is free, else a fresh one. The id must not already belong to
  /// another row — a backup restored onto a device that minted the same id for
  /// something else would otherwise overwrite it.
  String _claim(String want, Set<String> claimed, bool taken) =>
      taken || claimed.contains(want) || want.isEmpty ? newLocalId() : want;

  /// Whether the backup's copy of a row supersedes the local one: the local row
  /// must be CLEAN (an unpushed local edit always wins — it is work that exists
  /// nowhere else), the backup must be NEWER, and the content must actually
  /// differ (otherwise the restore would queue a push that changes nothing).
  bool _adoptsTask(BackupTask t, StoredTask local) =>
      local.syncState == SyncState.clean &&
      t.localUpdated.compareTo(local.localUpdated) > 0 &&
      (t.title != local.task.title ||
          t.notes != local.task.notes ||
          t.due != local.task.due ||
          t.completed != local.task.completed ||
          t.status != local.task.status.apiStr);

  bool _adoptsList(BackupList l, StoredTaskList local) =>
      local.syncState == SyncState.clean &&
      l.localUpdated.compareTo(local.localUpdated) > 0 &&
      l.title != local.list.title;

  /// Resolve the parent a restored task should attach to so nesting never
  /// exceeds one level. Walks up the ancestry — the backup's declared parents
  /// first ([backupParent]), then the local store — to the nearest TOP-LEVEL
  /// task and attaches there:
  ///
  /// - [parent] `null` (or unresolvable to any real row): stays top level.
  /// - a top-level parent: kept as-is (the one allowed level).
  /// - a parent that is itself a subtask: the chain FLATTENS onto its top-level
  ///   ancestor, so a 3-level backup lands as valid one-level subtasks under the
  ///   root instead of an unrenderable nest (F13/#191).
  /// - a parent that dangles higher up: the child below the missing node is
  ///   itself re-homed to top level, so the task attaches there.
  ///
  /// A corrupt cycle bails to the last valid candidate rather than looping.
  Future<String?> _normalizeParent(
    String? parent,
    Map<String, String?> backupParent,
  ) async {
    final seen = <String>{};
    // `child` is the node one level below `cur` in the walk — a valid
    // top-level candidate once `cur` is found to be missing.
    String? child;
    var cur = parent;
    while (cur != null) {
      if (!seen.add(cur)) return child; // cycle guard
      final String? next;
      if (backupParent.containsKey(cur)) {
        next = backupParent[cur];
      } else {
        final local = await store.findTaskAny(cur);
        // `cur` exists nowhere: it dangles, so the node below it (`child`) is
        // top level — attach there (`null` when `cur` was the original parent).
        if (local == null) return child;
        next = local.task.parent;
      }
      if (next == null) return cur; // `cur` is a top-level task → attach here
      child = cur;
      cur = next;
    }
    return null;
  }
}

/// What the restore decided about ONE backup list: which local row it is, and
/// whether the backup's title supersedes it. `local == null` means insert.
class _ListPlan {
  _ListPlan({
    required this.backup,
    required this.localId,
    required this.local,
    required this.adopt,
  });

  final BackupList backup;
  final String localId;
  final StoredTaskList? local;
  final bool adopt;
}

/// What the restore decided about ONE backup task. `local == null` means
/// insert; [parentLocalId] is filled in once every task's identity is known.
class _TaskPlan {
  _TaskPlan({
    required this.backup,
    required this.localId,
    required this.listId,
    required this.local,
    required this.adopt,
    this.localOnlyList = false,
  });

  final BackupTask backup;
  final String localId;
  final String listId;
  final StoredTask? local;
  final bool adopt;

  /// Whether the list this row lands in is local-only (never pushes).
  final bool localOnlyList;

  /// The parent this row attaches to, in LOCAL id space; `null` = top level.
  String? parentLocalId;
}

/// The whole decision, taken before a single row is written.
class _RestorePlan {
  const _RestorePlan({
    required this.lists,
    required this.tasks,
    required this.taskTarget,
  });

  final List<_ListPlan> lists;
  final List<_TaskPlan> tasks;

  /// Backup task id → the LOCAL id it resolved to.
  final Map<String, String> taskTarget;
}
