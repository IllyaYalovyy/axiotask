// Pure sync decision core (RFC-009 Step 1) — the Dart port of
// `sync/reconcile.rs`.
//
// Every decision the sync engine makes is a function of *observations* — the
// local row state and what the server answered — and nothing else. Those
// decisions live here, as pure `(state, observation) → action` functions with
// no IO, no async, no store, and no client. The engine (Step 5, later tasks)
// keeps the three things that genuinely need the outside world: **observe**
// (read the store, call the API), **decide** (call into this module), **apply**
// (write the store).
//
// This file is built in two migration steps. T5.3 lands the push-side half:
// the shared failure classification plus §B/§C (content update), §D (delete)
// and §G (create). T5.4 appends §E/§F (moves), §I (lists) and §A (pull).
// Section markers (§B, §D, …) refer to the matrix in
// `designs/RFC-009-sync-conflict-matrix.md` in the reference repo.
//
// Pure Dart: no Flutter dependency, fully unit-testable.

import '../api/api_error.dart';
import '../model/base_snapshot.dart';
import '../model/dates.dart' show normalizeDue;
import '../model/task.dart';
import '../store/stored.dart';

// ─── Shared vocabulary ───────────────────────────────────────────────────────

/// How far along the push pipeline a task id referenced by a pending intent is.
/// Local ids are UUIDs the server has never seen; naming one in a request draws
/// a permanent 400 ("Invalid task ID", verified live).
enum RefState {
  /// No such row locally (deleted, or never existed).
  missing,

  /// Present locally but never pushed — it still carries a local UUID.
  local,

  /// Present and pushed: it carries a server etag, so its id is real.
  synced;

  /// Classify a referenced row as the store returned it.
  static RefState of(StoredTask? row) {
    if (row == null) return RefState.missing;
    return row.task.etag != null ? RefState.synced : RefState.local;
  }
}

/// How a failed row push resolves. Transient errors leave the row dirty for the
/// next run. A server rejection (400 & co.) also leaves the row dirty but is
/// counted and logged — it must not abort the run, or one poisoned row would
/// permanently starve every other push AND the pull. Only auth failures abort:
/// every subsequent call would fail the same way.
enum PushFailure {
  /// Leave the row dirty; the next run retries it.
  retry,

  /// Count it, log it, keep the row dirty, and continue with the next row.
  reject,

  /// Auth is dead — abort the whole run.
  abort,
}

/// Classify one row's push failure ([PushFailure]).
PushFailure pushFailure(ApiError e) {
  if (e.isTransient) return PushFailure.retry;
  if (e is Unauthorized || e is AuthExpired) return PushFailure.abort;
  return PushFailure.reject;
}

// ─── §B/§C — content update ──────────────────────────────────────────────────

/// What a failed content-update push does to the row (§B, §C).
sealed class UpdateFailure {
  const UpdateFailure();
}

/// `412`: the etag is stale — refetch and reconcile ([resolveConflict]).
final class UpdateResolveConflict extends UpdateFailure {
  const UpdateResolveConflict();

  @override
  bool operator ==(Object other) => other is UpdateResolveConflict;

  @override
  int get hashCode => (UpdateResolveConflict).hashCode;
}

/// `404`: the row is gone on the server (deleted, or cascaded away with a
/// deleted parent). Delete wins in both directions (P4) — hard-delete locally
/// and discard the edit.
final class UpdateDeleteLocal extends UpdateFailure {
  const UpdateDeleteLocal();

  @override
  bool operator ==(Object other) => other is UpdateDeleteLocal;

  @override
  int get hashCode => (UpdateDeleteLocal).hashCode;
}

/// Anything else — generic row-push failure handling.
final class UpdateFailed extends UpdateFailure {
  const UpdateFailed(this.failure);

  /// The classified push failure.
  final PushFailure failure;

  @override
  bool operator ==(Object other) =>
      other is UpdateFailed && other.failure == failure;

  @override
  int get hashCode => Object.hash(UpdateFailed, failure);
}

/// Decide what an update push's error means (§B). A success always adopts the
/// response **body**, not just the etag (P6) — that lives in the engine.
UpdateFailure onUpdateError(ApiError e) => switch (e) {
  PreconditionFailed() => const UpdateResolveConflict(),
  NotFound() => const UpdateDeleteLocal(),
  _ => UpdateFailed(pushFailure(e)),
};

