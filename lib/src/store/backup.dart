// Export / backup serialization — the Dart port of `export.rs`.
//
// Produces a complete, human-readable, future-proof snapshot of everything
// axiotask holds locally — every task list, every task, and ALL of their fields
// and sync metadata — plus the exact inverse restore. Nothing the app stores is
// dropped, so a backup is a lossless mirror of the local database.
//
// The document is a single JSON object. Tasks are nested under the list they
// belong to (mirrors the user's mental model and keeps parent/child obvious).
// The top-level [Backup.version] lets future releases evolve the shape; unknown
// fields are ignored on read, so older backups keep loading and newer backups
// degrade gracefully. Enum fields serialize as their wire strings
// (`TaskStatus.apiStr` / `SyncState.asStr`) so the JSON reads cleanly.
//
// This module is pure (no IO), matching the `dates`/`export.rs` convention:
// callers own reading from the store, the `exportedAt` timestamp, and writing
// the resulting string to disk.

import 'dart:convert';

import '../model/task.dart';
import '../model/task_list.dart';
import 'stored.dart';

/// Current backup schema version. Bump when the shape changes incompatibly;
/// readers should refuse versions they do not understand.
const int backupVersion = 1;

/// Producing application name, embedded so a backup is self-describing.
const String backupApp = 'axiotask';

/// A complete local snapshot: the root of an exported backup document.
class Backup {
  const Backup({
    required this.version,
    required this.app,
    required this.exportedAt,
    required this.lists,
  });

  /// Schema version for forward/backward compatibility.
  final int version;

  /// Producing application name (always `axiotask` today).
  final String app;

  /// RFC 3339 timestamp of when the backup was produced.
  final String exportedAt;

  /// Every task list, each with its tasks nested for readability.
  final List<BackupList> lists;

  /// Assemble a backup from the store's lists paired with their tasks. Order is
  /// preserved exactly as provided; `exportedAt` should be an RFC 3339 string.
  factory Backup.build(
    String exportedAt,
    List<(StoredTaskList, List<StoredTask>)> lists,
  ) {
    return Backup(
      version: backupVersion,
      app: backupApp,
      exportedAt: exportedAt,
      lists: [
        for (final (list, tasks) in lists)
          BackupList(
            id: list.list.id,
            title: list.list.title,
            etag: list.list.etag,
            updated: list.list.updated,
            localOnly: list.localOnly,
            syncState: list.syncState.asStr,
            localUpdated: list.localUpdated,
            pendingOp: list.pendingOp,
            tasks: [for (final t in tasks) BackupTask.fromStored(t)],
          ),
      ],
    );
  }

  /// Parse a backup document from its JSON text. Unknown fields are ignored and
  /// missing optional fields default, so this stays forward- and
  /// backward-compatible. Throws [FormatException] on malformed input.
  factory Backup.fromJson(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('backup root is not a JSON object');
    }
    final rawLists = decoded['lists'];
    return Backup(
      version: (decoded['version'] as num?)?.toInt() ?? backupVersion,
      app: decoded['app'] as String? ?? backupApp,
      exportedAt: decoded['exported_at'] as String? ?? '',
      lists: [
        if (rawLists is List)
          for (final l in rawLists)
            if (l is Map<String, Object?>) BackupList._fromJson(l),
      ],
    );
  }

  /// Serialize to pretty-printed JSON (human-readable, diff-friendly).
  String toJsonPretty() =>
      const JsonEncoder.withIndent('  ').convert(_toJson());

  Map<String, Object?> _toJson() => {
    'version': version,
    'app': app,
    'exported_at': exportedAt,
    'lists': [for (final l in lists) l._toJson()],
  };

  /// Reconstruct store rows (each list paired with its tasks) from a backup —
  /// the exact inverse of [Backup.build]. Every domain field and all sync
  /// metadata are restored verbatim; unknown enum strings degrade safely
  /// (`sync_state` → clean, `status` → needsAction) rather than failing the
  /// whole restore.
  List<(StoredTaskList, List<StoredTask>)> intoStored() => [
    for (final l in lists) l._intoStored(),
  ];

  /// Total number of tasks across all lists (handy for status messages).
  int get taskCount => lists.fold(0, (sum, l) => sum + l.tasks.length);

  @override
  bool operator ==(Object other) =>
      other is Backup &&
      other.version == version &&
      other.app == app &&
      other.exportedAt == exportedAt &&
      _listEquals(other.lists, lists);

  @override
  int get hashCode =>
      Object.hash(version, app, exportedAt, Object.hashAll(lists));
}

