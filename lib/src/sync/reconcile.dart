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
// This file is built in two migration steps. T5.3 landed the push-side half:
// the shared failure classification plus §B/§C (content update), §D (delete)
// and §G (create). T5.4 appends §E/§F (moves), §I (lists), §G3/D2 (re-home)
// and §A (pull). Section markers (§B, §D, …) refer to the matrix in
// `designs/RFC-009-sync-conflict-matrix.md` in the reference repo.
//
// Pure Dart: no Flutter dependency, fully unit-testable.

import '../api/api_error.dart';
import '../model/base_snapshot.dart';
import '../model/dates.dart' show normalizeDue;
import '../model/task.dart';
import '../model/task_list.dart';
import '../store/stored.dart';

// ─── Shared vocabulary ───────────────────────────────────────────────────────

/// How far along the push pipeline a task referenced by a pending intent is.
/// Every row's own id is a local UUID the server has never seen (#224); only a
/// row that has LEARNED a `remote_id` can be named in a request at all —
/// naming anything else draws a permanent 400 ("Invalid task ID", verified
/// live).
enum RefState {
  /// No such row locally (deleted, or never existed).
  missing,

  /// Present locally but never acknowledged by the server — there is no remote
  /// id to send.
  local,

  /// Present and acknowledged: it carries a `remote_id`, so it is nameable.
  synced;