/// How a `412` resolves once the authoritative remote row is in hand.
enum ConflictResolution {
  /// No real divergence — adopt the remote row wholesale (etag included).
  adoptRemote,

  /// Real divergence — remote becomes canonical and the local edit survives as
  /// a "(conflicted copy)" task (P3). Nothing is silently discarded.
  conflictedCopy,
}

/// Resolve a `412` conflict: identical content is just etag/normalization drift
/// to absorb; divergent content preserves both (P3).
///
/// **Status is deliberately excluded from the divergence test** (RFC-009 D1,
/// ratified): when title, notes and due all agree and only the checkbox
/// differs, remote wins outright and no copy is made. A lost checkbox click
/// costs one click to redo; a duplicate "buy milk (conflicted copy)" is
/// confusing and has to be cleaned up by hand. Status still counts everywhere
/// else — [sameContent] is unchanged, so create-adoption stays exact.
ConflictResolution resolveConflict(Task local, Task remote) =>
    sameTypedContent(local, remote)
    ? ConflictResolution.adoptRemote
    : ConflictResolution.conflictedCopy;

/// What a failed refetch during `412` resolution does (§B).
enum RefetchFailure {
  /// `404`: the server deleted it — mirror the update-path behavior (P4).
  deleteLocal,

  /// Transient — the row stays dirty and retries next run.
  stayDirty,

  /// Anything else aborts the run, preserving the local edit untouched.
  abort,
}

/// Decide what a failed conflict refetch means (§B).
RefetchFailure onConflictRefetchError(ApiError e) {
  if (e is NotFound) return RefetchFailure.deleteLocal;
  if (e.isTransient) return RefetchFailure.stayDirty;
  return RefetchFailure.abort;
}

/// The patch an update push sends. Canonicalizes on the way out: Google 400s a
/// bare date, `""` clears a due date (both verified live), and cleared notes go
/// as `""` rather than being omitted. An unparseable stored due degrades to
/// "clear" rather than poisoning the row forever.
TaskPatch updatePatch(StoredTask row) => TaskPatch(
  title: row.task.title,
  notes: row.task.notes ?? '',
  due: (row.task.due == null ? null : normalizeDue(row.task.due!)) ?? '',
  status: row.task.status,
);

/// The surviving local edit, as a fresh unpushed "(conflicted copy)" create.
/// [newId] is supplied by the caller so this stays pure.
StoredTask conflictedCopy(StoredTask local, Task remote, String newId) =>
    StoredTask(
      // Build the Task directly: the copy drops the etag and web-view link and
      // takes a fresh id/title, keeping every other field from the local edit
      // (the Dart equivalent of the reference's `..local.task.clone()`).
      task: Task(
        id: newId,
        parent: local.task.parent,
        position: local.task.position,
        title: '${local.task.title} (conflicted copy)',
        notes: local.task.notes,
        status: local.task.status,
        due: local.task.due,
        completed: local.task.completed,
        updated: remote.updated,
        deleted: local.task.deleted,
      ),
      listId: local.listId,
      syncState: SyncState.dirty,
      pendingOp: 'create',
      localUpdated: remote.updated,
    );

// ─── §D — delete ─────────────────────────────────────────────────────────────

/// What a delete push does (§D).
sealed class DeleteAction {
  const DeleteAction();
}

/// Hard-delete locally and clear the tombstone. A remote `404` counts as
/// success: the row is gone either way.
final class HardDeleteLocal extends DeleteAction {
  const HardDeleteLocal();

  @override
  bool operator ==(Object other) => other is HardDeleteLocal;

  @override
  int get hashCode => (HardDeleteLocal).hashCode;
}

/// Generic row-push failure handling.
final class DeleteFailed extends DeleteAction {
  const DeleteFailed(this.failure);

  /// The classified push failure.
  final PushFailure failure;

  @override
  bool operator ==(Object other) =>
      other is DeleteFailed && other.failure == failure;

  @override
  int get hashCode => Object.hash(DeleteFailed, failure);
}

/// Decide what a delete push's answer means (§D); `null` is a success. The
/// DELETE is unconditional (no If-Match), so a concurrent remote edit is
/// discarded (P4).
DeleteAction planDelete(ApiError? error) {
  if (error == null || error is NotFound) return const HardDeleteLocal();
  return DeleteFailed(pushFailure(error));
}

