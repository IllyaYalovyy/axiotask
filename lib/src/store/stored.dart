// Store value types — the sync-metadata wrappers around the domain model, the
// Dart port of the value types in `store/repo.rs` (SyncState, StoredTask,
// StoredTaskList). They live in their own file because the backup layer
// (`backup.dart`) depends on them and the full repository (`store.dart`, T1.3)
// builds the query/mutation surface on top of the same types.
//
// Pure Dart: no Flutter, no drift dependency.

import '../model/task.dart';
import '../model/task_list.dart';

/// Per-row sync state, stored as text in SQLite.
enum SyncState {
  /// In sync with the server.
  clean,

  /// Locally modified; awaiting push.
  dirty,

  /// Locally deleted; tombstone awaiting confirmation from the server.
  deleted;

  /// Wire representation as stored in SQLite.
  String get asStr => switch (this) {
    SyncState.clean => 'clean',
    SyncState.dirty => 'dirty',
    SyncState.deleted => 'deleted',
  };

  /// Parse from the SQLite representation. Returns `null` for unknown values.
  static SyncState? parse(String s) => switch (s) {
    'clean' => SyncState.clean,
    'dirty' => SyncState.dirty,
    'deleted' => SyncState.deleted,
    _ => null,
  };
}

/// A domain [Task] plus the sync metadata the store tracks for it.
class StoredTask {
  const StoredTask({
    required this.task,
    required this.listId,
    required this.syncState,
    required this.localUpdated,
    this.pendingOp,
    this.remoteId,
  });

  /// The domain task. Its `id` is the row's LOCAL id — a UUID minted when the
  /// row was first stored (by a local create, or by the pull that first saw the
  /// remote row) and IMMUTABLE for the row's lifetime. `parent` is a local id
  /// too. Google's id lives in [remoteId], never here.
  final Task task;

  /// Which list this task belongs to.
  final String listId;

  /// Local sync state.
  final SyncState syncState;

  /// Local timestamp of the last edit (RFC 3339).
  final String localUpdated;

  /// Pending push operation when dirty: `create` | `update` | `delete`.
  final String? pendingOp;

  /// Google's id for this row, learned when its create push was acknowledged;
  /// `null` while the server has never seen the row. Write-once: the store
  /// never unlearns it, and the sync engine translates local ⇄ remote ids at
  /// the API boundary using it.
  final String? remoteId;

  @override
  bool operator ==(Object other) =>
      other is StoredTask &&
      other.task == task &&
      other.listId == listId &&
      other.syncState == syncState &&
      other.localUpdated == localUpdated &&
      other.pendingOp == pendingOp &&
      other.remoteId == remoteId;

  @override
  int get hashCode =>
      Object.hash(task, listId, syncState, localUpdated, pendingOp, remoteId);
}

/// A pending position/parent move to be pushed via the Tasks move API.
///
/// Structural moves (reorder / reparent) live on their own axis from
/// field-level edits: a task can be both edited (`tasks.pending_op`) AND moved
/// (a `pending_moves` row) before the next sync.
class PendingMove {
  const PendingMove({
    required this.taskId,
    required this.listId,
    this.parentId,
    this.previousId,
  });

  /// Task being moved.
  final String taskId;

  /// List the task belongs to.
  final String listId;

  /// Target parent (`null` = top-level).
  final String? parentId;

  /// Task it should follow (`null` = first position).
  final String? previousId;

  @override
  bool operator ==(Object other) =>
      other is PendingMove &&
      other.taskId == taskId &&
      other.listId == listId &&
      other.parentId == parentId &&
      other.previousId == previousId;

  @override
  int get hashCode => Object.hash(taskId, listId, parentId, previousId);
}

/// A domain [TaskList] plus the sync metadata the store tracks for it.
class StoredTaskList {
  const StoredTaskList({
    required this.list,
    required this.syncState,
    required this.localUpdated,
    this.pendingOp,
    this.localOnly = false,
    this.remoteId,
  });

  /// The domain list. Its `id` is the row's LOCAL id, IMMUTABLE for the row's
  /// lifetime; Google's id lives in [remoteId].
  final TaskList list;

  /// Local sync state.
  final SyncState syncState;

  /// Local timestamp of the last edit (RFC 3339).
  final String localUpdated;

  /// Pending push operation when dirty: `create` | `update` | `delete`.
  final String? pendingOp;

  /// Local-only list: never pushed to, pulled from, or reconciled against
  /// Google. Excluded from ghost detection and from all push paths.
  final bool localOnly;

  /// Google's id for this list, learned when its create push was acknowledged
  /// (or when a pull first saw it); `null` for a list the server has never
  /// seen — a local-only list keeps it `null` forever.
  final String? remoteId;

  @override
  bool operator ==(Object other) =>
      other is StoredTaskList &&
      other.list == list &&
      other.syncState == syncState &&
      other.localUpdated == localUpdated &&
      other.pendingOp == pendingOp &&
      other.localOnly == localOnly &&
      other.remoteId == remoteId;

  @override
  int get hashCode => Object.hash(
    list,
    syncState,
    localUpdated,
    pendingOp,
    localOnly,
    remoteId,
  );
}
