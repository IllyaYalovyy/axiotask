// Backup export / import orchestration — the Dart port of the `export_backup` /
// `import_backup` commands (commands.rs) plus `build_backup` / `restore_backup`
// (state.rs). It is the seam between the pure [Backup] serialization
// (`store/backup.dart`), the [Store], and the filesystem: it reads every list
// and task, writes a lossless JSON snapshot to a timestamped file, and restores
// one back.
//
// Restore is NON-DESTRUCTIVE by contract (inventory-ui): it ADDS or refreshes,
// never deletes. A list or task already present locally (matched by id) is left
// untouched; anything missing is inserted as a fresh CREATE (etag cleared,
// pending push queued) so a later sync reconciles it with Google. A restored
// task whose parent is absent both locally and in the backup is re-homed to top
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

/// Outcome of an import: which file, and how many rows were actually written
/// (the non-destructive merge skips rows already present, so these can be fewer
/// than the backup holds).
class ImportResult {
  const ImportResult({
    required this.path,
    required this.lists,
    required this.tasks,
  });

  /// Absolute path of the file restored.
  final String path;

  /// Number of lists newly inserted.
  final int lists;

  /// Number of tasks newly inserted.
  final int tasks;
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

  // The non-destructive merge. Existing ids (list or task) are left alone;
  // missing rows are inserted as fresh creates so a later sync pushes them.
  Future<ImportResult> _restore(Backup backup, String path) async {
    final now = nowUtcString();
    final existingListIds = {for (final l in await store.allLists()) l.list.id};

    var listsWritten = 0;
    var tasksWritten = 0;

    // First pass: capture every restored task's declared parent so the
    // normalization pass can walk the ancestry (order-independent, and so a
    // child whose parent is also being restored is NOT wrongly re-homed).
    final backupParent = <String, String?>{
      for (final l in backup.lists)
        for (final t in l.tasks) t.id: t.parent,
    };

    for (final l in backup.lists) {
      final listExists = existingListIds.contains(l.id);
      if (!listExists) {
        // A restored list comes back as a fresh create: no etag, and a pending
        // create push unless it is local-only (which never syncs).
        await store.upsertList(
          StoredTaskList(
            list: TaskList(id: l.id, title: l.title, updated: l.updated),
            syncState: l.localOnly ? SyncState.clean : SyncState.dirty,
            localUpdated: now,
            pendingOp: l.localOnly ? null : 'create',
            localOnly: l.localOnly,
          ),
        );
        listsWritten += 1;
      }

      for (final t in l.tasks) {
        // Skip a task already present locally (non-destructive).
        if (await store.findTaskAny(t.id) != null) continue;

        // Normalize the parent to keep nesting at one level: a dangling parent
        // re-homes to top level (FK safety), and a >1-level chain flattens onto
        // its top-level ancestor (F13/#191) — a backup from an older/buggy build
        // could carry a nest no list view can render.
        final parent = await _normalizeParent(t.parent, backupParent);

        await store.upsertTask(
          StoredTask(
            task: Task(
              id: t.id,
              parent: parent,
              position: t.position,
              title: t.title,
              notes: t.notes,
              status: TaskStatus.parseApi(t.status) ?? TaskStatus.needsAction,
              due: t.due,
              completed: t.completed,
              updated: t.updated,
              // Fresh create: no etag / web link, reconciled on the next pull.
            ),
            listId: l.id,
            syncState: SyncState.dirty,
            localUpdated: now,
            pendingOp: 'create',
          ),
        );
        tasksWritten += 1;
      }
    }

    return ImportResult(path: path, lists: listsWritten, tasks: tasksWritten);
  }

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