/// A task list plus all of its sync metadata and tasks.
class BackupList {
  const BackupList({
    required this.id,
    required this.title,
    this.etag,
    required this.updated,
    required this.localOnly,
    required this.syncState,
    required this.localUpdated,
    this.pendingOp,
    required this.tasks,
  });

  /// Google's identifier (or a local UUID before first push).
  final String id;

  /// Display title.
  final String title;

  /// Opaque etag returned by Google; `null` for local-only rows.
  final String? etag;

  /// Server-side `updated` timestamp (RFC 3339).
  final String updated;

  /// Local-only list: never synced to Google.
  final bool localOnly;

  /// Local sync state: `clean` | `dirty` | `deleted`.
  final String syncState;

  /// Local timestamp of the last edit (RFC 3339).
  final String localUpdated;

  /// Pending push operation when dirty: `create` | `update` | `delete`.
  final String? pendingOp;

  /// Tasks belonging to this list, in store order.
  final List<BackupTask> tasks;

  factory BackupList._fromJson(Map<String, Object?> json) {
    final rawTasks = json['tasks'];
    return BackupList(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      etag: json['etag'] as String?,
      updated: json['updated'] as String? ?? '',
      localOnly: json['local_only'] as bool? ?? false,
      syncState: json['sync_state'] as String? ?? '',
      localUpdated: json['local_updated'] as String? ?? '',
      pendingOp: json['pending_op'] as String?,
      tasks: [
        if (rawTasks is List)
          for (final t in rawTasks)
            if (t is Map<String, Object?>) BackupTask._fromJson(t),
      ],
    );
  }

  Map<String, Object?> _toJson() => {
    'id': id,
    'title': title,
    if (etag != null) 'etag': etag,
    'updated': updated,
    'local_only': localOnly,
    'sync_state': syncState,
    'local_updated': localUpdated,
    if (pendingOp != null) 'pending_op': pendingOp,
    'tasks': [for (final t in tasks) t._toJson()],
  };

  (StoredTaskList, List<StoredTask>) _intoStored() {
    final storedTasks = [for (final t in tasks) t._intoStored(id)];
    final stored = StoredTaskList(
      list: TaskList(id: id, title: title, etag: etag, updated: updated),
      syncState: SyncState.parse(syncState) ?? SyncState.clean,
      localUpdated: localUpdated,
      pendingOp: pendingOp,
      localOnly: localOnly,
    );
    return (stored, storedTasks);
  }

  @override
  bool operator ==(Object other) =>
      other is BackupList &&
      other.id == id &&
      other.title == title &&
      other.etag == etag &&
      other.updated == updated &&
      other.localOnly == localOnly &&
      other.syncState == syncState &&
      other.localUpdated == localUpdated &&
      other.pendingOp == pendingOp &&
      _listEquals(other.tasks, tasks);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    etag,
    updated,
    localOnly,
    syncState,
    localUpdated,
    pendingOp,
    Object.hashAll(tasks),
  );
}

/// A task with every domain field and all sync metadata.
class BackupTask {
  const BackupTask({
    required this.id,
    this.parent,
    required this.position,
    required this.title,
    this.notes,
    required this.status,
    this.due,
    this.completed,
    this.etag,
    required this.updated,
    required this.syncState,
    required this.localUpdated,
    this.pendingOp,
  });

  /// Google's identifier (or a local UUID before first push).
  final String id;

