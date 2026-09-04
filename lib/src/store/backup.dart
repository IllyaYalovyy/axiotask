// Export / backup serialization — the Dart port of `export.rs`.
//
// Produces a complete, human-readable, future-proof snapshot of everything
// axiotask holds locally — every task list, every task, and ALL of their fields
// and sync metadata — plus the exact inverse restore. Nothing the app stores is
// dropped, so a backup is a lossless mirror of the local database. That
// includes the parts of the push queue that live outside the task row: the base
// snapshot behind a dirty row, its queued structural move, and its open
// in-flight create marker (#272), each nested under its task.
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

import '../model/base_snapshot.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'stored.dart';

/// Current backup schema version. Bump when the shape changes incompatibly;
/// readers should refuse versions they do not understand.
///
/// * 1 — lists + tasks with their domain fields and per-row sync metadata.
/// * 2 — adds the rest of the push queue, all nested under the task it belongs
///   to: its base snapshot (`base_*`), its queued structural move
///   (`pending_moves`) and its open in-flight create marker
///   (`inflight_creates`). A version-1 file still restores: every added field
///   is optional and simply absent there.
const int backupVersion = 2;

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
  /// [bases], [moves] and [inflight] are keyed by TASK id and carry the state
  /// that lives outside the task row itself: the base snapshot behind a dirty
  /// row, its queued structural move, and its open in-flight create marker.
  /// KEY PRESENCE is what [inflight] means — a marker with no recorded drain
  /// snapshot maps to `null` and is still a marker.
  factory Backup.build(
    String exportedAt,
    List<(StoredTaskList, List<StoredTask>)> lists, {
    Map<String, BaseSnapshot> bases = const {},
    Map<String, PendingMove> moves = const {},
    Map<String, String?> inflight = const {},
  }) {
    return Backup(
      version: backupVersion,
      app: backupApp,
      exportedAt: exportedAt,
      lists: [
        for (final (list, tasks) in lists)
          BackupList(
            id: list.list.id,
            remoteId: list.remoteId,
            title: list.list.title,
            etag: list.list.etag,
            updated: list.list.updated,
            localOnly: list.localOnly,
            syncState: list.syncState.asStr,
            localUpdated: list.localUpdated,
            pendingOp: list.pendingOp,
            tasks: [
              for (final t in tasks)
                BackupTask.fromStored(
                  t,
                  base: bases[t.task.id],
                  move: moves[t.task.id],
                  inflight: inflight.containsKey(t.task.id)
                      ? BackupInflight(baseLocalUpdated: inflight[t.task.id])
                      : null,
                ),
            ],
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
  /// the value-level inverse of [Backup.build]. Every domain field and the
  /// per-row sync metadata come back verbatim; the queue state that is not part
  /// of a row ([BackupTask.base], [BackupTask.move], [BackupTask.inflight])
  /// has no place in these types and is applied by the restore itself.
  /// Unknown enum strings degrade safely
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
    this.remoteId,
    required this.title,
    this.etag,
    required this.updated,
    required this.localOnly,
    required this.syncState,
    required this.localUpdated,
    this.pendingOp,
    required this.tasks,
  });

  /// The list's LOCAL id — immutable for the row's lifetime (#224).
  final String id;

  /// Google's id for the list; `null` if the server has never seen it.
  final String? remoteId;

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
      remoteId: json['remote_id'] as String?,
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
    if (remoteId != null) 'remote_id': remoteId,
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
      remoteId: remoteId,
    );
    return (stored, storedTasks);
  }

  @override
  bool operator ==(Object other) =>
      other is BackupList &&
      other.id == id &&
      other.remoteId == remoteId &&
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
    remoteId,
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
    this.remoteId,
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
    this.base,
    this.move,
    this.inflight,
  });

  /// The task's LOCAL id — immutable for the row's lifetime (#224).
  final String id;

  /// Google's id for the task; `null` if the server has never seen it.
  final String? remoteId;

  /// Parent task id (a LOCAL id); `null` means a top-level task.
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

  /// The row's content as of its last agreement with the server (`base_*`),
  /// present only while the row is dirty (RFC-009 §B). Without it a restored
  /// row resolves a 412 against the wrong content.
  final BaseSnapshot? base;

  /// The structural move queued for this row (`pending_moves`), if any.
  final BackupMove? move;

  /// The open in-flight create marker for this row (`inflight_creates`), if
  /// any — the record that an insert was issued and its answer never arrived.
  final BackupInflight? inflight;

  /// Build from a stored task. `web_view_link` and `deleted` are output-only /
  /// server-derived and intentionally NOT exported (a restore reconstructs a
  /// fresh, un-tombstoned row that a later pull re-populates).
  factory BackupTask.fromStored(
    StoredTask st, {
    BaseSnapshot? base,
    PendingMove? move,
    BackupInflight? inflight,
  }) => BackupTask(
    id: st.task.id,
    remoteId: st.remoteId,
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
    base: base,
    move: move == null
        ? null
        : BackupMove(parent: move.parentId, previous: move.previousId),
    inflight: inflight,
  );

  factory BackupTask._fromJson(Map<String, Object?> json) => BackupTask(
    id: json['id'] as String? ?? '',
    remoteId: json['remote_id'] as String?,
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
    base: _baseFromJson(json),
    move: json['pending_move'] is Map<String, Object?>
        ? BackupMove._fromJson(json['pending_move']! as Map<String, Object?>)
        : null,
    inflight: json['inflight_create'] is Map<String, Object?>
        ? BackupInflight._fromJson(
            json['inflight_create']! as Map<String, Object?>,
          )
        : null,
  );

  /// The base snapshot from its flat `base_*` fields; `null` when the file
  /// carries none (`base_title` is the presence sentinel, as in the schema).
  static BaseSnapshot? _baseFromJson(Map<String, Object?> json) {
    final title = json['base_title'] as String?;
    if (title == null) return null;
    return BaseSnapshot(
      title: title,
      notes: json['base_notes'] as String?,
      due: json['base_due'] as String?,
      status:
          TaskStatus.parseApi(json['base_status'] as String? ?? '') ??
          TaskStatus.needsAction,
    );
  }

  Map<String, Object?> _toJson() => {
    'id': id,
    if (remoteId != null) 'remote_id': remoteId,
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
    if (base != null) 'base_title': base!.title,
    if (base?.notes != null) 'base_notes': base!.notes,
    if (base?.due != null) 'base_due': base!.due,
    if (base != null) 'base_status': base!.status.apiStr,
    if (move != null) 'pending_move': move!._toJson(),
    if (inflight != null) 'inflight_create': inflight!._toJson(),
  };

  StoredTask _intoStored(String listId) => StoredTask(
    remoteId: remoteId,
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
      other.remoteId == remoteId &&
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
      other.pendingOp == pendingOp &&
      other.base == base &&
      other.move == move &&
      other.inflight == inflight;

  @override
  int get hashCode => Object.hash(
    id,
    remoteId,
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
    base,
    move,
    inflight,
  );
}