  /// Classify a referenced row as the store returned it.
  static RefState of(StoredTask? row) {
    if (row == null) return RefState.missing;
    return row.remoteId != null ? RefState.synced : RefState.local;
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
/// * [remoteId] — Google's id for the row. A row that has one is already on the
///   server, so its push is an update however the queue is labelled
///   ([effectivePendingOp]).
/// * [attempted] — creates already tried this run. A create whose response
///   timed out after the server committed would otherwise be double-inserted
///   (orphan recovery only runs at the start of a run, not between passes).
/// * [unresolvedInflight] — a marker recovery that could NOT resolve still
///   means "this insert may already have landed"; that create waits for a run
///   with a complete remote view (H1).
bool createIsEligible(
  String? pendingOp,
  String? remoteId,
  String id,
  Set<String> attempted,
  Set<String> unresolvedInflight,
) =>
    effectivePendingOp(pendingOp, remoteId) == 'create' &&
    !attempted.contains(id) &&
    !unresolvedInflight.contains(id);

/// The push op a dirty row really needs, read against what the server already
/// knows about it (#269).
///
/// A queued `create` on a row that already carries a `remote_id` is a
/// contradiction: Google minted that id, so the row EXISTS there and inserting
/// it again would put a duplicate on the user's account, which the follow-up
/// patch would then quietly edit. What the queue means in that state is "this
/// row has unpushed content" — against an acknowledged row, that is a PATCH.
///
/// [Store.upsertTask] keeps the state from being written at all; this is the
/// engine's half of the same invariant, so a row that reaches the push queue in
/// that shape converges instead of duplicating.
String? effectivePendingOp(String? pendingOp, String? remoteId) =>
    (pendingOp == 'create' && remoteId != null) ? 'update' : pendingOp;

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

/// For a SUBTASK, the REMOTE id of the already-synced sibling to anchor the
/// insert after. Without a `previous` the API inserts at the top, so a batch of
/// subtasks would land on Google in reverse creation order. `null` for a
/// top-level create (or when no sibling has a remote id yet). The value is a
/// wire parameter, so it is the sibling's `remote_id`, never its local id.
String? createPreviousAnchor(StoredTask row, List<StoredTask> listRows) {
  final parent = row.task.parent;
  if (parent == null) return null;
  StoredTask? best;
  for (final t in listRows) {
    if (t.task.parent == parent &&
        t.task.id != row.task.id &&
        t.remoteId != null) {
      if (best == null || t.task.position.compareTo(best.task.position) > 0) {
        best = t;
      }
    }
  }
  return best?.remoteId;
}

/// The insert payload for a create. [due] is canonicalized on the way out:
/// Google 400s a bare date, and this heals any legacy/imported row that stored a
/// non-canonical form.
///
/// [parent] and [previous] are WIRE ids (the referenced rows' `remote_id`), not
/// the local ids the row itself carries — the caller translates them at the API
/// boundary (#224). A subtask create is only ever attempted once its parent has
/// a remote id ([parentIsPushable]).
NewTask createPayload(StoredTask row, String? previous, String? parent) =>
    NewTask(
      title: row.task.title,
      notes: row.task.notes,
      due: row.task.due == null ? null : normalizeDue(row.task.due!),
      status: row.task.status,
      parent: parent,
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

// ─── §E/§F — position and parent moves ───────────────────────────────────────

/// The ids a pending move references, as the store currently sees them.
class MoveRefs {
  const MoveRefs({
    required this.task,
    this.parent,
    this.previous,
    this.taskHasChildren = false,
    this.parentIsSubtask = false,
  });

  /// The task being moved.
  final RefState task;

  /// The target parent; `null` when the move names none (top-level).
  final RefState? parent;

  /// The sibling the task should follow; `null` when the move names none.
  final RefState? previous;

  /// Whether the moved task currently has subtasks of its own. Only matters
  /// for a demote: its children would land a third level down.
  final bool taskHasChildren;

  /// Whether the target parent is itself a subtask — the mirror case of the
  /// same third level.
  final bool parentIsSubtask;
}

/// What to do with a pending move before calling the API (§E, §F).
sealed class MoveIntent {
  const MoveIntent();
}

/// Send it. [keepPrevious] false means the ordering half was dropped and only
/// the reparent is sent.
final class MoveSend extends MoveIntent {
  const MoveSend({required this.keepPrevious});

  /// Whether the `previous` sibling is still expressible.
  final bool keepPrevious;

  @override
  bool operator ==(Object other) =>
      other is MoveSend && other.keepPrevious == keepPrevious;

  @override
  int get hashCode => Object.hash(MoveSend, keepPrevious);
}

/// Nothing left to express — clear the intent so it stops being re-walked (and
/// stops inflating the pending-changes count the UI shows).
final class MoveDrop extends MoveIntent {
  const MoveDrop();

  @override
  bool operator ==(Object other) => other is MoveDrop;

  @override
  int get hashCode => (MoveDrop).hashCode;
}

/// The move would nest the task a third level deep (invariant #1). Clear the
/// intent WITHOUT calling the API: the server would accept it (probe 3: there
/// is no depth cap, the move returns 200), and the grandchild it would store is
/// a row no list view can render. The pull that follows restores the remote
/// parent on the row, so local converges too.
final class MoveRefuse extends MoveIntent {
  const MoveRefuse();

  @override
  bool operator ==(Object other) => other is MoveRefuse;

  @override
  int get hashCode => (MoveRefuse).hashCode;
}

/// The ids aren't on the server yet — keep the intent and try next run.
final class MoveWait extends MoveIntent {
  const MoveWait();

  @override
  bool operator ==(Object other) => other is MoveWait;

  @override
  int get hashCode => (MoveWait).hashCode;
}

/// Plan a pending move against the current local view of the ids it names
/// (§E, §F). Moves degrade, never wedge (P5).
MoveIntent planMove(MoveRefs refs) {
  // The TARGET PARENT is gone (the user deleted it after dropping this task
  // under it). Its delete cascades to the whole subtree on both sides (verified
  // live), so this task goes with it: there is nothing left to express, and
  // Google would answer 400 "Invalid task ID" for the dead parent (verified
  // live). The synced-yet check below can never pass for a row that no longer
  // exists, so the intent would otherwise survive forever.
  if (refs.parent == RefState.missing) return const MoveDrop();
  // A DEMOTE that would produce a third level (invariant #1) — either the task
  // already has subtasks, or the target parent is itself a subtask. Google does
  // NOT cap nesting depth: the move is accepted with 200 and the grandchild is
  // stored (probe 3, which falsified the earlier "the server rejects it"
  // claim). So the refusal has to happen here. A demote is only ever *recorded*
  // against a childless task, but a pull can hand that task a remote-born
  // subtask before the move is pushed.
  if (refs.parent != null && (refs.taskHasChildren || refs.parentIsSubtask)) {
    return const MoveRefuse();
  }
  // The SIBLING this task was dropped after is gone. One drag can carry two
  // intents — reparent and ordering — and the row already applied both
  // optimistically. "Place after B" is unexpressible now, but the reparent
  // still is, so dropping the whole intent would strand it: local would show
  // the task at its new parent while Google keeps the old one, and because the
  // row is Clean with a matching etag no later pull ever corrects the drift.
  // Keep the parent, drop only the ordering — position self-heals on the next
  // pull.
  final keepPrevious =
      refs.previous != null && refs.previous != RefState.missing;
  // A move whose task (or target parent/previous) hasn't been pushed yet still
  // carries a local UUID — the API answers 400 "Invalid task ID" (verified
  // live), which would drop the user's reordering. Hold the intent;
  // finishCreate rewrites the ids when the create lands.
  bool unsynced(RefState? r) => r != null && r != RefState.synced;
  if (refs.task != RefState.synced ||
      unsynced(refs.parent) ||
      (keepPrevious && unsynced(refs.previous))) {
    return const MoveWait();
  }
  return MoveSend(keepPrevious: keepPrevious);
}

/// The `previous` id to send for a planned move, given the stored intent.
String? movePreviousId(PendingMove mv, MoveIntent intent) =>
    intent is MoveSend && intent.keepPrevious ? mv.previousId : null;

/// How much of a successful move response is adopted (§E).
enum MoveAdoption {
  /// Adopt the response BODY, not just the etag — the same trap `update`
  /// documents. A move can change more than parent/position: completing a
  /// parent cascades to its subtree server-side (verified live), so a task
  /// moved OUT of a parent completed in the same batch comes back completed.
  /// The fresh etag the move returns would otherwise make every later pull skip
  /// the row and freeze that drift in place (P6).
  body,

  /// The row carries its own pending content edit: keep it (meta only). Its
  /// update push adopts the server body on this run or the next.
  metaOnly,
}

/// Decide how much of a move response to adopt, from the row snapshot taken
/// *before* the call (so a mid-flight re-edit stays dirty).
MoveAdoption moveAdoption(StoredTask? before) =>
    before != null && before.syncState == SyncState.clean
    ? MoveAdoption.body
    : MoveAdoption.metaOnly;

/// What a failed move push does (§E, §F).
enum MoveFailure {
  /// `404` on a move that named a `previous` sibling. The status is
  /// **ambiguous**: the server answers 404 both for "Previous task id not
  /// found" (probe 2, verified live) and for a subject it no longer has.
  /// Reading it as "the task is gone" throws away a reparent the server would
  /// have accepted — the user's demote silently reverts. Resolve the ambiguity
  /// by experiment: drop the ordering half (P5's ladder) and send the reparent
  /// alone. If THAT 404s, the subject really is gone.
  dropPreviousAndRetry,

  /// `404`: the task is gone on the server — drop the stale intent.
  dropIntent,

  /// Transient — keep the intent and retry next run.
  retry,

  /// Auth is dead — abort the run, leaving the intent pending.
  abort,

  /// Rejected. A rejected move must not starve the rest of the queue: count it
  /// and drop the intent (positions self-heal on the next pull).
  rejectAndDrop,
}

/// Decide what a move push's error means (§E, §F). [sentPrevious] says whether
/// the call that failed named a `previous` sibling — the only thing that makes
/// a 404 ambiguous ([MoveFailure.dropPreviousAndRetry]).
MoveFailure onMoveError(ApiError e, bool sentPrevious) {
  if (e is NotFound) {
    return sentPrevious
        ? MoveFailure.dropPreviousAndRetry
        : MoveFailure.dropIntent;
  }
  return switch (pushFailure(e)) {
    PushFailure.retry => MoveFailure.retry,
    PushFailure.abort => MoveFailure.abort,
    PushFailure.reject => MoveFailure.rejectAndDrop,
  };
}

// ─── §I — list operations ────────────────────────────────────────────────────

/// A remote list a local list-create should adopt instead of inserting a
/// duplicate — same title, and whose id we do not already map to a local row
/// (§I). Covers the default "My Tasks" bootstrap and any create that already
/// landed. [trackedRemoteIds] is the set of `remote_id`s the store already
/// holds.
TaskList? adoptableList(
  String title,
  List<TaskList> remote,
  Set<String> trackedRemoteIds,
) {
  for (final r in remote) {
    if (r.title == title && !trackedRemoteIds.contains(r.id)) return r;
  }
  return null;
}

/// What a failed list rename does (§I).
sealed class ListRenameFailure {
  const ListRenameFailure();
}

/// `404`: the list is gone on the server — hard-delete it locally (P4).
final class ListRenameDeleteLocal extends ListRenameFailure {
  const ListRenameDeleteLocal();

  @override
  bool operator ==(Object other) => other is ListRenameDeleteLocal;

  @override
  int get hashCode => (ListRenameDeleteLocal).hashCode;
}

/// Generic row-push failure handling.
final class ListRenameFailed extends ListRenameFailure {
  const ListRenameFailed(this.failure);

  /// The classified push failure.
  final PushFailure failure;

  @override
  bool operator ==(Object other) =>
      other is ListRenameFailed && other.failure == failure;

  @override
  int get hashCode => Object.hash(ListRenameFailed, failure);
}

/// Decide what a list rename's error means (§I).
ListRenameFailure onListRenameError(ApiError e) => e is NotFound
    ? const ListRenameDeleteLocal()
    : ListRenameFailed(pushFailure(e));

/// What a list delete push does (§I).
enum ListDeleteAction {
  /// Hard-delete locally; a remote `404` counts as success.
  deleteLocal,

  /// Transient — keep the tombstone and retry next run.
  retry,

  /// Auth is dead — abort the run, leaving the tombstone.
  abort,

  /// Permanently refused — Google will not delete an account's default list,
  /// for example. A tombstone that can never push would error on every run
  /// forever; revive the list instead (its tasks re-pull) and tell the user via
  /// the error count.
  revive,
}

/// Decide what a list delete's answer means (§I); `null` is a success.
ListDeleteAction planListDelete(ApiError? error) {
  if (error == null || error is NotFound) return ListDeleteAction.deleteLocal;
  return switch (pushFailure(error)) {
    PushFailure.retry => ListDeleteAction.retry,
    PushFailure.abort => ListDeleteAction.abort,
    PushFailure.reject => ListDeleteAction.revive,
  };
}

// ─── §G3 — a remotely-deleted list holding unpushed rows (D2) ────────────────

/// The title Google gives an account's default list, and the title the app's
/// own offline bootstrap uses. Preferring it makes the re-home target the list
/// the user thinks of as home whenever one exists.
const String _defaultListTitle = 'My Tasks';

/// Where the unpushed rows of a remotely-deleted list go (§G3, D2 — ratified).
///
/// A row the server has never seen must not die with a list the server deleted
/// (P2), so it re-homes to the **default list**: the surviving list titled "My
/// Tasks" if there is one, otherwise the alphabetically first, tied by id so the
/// choice is deterministic. Candidates exclude the dying list itself, lists the
/// user has tombstoned (they would take the rows down again) and local-only
/// lists (they never push, so a re-homed create would never sync). `null` means
/// there is nowhere to put them — the caller keeps the list alive instead.
StoredTaskList? rehomeTarget(List<StoredTaskList> lists, String dyingListId) {
  StoredTaskList? best;
  ({bool notDefault, String title, String id})? bestKey;
  for (final l in lists) {
    if (l.list.id == dyingListId ||
        l.localOnly ||
        l.syncState == SyncState.deleted) {
      continue;
    }
    final key = (
      notDefault: l.list.title != _defaultListTitle,
      title: l.list.title,
      id: l.list.id,
    );
    if (bestKey == null || _rehomeKeyLess(key, bestKey)) {
      best = l;
      bestKey = key;
    }
  }
  return best;
}

/// Lexicographic ordering for the re-home key `(notDefault, title, id)`, so the
/// default list wins, then the alphabetically-first title, ties broken by id.
bool _rehomeKeyLess(
  ({bool notDefault, String title, String id}) a,
  ({bool notDefault, String title, String id}) b,
) {
  if (a.notDefault != b.notDefault) return !a.notDefault;
  final byTitle = a.title.compareTo(b.title);
  if (byTitle != 0) return byTitle < 0;
  return a.id.compareTo(b.id) < 0;
}

// ─── §A — pull ───────────────────────────────────────────────────────────────

/// An in-flight create the pull must not front-run: its base snapshot (the
/// payload as sent) plus the remote parent id it was inserted under. Matching on
/// the base — not the row's live content — means an edit made during the
/// in-flight window (#122) still recognizes the committed orphan, and the parent
/// id lets the match tolerate the completed-parent cascade (RFC-009 §G).
class InflightBase {
  const InflightBase({required this.base, this.parent});

  /// The create's base snapshot (payload as sent).
  final BaseSnapshot base;

  /// The LOCAL parent id the row names, used to detect the completed-parent
  /// cascade. Remote rows are translated into local-id space before they are
  /// matched against it (#224).
  final String? parent;
}

/// The rows of one remote list that are candidates for upsert, in FK-safe order
/// (§A). Dirty rows keep their local intent (push handles them), and a remote
/// row matching an in-flight create by its BASE snapshot is left for
/// `recoverInflightCreates` to adopt via id remap — pulling it as a new clean
/// row would duplicate it (or collide on the primary key). Matching on the base
/// (not the live row) makes this robust to an edit during the in-flight window
/// (#122) and to the completed-parent status cascade (RFC-009 §G), exactly like
/// recovery's [findOrphanByBase].
List<Task> pullBatch(
  List<Task> remote,
  Set<String> dirtyIds,
  List<InflightBase> inflight,
) {
  final filtered = <Task>[];
  for (final t in remote) {
    if (dirtyIds.contains(t.id)) continue;
    if (inflight.any((f) => _baseMatchesCreate(f.base, f.parent, t))) continue;
    filtered.add(t);
  }
  return orderParentsFirst(filtered);
}

/// Everything [planPullRow] needs to judge one pulled row.
class PullRowContext {
  const PullRowContext({
    required this.localEtags,
    required this.batchIds,
    required this.knownLocal,
  });

  /// Local `task_id → etag` for the list being pulled.
  final Map<String, String?> localEtags;

  /// Ids of the batch currently being upserted.
  final Set<String> batchIds;

  /// Ids already present locally in this list.
  final Set<String> knownLocal;
}

/// What a pulled remote row does to the local store (§A).
enum PullRowAction {
  /// Local already carries this etag — nothing to do.
  skip,

  /// Upsert as a clean row.
  upsert,

  /// Upsert, but detached from its parent and with the etag dropped. A parent
  /// that is neither in this batch nor already local (its row was skipped as
  /// dirty/in-flight, or it moved mid-pagination) would fail the FK and abort
  /// the whole pull. Dropping the etag keeps the row from being etag-skipped
  /// next pull, so it re-links once the parent appears.
  upsertDetached,
}

/// Decide what to do with one pulled row (§A).
PullRowAction planPullRow(Task task, PullRowContext ctx) {
  if (isUpToDate(task.id, task.etag, ctx.localEtags)) return PullRowAction.skip;
  final parent = task.parent;
  if (parent != null &&
      !ctx.batchIds.contains(parent) &&
      !ctx.knownLocal.contains(parent)) {
    return PullRowAction.upsertDetached;
  }
  return PullRowAction.upsert;
}

/// Ids of the local rows that sit a third level deep — a grandchild, i.e. a row
/// whose parent is a **clean** subtask (RFC-009 §F/§G, D7 **ratified**).
///
/// Google does not cap nesting depth (probe 3: a `move` that deepens the tree
/// returns 200), so invariant #1 (subtasks are strictly one level) is ours to
/// enforce client-side. Two vectors reach the server-side third level and no
/// push-side guard can close either — the demote is unseen until the pull:
///   * §F residual — a remote-born subtask arrives *after* our demote already
///     landed, so the server holds `P > T > C` we never asked for; and
///   * §G — our own queued subtask create races a remote demote of its parent,
///     so the create lands (or is still queued) under a row the server has since
///     made a subtask.
///
/// The pull is the one place with the full server picture, so D7 promotes each
/// grandchild to top-level and, for a synced row, pushes the corrective move.
///
/// Detects over the LOCAL store after the pull's upsert, not the fetched batch:
/// a paged pull can land a middle row's demotion (`T` gains parent `P`) while
/// the grandchild `C` sits on a page a transient error dropped — so `C` never
/// appears in this batch, yet it is a third level the moment `T`'s demotion is
/// stored. The local store is the only place that sees the whole chain.
///
/// The **clean-middle guard** is what makes local detection safe: the PARENT
/// (`T`) must be `Clean`. A clean parent link is server-confirmed, so a row that
/// looks nested purely because of an un-pushed optimistic demote of the middle
/// (a refused move that stayed put while `T` was dirty) is never mistaken for a
/// real third level and never triggers a bogus repair. The grandchild `C` itself
/// may be in any state — clean, a pending edit, or a still-queued create under a
/// just-demoted parent (§G) — because that only changes HOW it is promoted, not
/// WHETHER it is a third level.
///
/// Structural only — no IO. Promoting exactly these ids to top-level heals any
/// tree to at most one level: a great-grandchild `D` under a promoted `C`
/// becomes a legal one-level subtask once `C` is top-level.
List<String> thirdLevelIds(List<StoredTask> rows) {
  final byId = {for (final r in rows) r.task.id: r};
  final out = <String>[];
  for (final r in rows) {
    final parentId = r.task.parent;
    if (parentId == null) continue;
    final parent = byId[parentId];
    if (parent != null &&
        parent.syncState == SyncState.clean &&
        parent.task.parent != null) {
      out.add(r.task.id);
    }
  }
  return out;
}

/// Whether a remote task is already up to date locally.
bool isUpToDate(
  String id,
  String? remoteEtag,
  Map<String, String?> localEtags,
) {
  if (!localEtags.containsKey(id)) return false;
  final local = localEtags[id];
  return local != null && remoteEtag != null && local == remoteEtag;
}

/// Order [tasks] so every parent precedes its children (FK-safe upsert order),
/// at any depth. A parent whose id is not in the batch places immediately; a
/// cycle (no row can ever place) is appended rather than dropped, so no row is
/// ever silently lost.
List<Task> orderParentsFirst(List<Task> tasks) {
  final inBatch = {for (final t in tasks) t.id};
  final remaining = List<Task?>.from(tasks);
  final placed = <String>{};
  final out = <Task>[];
  while (true) {
    var progressed = false;
    for (var i = 0; i < remaining.length; i++) {
      final t = remaining[i];
      if (t == null) continue;
      final parent = t.parent;
      final ready =
          parent == null ||
          !inBatch.contains(parent) ||
          placed.contains(parent);
      if (ready) {
        placed.add(t.id);
        out.add(t);
        remaining[i] = null;
        progressed = true;
      }
    }
    if (!progressed) break;
  }
  for (final t in remaining) {
    if (t != null) out.add(t);
  }
  return out;
}

/// What a pulled remote list does to the local store (§A, §I).
sealed class ListPullAction {
  const ListPullAction();
}

/// A locally dirty list with the same id — preserve local intent (push will
/// handle it).
final class ListPullKeepLocal extends ListPullAction {
  const ListPullKeepLocal();

  @override
  bool operator ==(Object other) => other is ListPullKeepLocal;

  @override
  int get hashCode => (ListPullKeepLocal).hashCode;
}

/// Adopt an un-acknowledged local create (no `remote_id`) with the same title
/// by teaching it the remote id — covers the offline "My Tasks" bootstrap and
/// any create that already landed. The local row keeps its own id (#224).
final class ListPullAdoptLocalCreate extends ListPullAction {
  const ListPullAdoptLocalCreate(this.localId);

  /// The local id of the row that adopts the remote list.
  final String localId;

  @override
  bool operator ==(Object other) =>
      other is ListPullAdoptLocalCreate && other.localId == localId;

  @override
  int get hashCode => Object.hash(ListPullAdoptLocalCreate, localId);
}

/// Upsert the remote list. [changed] reports whether anything the UI shows
/// actually differs from what is stored.
final class ListPullUpsert extends ListPullAction {
  const ListPullUpsert({required this.changed});

  /// Whether this upsert changes locally-visible list metadata.
  final bool changed;

  @override
  bool operator ==(Object other) =>
      other is ListPullUpsert && other.changed == changed;

  @override
  int get hashCode => Object.hash(ListPullUpsert, changed);
}

/// Decide how one remote list reconciles into the local store (§A, §I).
ListPullAction planListPull(TaskList remote, List<StoredTaskList> locals) {
  if (locals.any(
    (l) => l.list.id == remote.id && l.syncState != SyncState.clean,
  )) {
    return const ListPullKeepLocal();
  }

  for (final l in locals) {
    if (l.pendingOp == 'create' &&
        l.remoteId == null &&
        l.list.title == remote.title) {
      return ListPullAdoptLocalCreate(l.list.id);
    }
  }

  // Lists are deliberately NOT etag-skipped like tasks: the title itself is
  // compared, so a server-side rename always lands (§I / D6, remote-wins) even
  // if the etag and `updated` are byte-identical to what we hold.
  final changed = !locals.any(
    (l) =>
        l.list.id == remote.id &&
        l.list.title == remote.title &&
        l.list.etag == remote.etag &&
        l.list.updated == remote.updated &&
        !l.localOnly &&
        l.syncState == SyncState.clean,
  );
  return ListPullUpsert(changed: changed);
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