  /// Parent task id; `null` means a top-level task.
  final String? parent;

  /// Google's lex-sortable position string (preserves ordering on restore).
  final String position;

  /// Display title.
  final String title;

  /// Free-form notes, verbatim.
  final String? notes;

  /// Completion status: `needsAction` | `completed`.
  final String status;

  /// Due date (RFC 3339).
  final String? due;

  /// Completion timestamp (RFC 3339).
  final String? completed;

  /// Opaque etag returned by Google.
  final String? etag;

  /// Server-side `updated` timestamp.
  final String updated;

  /// Local sync state: `clean` | `dirty` | `deleted`.
  final String syncState;

  /// Local timestamp of the last edit (RFC 3339).
  final String localUpdated;

  /// Pending push operation when dirty: `create` | `update` | `delete`.
  final String? pendingOp;

  /// Build from a stored task. `web_view_link` and `deleted` are output-only /
  /// server-derived and intentionally NOT exported (a restore reconstructs a
  /// fresh, un-tombstoned row that a later pull re-populates).
  factory BackupTask.fromStored(StoredTask st) => BackupTask(
    id: st.task.id,
    parent: st.task.parent,
    position: st.task.position,
    title: st.task.title,
    notes: st.task.notes,
    status: st.task.status.apiStr,
    due: st.task.due,
    completed: st.task.completed,
    etag: st.task.etag,
    updated: st.task.updated,
    syncState: st.syncState.asStr,
    localUpdated: st.localUpdated,
    pendingOp: st.pendingOp,
  );

  factory BackupTask._fromJson(Map<String, Object?> json) => BackupTask(
    id: json['id'] as String? ?? '',
    parent: json['parent'] as String?,
    position: json['position'] as String? ?? '',
    title: json['title'] as String? ?? '',
    notes: json['notes'] as String?,
    status: json['status'] as String? ?? '',
    due: json['due'] as String?,
    completed: json['completed'] as String?,
    etag: json['etag'] as String?,
    updated: json['updated'] as String? ?? '',
    syncState: json['sync_state'] as String? ?? '',
    localUpdated: json['local_updated'] as String? ?? '',
    pendingOp: json['pending_op'] as String?,
  );

  Map<String, Object?> _toJson() => {
    'id': id,
    if (parent != null) 'parent': parent,
    'position': position,
    'title': title,
    if (notes != null) 'notes': notes,
    'status': status,
    if (due != null) 'due': due,
    if (completed != null) 'completed': completed,
    if (etag != null) 'etag': etag,
    'updated': updated,
    'sync_state': syncState,
    'local_updated': localUpdated,
    if (pendingOp != null) 'pending_op': pendingOp,
  };

  StoredTask _intoStored(String listId) => StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: position,
      title: title,
      notes: notes,
      status: TaskStatus.parseApi(status) ?? TaskStatus.needsAction,
      due: due,
      completed: completed,
      etag: etag,
      updated: updated,
      // Not exported: a restored row starts without a web link and un-deleted.
    ),
    listId: listId,
    syncState: SyncState.parse(syncState) ?? SyncState.clean,
    localUpdated: localUpdated,
    pendingOp: pendingOp,
  );

  @override
  bool operator ==(Object other) =>
      other is BackupTask &&
      other.id == id &&
      other.parent == parent &&
      other.position == position &&
      other.title == title &&
      other.notes == notes &&
      other.status == status &&
      other.due == due &&
      other.completed == completed &&
      other.etag == etag &&
      other.updated == updated &&
      other.syncState == syncState &&
      other.localUpdated == localUpdated &&
      other.pendingOp == pendingOp;

  @override
  int get hashCode => Object.hash(
    id,
    parent,
    position,
    title,
    notes,
    status,
    due,
    completed,
    etag,
    updated,
    syncState,
    localUpdated,
    pendingOp,
  );
}

/// Order-sensitive element equality for the value types above (kept private so
/// the module stays dependency-free — no `package:collection`).
bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