// ─── §G — create ─────────────────────────────────────────────────────────────

/// Whether a dirty row is a create this pass may attempt at all — the cheap,
/// id-only half of the gate (§G).
///
/// * [attempted] — creates already tried this run. A create whose response
///   timed out after the server committed would otherwise be double-inserted
///   (orphan recovery only runs at the start of a run, not between passes).
/// * [unresolvedInflight] — a marker recovery that could NOT resolve still
///   means "this insert may already have landed"; that create waits for a run
///   with a complete remote view (H1).
/// * [held] — the one id the UI is actively holding. A create remaps a local id
///   to the server id, which would invalidate the id the UI holds, so that ONE
///   create waits. Every other create still pushes.
bool createIsEligible(
  String? pendingOp,
  String id,
  Set<String> attempted,
  Set<String> unresolvedInflight,
  String? held,
) =>
    pendingOp == 'create' &&
    !attempted.contains(id) &&
    !unresolvedInflight.contains(id) &&
    held != id;

/// Whether a pending update or delete may be pushed at all (§B/§D × §G).
///
/// A row whose CREATE is still unresolved in flight has no server id yet, and
/// naming its local UUID in a request is a permanent 400 ("Invalid task ID",
/// verified live). Worse, its insert MAY have committed: pushing the delete now
/// would report success against an id Google never minted while the row it
/// really created lives on, to be pulled back as a duplicate. Both mutations
/// wait for the run that resolves the marker.
bool mutationIsPushable(String id, Set<String> unresolvedInflight) =>
    !unresolvedInflight.contains(id);

/// Whether a create's parent is resolved enough to name in the insert (§G).
/// `null` is a top-level create — no constraint. A still-local parent id draws a
/// permanent 400 from Google ("Invalid task ID", verified live), so the child
/// waits; `finishCreate` rewrites its parent id once the parent lands.
bool parentIsPushable(RefState? parent) =>
    parent == null || parent == RefState.synced;

/// For a SUBTASK, the already-synced sibling to anchor the insert after. Without
/// a `previous` the API inserts at the top, so a batch of subtasks would land on
/// Google in reverse creation order. `null` for a top-level create.
String? createPreviousAnchor(StoredTask row, List<StoredTask> listRows) {
  final parent = row.task.parent;
  if (parent == null) return null;
  StoredTask? best;
  for (final t in listRows) {
    if (t.task.parent == parent &&
        t.task.id != row.task.id &&
        t.task.etag != null) {
      if (best == null || t.task.position.compareTo(best.task.position) > 0) {
        best = t;
      }
    }
  }
  return best?.task.id;
}

/// The insert payload for a create. [due] is canonicalized on the way out:
/// Google 400s a bare date, and this heals any legacy/imported row that stored a
/// non-canonical form.
NewTask createPayload(StoredTask row, String? previous) => NewTask(
  title: row.task.title,
  notes: row.task.notes,
  due: row.task.due == null ? null : normalizeDue(row.task.due!),
  status: row.task.status,
  parent: row.task.parent,
  previous: previous,
);

/// What a failed create push does to the in-flight marker (§G).
sealed class CreateFailure {
  const CreateFailure();
}

/// Transient: the insert may or may not have reached the server. KEEP the
/// marker so the next run can adopt an orphan instead of duplicating.
final class KeepInflight extends CreateFailure {
  const KeepInflight();

  @override
  bool operator ==(Object other) => other is KeepInflight;

  @override
  int get hashCode => (KeepInflight).hashCode;
}

/// The insert definitively did not land — clear the marker, then handle the
/// failure normally.
final class ClearInflight extends CreateFailure {
  const ClearInflight(this.failure);

  /// The classified push failure to handle after clearing the marker.
  final PushFailure failure;

  @override
  bool operator ==(Object other) =>
      other is ClearInflight && other.failure == failure;

  @override
  int get hashCode => Object.hash(ClearInflight, failure);
}

/// Decide what a create push's error means (§G).
CreateFailure onCreateError(ApiError e) =>
    e.isTransient ? const KeepInflight() : ClearInflight(pushFailure(e));