/// A queued structural move (`pending_moves`) as it appears in a backup,
/// nested under the task it belongs to. Its `list_id` is not stored: the store
/// only ever records a move for the list the task itself is in, and the row
/// cascades with that list.
class BackupMove {
  const BackupMove({this.parent, this.previous});

  /// Target parent (a LOCAL id); `null` = top level.
  final String? parent;

  /// The sibling the task should follow (a LOCAL id); `null` = first.
  final String? previous;

  factory BackupMove._fromJson(Map<String, Object?> json) => BackupMove(
    parent: json['parent'] as String?,
    previous: json['previous'] as String?,
  );

  Map<String, Object?> _toJson() => {
    if (parent != null) 'parent': parent,
    if (previous != null) 'previous': previous,
  };

  @override
  bool operator ==(Object other) =>
      other is BackupMove &&
      other.parent == parent &&
      other.previous == previous;

  @override
  int get hashCode => Object.hash(parent, previous);
}

/// An open in-flight create marker (`inflight_creates`) as it appears in a
/// backup. Its presence is the fact that matters; [baseLocalUpdated] is the
/// row's `local_updated` at the moment the insert was issued, which crash
/// recovery compares against to tell an untouched row from a re-edited one.
class BackupInflight {
  const BackupInflight({this.baseLocalUpdated});

  /// The row's `local_updated` when the insert was sent; `null` for a marker
  /// written before that was recorded.
  final String? baseLocalUpdated;

  factory BackupInflight._fromJson(Map<String, Object?> json) =>
      BackupInflight(baseLocalUpdated: json['base_local_updated'] as String?);

  Map<String, Object?> _toJson() => {
    if (baseLocalUpdated != null) 'base_local_updated': baseLocalUpdated,
  };

  @override
  bool operator ==(Object other) =>
      other is BackupInflight && other.baseLocalUpdated == baseLocalUpdated;

  @override
  int get hashCode => baseLocalUpdated.hashCode;
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