/// The remote task an interrupted create already committed, if any: our content
/// under an id we never recorded, under the SAME parent we named (#145). Scoped
/// to the in-flight row, so it never merges unrelated same-title tasks (legal).
Task? findOrphan(Task local, List<Task> remote, Set<String> knownLocalIds) {
  for (final r in remote) {
    if (!knownLocalIds.contains(r.id) &&
        r.parent == local.parent &&
        sameContent(local, r)) {
      return r;
    }
  }
  return null;
}

/// Like [findOrphan] but matches on the create's **base snapshot** — the insert
/// payload as it was actually sent — instead of the row's current content
/// (RFC-009 §G, #122). An edit made during the in-flight window mutates the
/// local row but never the base, so adoption still recognizes the committed
/// server row; without this the drifted content misses and the create is
/// retried, duplicating the task.
///
/// [parent] is the remote parent id our insert named (`null` = top-level); the
/// orphan must sit under it (#145). A SUBTASK's committed row also tolerates the
/// one status coercion Google applies on insert that the payload cannot predict:
/// a subtask inserted under a completed parent is stored **already completed**
/// (RFC-009 §G, probe) — so a completed remote under our parent is still our
/// child (status need not match). Everything the user typed always must match.
/// For a top-level create status stays strict.
Task? findOrphanByBase(
  BaseSnapshot base,
  String? parent,
  List<Task> remote,
  Set<String> knownLocalIds,
) {
  for (final r in remote) {
    if (!knownLocalIds.contains(r.id) && _baseMatchesCreate(base, parent, r)) {
      return r;
    }
  }
  return null;
}

/// A create's base against a committed remote row (see [findOrphanByBase]).
/// PARENT identity must match (#145). Typed content (title/notes/due) always
/// must match; status must match unless the subtask completion cascade explains
/// a completed remote.
bool _baseMatchesCreate(BaseSnapshot base, String? parent, Task r) {
  String? due(String? d) => d == null ? null : normalizeDue(d);
  String? notes(String? n) => (n == null || n.isEmpty) ? null : n;
  return r.parent == parent &&
      base.title == r.title &&
      notes(base.notes) == notes(r.notes) &&
      due(base.due) == due(r.due) &&
      (base.status == r.status ||
          (parent != null && r.status == TaskStatus.completed));
}

// ─── Content comparison ──────────────────────────────────────────────────────

/// Whether two tasks have identical user-visible content (the patchable
/// fields). Used to tell a real conflict from an identical concurrent edit, and
/// to adopt an orphaned create after a crash. Covers exactly title, notes, due,
/// status — never position, parent, or etag (P3), so a remote *move* never
/// manufactures a conflicted copy.
///
/// Comparison is normalization-tolerant, because Google canonicalizes what we
/// send: `due` always comes back as `YYYY-MM-DDT00:00:00.000Z`, and cleared
/// notes come back absent (`null` ≡ `""`). A raw string comparison here
/// manufactures phantom conflicts.
bool sameContent(Task a, Task b) =>
    sameTypedContent(a, b) && a.status == b.status;

/// On a `412`, whether the server left the TYPED content (title/notes/due)
/// unchanged relative to our base snapshot (RFC-009 §B × moved-while-edited,
/// #118). True means the etag bumped for a reason that did not touch what the
/// user typed — a bare reorder, or a status cascade — so the server never
/// diverged from us on content. Status is deliberately EXCLUDED: the
/// completed-parent cascade coerces status on both sides, so comparing it would
/// read that shared coercion as a remote divergence.
bool onlyLocalDiverged(Task remote, BaseSnapshot base) {
  String? due(String? d) => d == null ? null : normalizeDue(d);
  String? notes(String? n) => (n == null || n.isEmpty) ? null : n;
  return base.title == remote.title &&
      notes(base.notes) == notes(remote.notes) &&
      due(base.due) == due(remote.due);
}

/// Whether two tasks agree on everything the user *typed* — title, notes, due —
/// ignoring the checkbox. This is the divergence test for conflict resolution
/// (RFC-009 D1): a status-only difference is not worth a duplicate task. Same
/// normalization tolerance as [sameContent].
bool sameTypedContent(Task a, Task b) {
  String? due(Task t) => t.due == null ? null : normalizeDue(t.due!);
  String? notes(Task t) =>
      (t.notes == null || t.notes!.isEmpty) ? null : t.notes;
  return a.title == b.title && notes(a) == notes(b) && due(a) == due(b);
}
