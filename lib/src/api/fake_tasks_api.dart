// Deterministic in-memory implementation of [TasksApi] — the Dart port of
// `api/in_memory.rs`, PART 1 (T3.2): the CRUD semantics used as a test double
// for the sync engine and command handlers. Etags are a monotonic counter so
// conflict scenarios are deterministic.
//
// The fake models the REAL Google Tasks API's strictness, verified against the
// live service (RFC-009) — a permissive fake lets the whole test suite pass
// while production sync is broken:
//  - `due` must be a full RFC-3339 timestamp; a bare `YYYY-MM-DD` is a permanent
//    400. Accepted values normalize to `YYYY-MM-DDT00:00:00.000Z`. `""` clears.
//  - `title` over 1024 chars or `notes` over 8192 chars is a permanent 400
//    ("invalid argument") on both insert and patch — Google counts CHARACTERS,
//    not bytes. An empty title, by contrast, is a valid untitled task.
//  - inserting under a nonexistent (or soft-deleted) `parent` is a permanent
//    400 — the same rule the engine's forever-`Reject` push path keys off.
//  - deleting a parent soft-deletes its whole descendant subtree server-side.
//  - completing a parent auto-completes its whole subtree server-side, each
//    descendant getting a fresh etag + completed stamp; re-opening a subtask
//    whose parent is still completed returns 200 but is silently ignored, and
//    re-opening the parent does NOT reopen its children.
//  - inserting a child does NOT bump the parent's etag, so a complete pushed
//    with a pre-child etag lands and the cascade takes children never pulled.
//  - attaching an open task to a COMPLETED parent (by `insert` with a `parent`)
//    completes it: the response body itself already carries `completed`.
//  - **every task endpoint is addressed by the (list, task) PAIR** — the live
//    URL is `/lists/{tasklist}/tasks/{task}`. An unknown list is a 404 on
//    `list_tasks` (never an empty page), and an id that belongs to ANOTHER list
//    is unaddressable from this one: 404 on get/patch/delete, and the same 400
//    an unknown SUBJECT id draws on move. `parent` and `previous` are read in
//    the same scope — `previous` must be a real SIBLING (same list AND same
//    parent), or it is the verified 404.
//  - **every mutation moves `updated`**, alongside the fresh etag: patch, move,
//    a cascaded completion, and a list rename.
//
//  - **Soft delete.** Google soft-deletes: a `DELETE` moves the row (and its
//    cascade subtree) into a `deleted` set instead of dropping it. A direct
//    `get` still returns 200 (carrying `deleted: true` on the wire), a later
//    `patch` returns 200 but is silently ignored (the row stays deleted, and —
//    key for P4 — does NOT 412 on a stale etag), and the row is absent from
//    `list_tasks`. The engine converges §B×deleted through ghost detection on
//    the pull, exactly as live (RFC-009 #106).
//
// Deliberate divergence, recorded so nobody "fixes" the fake into a fiction:
// live `DELETE` honors `If-Match` (stale etag → 412), but [HttpTasksApi] sends
// none — making our deletes unconditional (RFC-009 P4, "delete wins") — so the
// trait (and the fake) has no etag parameter on delete.
//
// T3.3 adds the remainder — positioning ordering, `move`, real pagination, and
// the full fault-injection surface: untargeted FIFO faults, per-id and per-page
// targeted faults, `commit_then_fail` lost-response faults, the `on_call`
// interleave hook, `clear_faults`, and per-method call counting. Together
// T3.2+T3.3 cover the entire `in_memory.rs` inventory.
//
// Faults, call counting, and the on_call hook are wired into EVERY trait method
// uniformly (fire the hook, record the call, check faults) so the fake behaves
// exactly like the reference no matter which operation a test exercises.

import 'dart:async';

import '../model/dates.dart';
import '../model/page.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'api_error.dart';
import 'tasks_api.dart';

/// Per-method fault-injection key, and the argument to the [FakeTasksApi.callCount]
/// counter and the [FakeTasksApi.setOnCall] hook.
enum Method {
  listTasklists,
  insertTasklist,
  patchTasklist,
  deleteTasklist,
  listTasks,
  insertTask,
  getTask,
  patchTask,
  deleteTask,
  moveTask,
}

/// The documented live-API field-size limits (Google Tasks docs, verified
/// 2026-07-28): `title` ≤ 1024 characters, `notes` ≤ 8192 characters. Either
/// overflow is a permanent 400.
const int _maxTitleChars = 1024;
const int _maxNotesChars = 8192;

/// The server-side completion timestamp the fake stamps on completed rows —
/// deterministic so cascade tests can assert an exact value.
const String _completedStamp = '2026-01-01T00:00:00Z';

/// The seeded/created `updated` timestamp — deterministic like the reference.
/// Mutations advance from here (see [FakeTasksApi._freshUpdated]).
const String _updatedStamp = '2026-01-01T00:00:00Z';

/// A stored row: which list it belongs to plus the task itself.
typedef _Row = ({String listId, Task task});

/// A fault scoped to a specific target — a single task [id] (matching a
/// single-task method invoked against it) or a 0-based `list_tasks` [page]
/// (matching that page mid-scroll). Exactly one of [id]/[page] is set. Fired the
/// first time a matching call is made and removed on fire; order-independent
/// (unlike the untargeted FIFO queue), so a test can arm "fail patch of T2"
/// without caring what else is patched first.
class _TargetedFault {
  const _TargetedFault({
    required this.method,
    this.id,
    this.page,
    required this.err,
  });

  final Method method;
  final String? id;
  final int? page;
  final ApiError Function() err;
}

/// The per-call interleave hook installed via [FakeTasksApi.setOnCall]: it fires
/// at the START of every [TasksApi] call on this fake, receiving the fake itself
/// and the [Method] about to run, BEFORE that call does any work. It exists to
/// interleave a mutation at a precise point inside one sync run — the engine
/// makes many calls per run, and the fault/`*FromState` helpers only mutate at
/// op boundaries. It fires with its own slot emptied, so a re-entrant call from
/// inside the hook does NOT re-fire it.
///
/// A synchronous hook drives the synchronous server-side helpers
/// ([FakeTasksApi.seedTaskIfListExists], [FakeTasksApi.deleteTaskFromState],
/// [FakeTasksApi.deleteListFromState]) — another device racing us. An ASYNC
/// hook is AWAITED before the call proceeds, which is what it takes to model
/// the other race: a LOCAL store edit (drift is async) landing while the app's
/// own request is in the air (#268). Awaiting it is what makes that
/// interleaving deterministic instead of a microtask coin-flip.
typedef OnCall = FutureOr<void> Function(FakeTasksApi client, Method method);

/// Deterministic in-memory [TasksApi] test double. Mirrors verified Google
/// Tasks semantics exactly (see the file header); never loosen it to make a
/// test pass.
class FakeTasksApi implements TasksApi {
  final List<TaskList> _lists = [];
  final List<_Row> _tasks = [];

  /// Soft-deleted rows, moved OUT of [_tasks] by a `delete`. A deleted row
  /// vanishes from `list_tasks` but a direct `get`/`patch` still reaches it.
  /// Keeping them separate means every internal query over [_tasks]
  /// (parent checks, cascades) naturally sees only live rows, exactly as live.
  final List<_Row> _deleted = [];

  int _etagCounter = 0;

  /// Untargeted faults, FIFO. Fired only when the FRONT of the queue names the
  /// invoked method (so an armed-but-not-at-front fault leaves other methods
  /// alone), then popped — exactly the reference's `VecDeque` semantics.
  final List<(Method, ApiError Function())> _faults = [];

  /// Faults scoped to a specific task id or `list_tasks` page.
  final List<_TargetedFault> _targetedFaults = [];

  /// Methods whose next call commits its mutation server-side and THEN returns a
  /// [Network] error — a response lost after the server already applied the
  /// change (the at-least-once hazard). Fired and consumed per method.
  final List<Method> _commitThenFail = [];

  /// `list_tasks` page size. `null` returns the whole list in one page; a value
  /// splits it into that-many-item pages with real `next_page_token`s.
  int? _pageSize;

  /// Lists whose deletion the account permanently refuses (see
  /// [setUndeletableList]).
  final Set<String> _undeletableLists = {};

  /// Per-method invocation counts. A faulted call still counts.
  final Map<Method, int> _calls = {};

  /// The optional per-call interleave hook; see [OnCall] and [setOnCall].
  OnCall? _onCall;

  String _freshEtag() {
    _etagCounter += 1;
    return 'etag-$_etagCounter';
  }

  /// The `updated` stamp of a row the server has just mutated: [_updatedStamp]
  /// advanced by the etag counter, so it is deterministic AND strictly later
  /// than the stamp the row carried before. Call [_freshEtag] first — the two
  /// advance together, exactly as they do live.
  String _freshUpdated() => DateTime.utc(2026)
      .add(Duration(seconds: _etagCounter))
      .toIso8601String()
      .replaceFirst('.000', '');

  // ── Fault / call-count / hook plumbing ──────────────────────────────────

  /// Record an invocation of [m] (counted even when the call then faults).
  void _record(Method m) => _calls[m] = (_calls[m] ?? 0) + 1;

  /// Pop and fire the untargeted fault at the FRONT of the queue iff it names
  /// [m]; otherwise leave the queue untouched and return `null`.
  ApiError? _nextFault(Method m) {
    if (_faults.isNotEmpty && _faults.first.$1 == m) {
      return _faults.removeAt(0).$2();
    }
    return null;
  }

  /// Fire and consume a targeted fault matching [m] against task [id], if any.
  ApiError? _nextFaultForId(Method m, String id) {
    final i = _targetedFaults.indexWhere((f) => f.method == m && f.id == id);
    if (i < 0) return null;
    return _targetedFaults.removeAt(i).err();
  }

  /// Fire and consume a targeted fault matching [m] against `list_tasks` [page],
  /// if any.
  ApiError? _nextFaultForPage(Method m, int page) {
    final i = _targetedFaults.indexWhere(
      (f) => f.method == m && f.page == page,
    );
    if (i < 0) return null;
    return _targetedFaults.removeAt(i).err();
  }

  /// Consume a pending commit-then-fail arming for [m], returning whether THIS
  /// call's response should be lost after its mutation already committed.
  bool _takeCommitThenFail(Method m) {
    final i = _commitThenFail.indexOf(m);
    if (i < 0) return false;
    _commitThenFail.removeAt(i);
    return true;
  }

  /// Fire the on_call hook (if armed) for [m], with the hook taken out of its
  /// slot while running so a re-entrant trait call from inside it neither
  /// recurses nor re-fires. Restored afterwards unless the hook itself replaced
  /// or cleared it. An async hook is awaited, so whatever it does has finished
  /// before the call it interleaves with does any work.
  Future<void> _fireOnCall(Method m) async {
    final hook = _onCall;
    if (hook == null) return;
    _onCall = null;
    await hook(this, m);
    _onCall ??= hook;
  }

  // ── Test-fixture seeding ────────────────────────────────────────────────

  /// Seed a task list. Returns the seeded list (etag/updated filled).
  TaskList seedList(String id, String title) {
    final list = TaskList(
      id: id,
      title: title,
      etag: _freshEtag(),
      updated: _updatedStamp,
    );
    _lists.add(list);
    return list;
  }

  /// Seed a top-level task. Caller controls id/position for determinism.
  Task seedTask(String listId, String id, String title, String position) =>
      seedTaskWithParent(listId, id, title, position, null);

  /// Seed a task with an optional parent. Used for hierarchy tests.
  Task seedTaskWithParent(
    String listId,
    String id,
    String title,
    String position,
    String? parent,
  ) {
    assert(
      _lists.any((l) => l.id == listId),
      'seedTask: list $listId not seeded',
    );
    final task = Task(
      id: id,
      parent: parent,
      position: position,
      title: title,
      status: TaskStatus.needsAction,
      etag: _freshEtag(),
      updated: _updatedStamp,
      webViewLink: 'https://tasks.google.com/task/$id',
    );
    _tasks.add((listId: listId, task: task));
    return task;
  }

  // ── Task lists ──────────────────────────────────────────────────────────

  @override
  Future<List<TaskList>> listTasklists() async {
    await _fireOnCall(Method.listTasklists);
    _record(Method.listTasklists);
    final fault = _nextFault(Method.listTasklists);
    if (fault != null) throw fault;
    return List.of(_lists);
  }

  @override
  Future<TaskList> insertTasklist(String title) async {
    await _fireOnCall(Method.insertTasklist);
    _record(Method.insertTasklist);
    final fault = _nextFault(Method.insertTasklist);
    if (fault != null) throw fault;
    final etag = _freshEtag();
    final list = TaskList(
      id: 'remote-list-$_etagCounter',
      title: title,
      etag: etag,
      updated: _updatedStamp,
    );
    _lists.add(list);
    return list;
  }

  @override
  Future<TaskList> patchTasklist(String id, String title) async {
    await _fireOnCall(Method.patchTasklist);
    _record(Method.patchTasklist);
    final fault = _nextFault(Method.patchTasklist);
    if (fault != null) throw fault;
    final i = _lists.indexWhere((l) => l.id == id);
    if (i < 0) throw const NotFound();
    final updated = TaskList(
      id: id,
      title: title,
      etag: _freshEtag(),
      updated: _freshUpdated(),
    );
    _lists[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteTasklist(String id) async {
    await _fireOnCall(Method.deleteTasklist);
    _record(Method.deleteTasklist);
    final fault = _nextFault(Method.deleteTasklist);
    if (fault != null) throw fault;
    if (_undeletableLists.contains(id)) {
      // Permanently refused, list and tasks intact — the shape
      // `reconcile.planListDelete` answers with `revive`.
      throw const OtherApiError('400: Cannot delete this task list');
    }
    final before = _lists.length;
    _lists.removeWhere((l) => l.id == id);
    if (_lists.length == before) throw const NotFound();
    // The server cascades: the list's tasks (and their tombstones) go too.
    _tasks.removeWhere((r) => r.listId == id);
    _deleted.removeWhere((r) => r.listId == id);
  }

  // ── Tasks ───────────────────────────────────────────────────────────────

  @override
  Future<Page<Task>> listTasks(String listId, {String? pageToken}) async {
    await _fireOnCall(Method.listTasks);
    _record(Method.listTasks);
    // Decode the page cursor first — it identifies which page a per-page fault
    // targets. Tokens are our own opaque `page-N` strings; anything else is a
    // client bug the live API rejects with a permanent 400.
    final int pageIndex;
    if (pageToken == null) {
      pageIndex = 0;
    } else {
      final n = pageToken.startsWith('page-')
          ? int.tryParse(pageToken.substring(5))
          : null;
      if (n == null || n < 0) {
        throw const OtherApiError('400: Invalid page token');
      }
      pageIndex = n;
    }
    final fault = _nextFault(Method.listTasks);
    if (fault != null) throw fault;
    final pageFault = _nextFaultForPage(Method.listTasks, pageIndex);
    if (pageFault != null) throw pageFault;
    // The endpoint is `/lists/{tasklist}/tasks`: a list the account does not
    // have is a 404, NOT an empty page. The difference is load-bearing — an
    // empty page reads to the engine as "the server wiped this list's tasks".
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();

    // Google returns a list's tasks ordered by their opaque, lexicographic
    // `position` string; mirror that so ordering tests see a real order.
    final items =
        _tasks.where((r) => r.listId == listId).map((r) => r.task).toList()
          ..sort((a, b) => a.position.compareTo(b.position));

    final pageSize = _pageSize ?? (items.isEmpty ? 1 : items.length);
    final start = pageIndex * pageSize;
    final end = (start + pageSize) < items.length
        ? start + pageSize
        : items.length;
    final pageItems = start < items.length
        ? items.sublist(start, end)
        : <Task>[];
    final nextPageToken = end < items.length ? 'page-${pageIndex + 1}' : null;
    return Page(items: pageItems, nextPageToken: nextPageToken);
  }

  @override
  Future<Task> insertTask(String listId, NewTask task) async {
    await _fireOnCall(Method.insertTask);
    _record(Method.insertTask);
    final fault = _nextFault(Method.insertTask);
    if (fault != null) throw fault;
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    // Live-API strictness: an unknown (or soft-deleted) parent id is a
    // permanent 400 — exactly what pushing a child create before its parent
    // resolved does.
    // Scoped to THIS list: a parent id that lives in another list is as
    // unknown to this endpoint as one that exists nowhere.
    final parent = task.parent;
    if (parent != null &&
        !_tasks.any((r) => r.listId == listId && r.task.id == parent)) {
      throw const OtherApiError('400: Invalid task ID (parent)');
    }
    _validateSizes(task.title, task.notes);
    final due = _validateDue(task.due);
    // A task inserted under a COMPLETED parent is completed by the cascade
    // immediately — the insert RESPONSE already carries status=completed.
    final parentCompleted = parent != null && _isCompleted(parent);
    final etag = _freshEtag();
    final position = _positionAfter(listId, parent, task.previous);
    final id = 'remote-$_etagCounter';
    final status = parentCompleted
        ? TaskStatus.completed
        : (task.status ?? TaskStatus.needsAction);
    final created = Task(
      id: id,
      parent: parent,
      position: position,
      title: task.title,
      notes: task.notes,
      status: status,
      due: due,
      completed: status == TaskStatus.completed ? _completedStamp : null,
      etag: etag,
      updated: _updatedStamp,
      webViewLink: 'https://tasks.google.com/task/$id',
    );
    _tasks.add((listId: listId, task: created));
    // Lost-response hazard: the row IS created above, but the response is
    // dropped — the caller sees a Network error while the mutation landed.
    if (_takeCommitThenFail(Method.insertTask)) {
      throw const Network('response timeout after commit');
    }
    return created;
  }

  @override
  Future<Task> getTask(String listId, String id) async {
    await _fireOnCall(Method.getTask);
    _record(Method.getTask);
    final fault = _nextFault(Method.getTask);
    if (fault != null) throw fault;
    final idFault = _nextFaultForId(Method.getTask, id);
    if (idFault != null) throw idFault;
    for (final r in _tasks) {
      if (r.listId == listId && r.task.id == id) return r.task;
    }
    // A soft-deleted task still answers 200 on a direct get, flagged deleted.
    for (final r in _deleted) {
      if (r.listId == listId && r.task.id == id) {
        return r.task.copyWith(deleted: true);
      }
    }
    throw const NotFound();
  }

  @override
  Future<Task> patchTask(
    String listId,
    String id,
    TaskPatch patch, {
    String? etag,
  }) async {
    await _fireOnCall(Method.patchTask);
    _record(Method.patchTask);
    final fault = _nextFault(Method.patchTask);
    if (fault != null) throw fault;
    final idFault = _nextFaultForId(Method.patchTask, id);
    if (idFault != null) throw idFault;
    // Argument validation precedes resource lookup on the live API: an oversize
    // title/notes is a permanent 400 regardless of the target row's state.
    _validateSizes(patch.title, patch.notes);
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    final newEtag = _freshEtag();
    final newUpdated = _freshUpdated();

    // The (list, task) PAIR addresses the row: an id held by another list is
    // not reachable from this one.
    final idx = _tasks.indexWhere((r) => r.listId == listId && r.task.id == id);
    if (idx < 0) {
      // A PATCH to a soft-deleted task returns 200 with a body echoing the
      // requested edit, but the row stays deleted and never returns to
      // list_tasks — "accepted then silently ignored". The echo is NOT
      // persisted, and this must NOT 412 on a stale etag (P4: delete wins, no
      // conflicted copy).
      for (final r in _deleted) {
        if (r.listId == listId && r.task.id == id) {
          return _applyEcho(r.task, patch);
        }
      }
      throw const NotFound();
    }

    final current = _tasks[idx].task;
    if (etag != null && current.etag != etag) {
      throw const PreconditionFailed();
    }

    final patchedDue = patch.due != null ? _validateDue(patch.due) : null;

    // Re-opening a subtask whose parent is still completed returns 200 but is
    // silently ignored server-side. Evaluate before mutating anything.
    final parentCompleted =
        current.parent != null &&
        _tasks.any(
          (r) =>
              r.task.id == current.parent &&
              r.task.status == TaskStatus.completed,
        );
    final silentlyIgnoreReopen =
        patch.status == TaskStatus.needsAction && parentCompleted;

    var status = current.status;
    var completed = current.completed;
    var cascadeComplete = false;
    if (patch.status != null && !silentlyIgnoreReopen) {
      status = patch.status!;
      completed = status == TaskStatus.completed ? _completedStamp : null;
      cascadeComplete = status == TaskStatus.completed;
    }

    final updated = Task(
      id: current.id,
      parent: current.parent,
      position: current.position,
      title: patch.title ?? current.title,
      // An empty-string notes clears the field to null.
      notes: patch.notes != null
          ? (patch.notes!.isEmpty ? null : patch.notes)
          : current.notes,
      status: status,
      // An empty-string due clears; a present due is the normalized value.
      due: patch.due != null ? patchedDue : current.due,
      completed: completed,
      etag: newEtag,
      // A mutation moves `updated`, exactly as the live service does.
      updated: newUpdated,
      webViewLink: current.webViewLink,
    );
    _tasks[idx] = (listId: _tasks[idx].listId, task: updated);

    // Completing a parent auto-completes its whole subtree server-side. Un-
    // completing does NOT reopen children, so this only runs on completion.
    if (cascadeComplete) _cascadeCompleteDescendants(updated.id);
    // Lost-response hazard: the patch committed above (new content + etag), but
    // its response is dropped. A retry meets a self-content 412 the engine must
    // absorb by adopting the remote etag, with no conflicted copy.
    if (_takeCommitThenFail(Method.patchTask)) {
      throw const Network('response timeout after commit');
    }
    return updated;
  }

  @override
  Future<void> deleteTask(String listId, String id) async {
    await _fireOnCall(Method.deleteTask);
    _record(Method.deleteTask);
    final fault = _nextFault(Method.deleteTask);
    if (fault != null) throw fault;
    final idFault = _nextFaultForId(Method.deleteTask, id);
    if (idFault != null) throw idFault;
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    // Addressed by the pair: an id in another list is a 404 here, and its row
    // must not be touched.
    if (!_tasks.any((r) => r.listId == listId && r.task.id == id)) {
      throw const NotFound();
    }
    // DELETE soft-deletes; the server cascades to descendants, so the whole
    // subtree goes. Zero rows moved means `id` names no live task → 404.
    if (_softDeleteSubtree(id) == 0) throw const NotFound();
    // Lost-response hazard: the subtree is soft-deleted, but the response is
    // dropped. A retry meets a 404 the engine treats as a completed delete.
    if (_takeCommitThenFail(Method.deleteTask)) {
      throw const Network('response timeout after commit');
    }
  }

  @override
  Future<Task> moveTask(
    String listId,
    String id, {
    String? parent,
    String? previous,
  }) async {
    await _fireOnCall(Method.moveTask);
    _record(Method.moveTask);
    final fault = _nextFault(Method.moveTask);
    if (fault != null) throw fault;
    final idFault = _nextFaultForId(Method.moveTask, id);
    if (idFault != null) throw idFault;
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    final idx = _tasks.indexWhere((r) => r.listId == listId && r.task.id == id);
    if (idx < 0) {
      // Live-API behavior: an unknown SUBJECT id in a move is a permanent 400
      // "Invalid task ID" — NOT the 404 an unknown `previous` draws. An id that
      // belongs to another list is exactly as unknown to this endpoint.
      throw const OtherApiError('400: Invalid task ID');
    }
    // Same strictness `insert_task` applies to the same field: an unknown parent
    // is a permanent 400. Without it the fake could hold a task whose parent it
    // does not have — a state Google cannot be in, one our pull re-detaches on
    // every run (#113).
    if (parent != null &&
        !_tasks.any((r) => r.listId == listId && r.task.id == parent)) {
      throw const OtherApiError('400: Invalid task ID (parent)');
    }
    // A task cannot become its own descendant (Google's forest model, #155).
    // Walk up from the target parent; reaching `id` proves the move closes a
    // cycle → permanent 400, evaluated against current server state.
    if (parent != null) {
      String? cur = parent;
      while (cur != null) {
        if (cur == id) {
          throw const OtherApiError('400: Invalid task ID (parent)');
        }
        final i = _tasks.indexWhere((r) => r.task.id == cur);
        cur = i < 0 ? null : _tasks[i].task.parent;
      }
    }
    final newEtag = _freshEtag();
    final newUpdated = _freshUpdated();
    // Real lexicographic placement, exactly like `insert`. An unknown
    // `previous` throws NotFound (a 404), the verified asymmetry.
    final position = _positionAfter(listId, parent, previous);
    // Moving an open task under a COMPLETED parent completes it: the move
    // RESPONSE already carries status=completed, and the cascade reaches its
    // subtree.
    final destCompleted = parent != null && _isCompleted(parent);
    final current = _tasks[idx].task;
    final becomesCompleted =
        destCompleted && current.status != TaskStatus.completed;
    final moved = Task(
      id: current.id,
      parent: parent,
      position: position,
      title: current.title,
      notes: current.notes,
      status: becomesCompleted ? TaskStatus.completed : current.status,
      due: current.due,
      completed: becomesCompleted ? _completedStamp : current.completed,
      etag: newEtag,
      updated: newUpdated,
      webViewLink: current.webViewLink,
      deleted: current.deleted,
    );
    _tasks[idx] = (listId: _tasks[idx].listId, task: moved);
    if (destCompleted) _cascadeCompleteDescendants(moved.id);
    // Lost-response hazard: the move committed above, but the response is
    // dropped. A retry re-sends the same move and must reconverge.
    if (_takeCommitThenFail(Method.moveTask)) {
      throw const Network('response timeout after commit');
    }
    return moved;
  }

  // ── Fault injection & server-side state helpers ─────────────────────────

  /// Schedule an untargeted fault returned by the next call to [m] (FIFO per
  /// method; fires only when [m] is at the front of the queue).
  void failNext(Method m, ApiError Function() err) => _faults.add((m, err));

  /// Schedule a fault that fires only when [m] (a single-task method) is invoked
  /// against [id]. Order-independent; consumed on the first matching call.
  void failNextForId(Method m, String id, ApiError Function() err) =>
      _targetedFaults.add(_TargetedFault(method: m, id: id, err: err));

  /// Schedule a fault that fires only when `list_tasks` is called for the given
  /// 0-based [page] — models a network drop partway through a paged scroll.
  void failListTasksPage(int page, ApiError Function() err) => _targetedFaults
      .add(_TargetedFault(method: Method.listTasks, page: page, err: err));

  /// Split `list_tasks` into pages of at most [size] items, with real
  /// `next_page_token`s between them. Unset returns everything in one page.
  void setPageSize(int size) => _pageSize = size;

  /// Arm a lost-response fault on the next call to [m]: it commits its mutation
  /// server-side, then throws [Network] — the at-least-once hazard. Defined for
  /// the mutating methods; arming a read-only method has no committed mutation
  /// to preserve, so its call simply never checks the arming.
  void commitThenFailNext(Method m) => _commitThenFail.add(m);

  /// Insert-only shorthand for [commitThenFailNext] — the same as
  /// `commitThenFailNext(Method.insertTask)`.
  void commitThenFailNextInsert() => commitThenFailNext(Method.insertTask);

  /// Make [id] a list whose deletion the account permanently refuses: a
  /// `delete_tasklist` against it returns a permanent 400 and leaves the list
  /// and its tasks untouched.
  ///
  /// OPT-IN on purpose. The engine has a `revive` branch for a list delete the
  /// server refuses forever (`reconcile.planListDelete`), and the account's
  /// default list is the case it was written for — but "Google refuses to
  /// delete the default list" is NOT among the semantics probed live (RFC-009's
  /// eight probes) and is not in the published `tasklists.delete` reference. So
  /// the fake does not assert it as a universal truth about every account's
  /// first list; a test that wants that server states it, and the rejection
  /// itself is modelled exactly.
  void setUndeletableList(String id) => _undeletableLists.add(id);

  /// Disarm every queued fault — untargeted, targeted, and every pending
  /// commit-then-fail lost response — so a test can switch from a chaotic phase
  /// to a provably healthy one.
  void clearFaults() {
    _faults.clear();
    _targetedFaults.clear();
    _commitThenFail.clear();
  }

  /// Number of recorded calls to [m] (a faulted call still counts).
  int callCount(Method m) => _calls[m] ?? 0;

  /// Install (or replace) the per-call interleave hook. See [OnCall];
  /// [clearOnCall] removes it.
  void setOnCall(OnCall hook) => _onCall = hook;

  /// Remove any installed on_call hook.
  void clearOnCall() => _onCall = null;

  /// Soft-delete a task server-side the way another client's `DELETE` would —
  /// the row (and its cascade subtree) leaves `list_tasks`, but a direct
  /// `get`/`patch` still reaches it — WITHOUT recording a call or consuming a
  /// fault. Drives a delete race from setup or an on_call hook. [listId] is
  /// accepted for call-site clarity; the subtree is resolved by id.
  void deleteTaskFromState(String listId, String taskId) {
    _softDeleteSubtree(taskId);
  }

  /// Insert a top-level task server-side the way another client's create would,
  /// but TOLERANT of a racing list delete: a missing [listId] is a safe no-op
  /// instead of an assertion. Records no call and consumes no fault, so it can
  /// be driven from an on_call hook to model "another device created a task
  /// mid-run". (Setup-time seeding should still use [seedTask], whose assertion
  /// catches typos.)
  void seedTaskIfListExists(
    String listId,
    String id,
    String title,
    String position,
  ) {
    if (!_lists.any((l) => l.id == listId)) return;
    final task = Task(
      id: id,
      position: position,
      title: title,
      status: TaskStatus.needsAction,
      etag: _freshEtag(),
      updated: _updatedStamp,
      webViewLink: 'https://tasks.google.com/task/$id',
    );
    _tasks.add((listId: listId, task: task));
  }

  /// Remove a list (and its tasks + tombstones) from internal state, simulating
  /// a list deleted server-side by another client. Records no call. Later
  /// single-task/list methods against it then naturally return [NotFound].
  void deleteListFromState(String listId) {
    _lists.removeWhere((l) => l.id == listId);
    _tasks.removeWhere((r) => r.listId == listId);
    _deleted.removeWhere((r) => r.listId == listId);
  }

  // ── Internal helpers ────────────────────────────────────────────────────

  /// Validate + canonicalize a due value the way the live API does: `null`
  /// passes through, `""` means clear (→ `null`), anything else must be a full
  /// RFC-3339 timestamp (a bare date draws a permanent 400) and is normalized
  /// to `T00:00:00.000Z`.
  String? _validateDue(String? due) {
    if (due == null || due.isEmpty) return null;
    if (due.length < 20 ||
        !due.substring(10).startsWith('T') ||
        !due.endsWith('Z')) {
      throw const OtherApiError(
        '400: Request contains an invalid argument. '
        '(due)',
      );
    }
    final normalized = normalizeDue(due);
    if (normalized == null) {
      throw const OtherApiError(
        '400: Request contains an invalid argument. '
        '(due)',
      );
    }
    return normalized;
  }

  /// Reject a `title`/`notes` that exceeds the documented length. Google counts
  /// characters (runes), not bytes; a `null` field passes through untouched.
  void _validateSizes(String? title, String? notes) {
    if (title != null && title.runes.length > _maxTitleChars) {
      throw const OtherApiError(
        '400: Request contains an invalid argument. '
        '(title too long)',
      );
    }
    if (notes != null && notes.runes.length > _maxNotesChars) {
      throw const OtherApiError(
        '400: Request contains an invalid argument. '
        '(notes too long)',
      );
    }
  }

  /// The opaque, lexicographically-sortable `position` for a task placed after
  /// [previous] among its siblings — the same rule the live API applies for
  /// both `insert` and `move`. With [previous], append `'+'` (0x2B, below every
  /// digit) to the anchor's position, sorting strictly after it and before its
  /// original successor. With no [previous], go to the very top: `'!'` (0x21)
  /// sorts before any digit, and a descending counter keeps successive top
  /// inserts above one another. Call [_freshEtag] first so the counter advanced.
  ///
  /// [previous] names a SIBLING: `position` orders a task among the rows that
  /// share its list and its parent, so an anchor from another list — or from
  /// another parent in this one — has no meaning to place against. Anything but
  /// a real sibling is the same 404 an unknown `previous` draws (verified live:
  /// "Previous task id not found"; the asymmetry with an unknown SUBJECT id,
  /// which is a 400, is deliberate).
  String _positionAfter(String listId, String? parent, String? previous) {
    if (previous == null) {
      final descending = _u64Max - BigInt.from(_etagCounter);
      return '!${descending.toString().padLeft(19, '0')}';
    }
    for (final r in _tasks) {
      if (r.listId == listId &&
          r.task.id == previous &&
          r.task.parent == parent) {
        return '${r.task.position}+';
      }
    }
    throw const NotFound();
  }

  /// Is [id] a task the server currently considers completed?
  bool _isCompleted(String id) => _tasks.any(
    (r) => r.task.id == id && r.task.status == TaskStatus.completed,
  );

  /// Every transitive descendant of [root] (excluding [root] itself), by id.
  Set<String> _descendantsOf(String root) {
    final subtree = <String>{root};
    while (true) {
      final more = _tasks
          .where(
            (r) => r.task.parent != null && subtree.contains(r.task.parent),
          )
          .map((r) => r.task.id)
          .toSet();
      final before = subtree.length;
      subtree.addAll(more);
      if (subtree.length == before) break;
    }
    subtree.remove(root);
    return subtree;
  }

  /// Complete every descendant of [root], each getting a fresh etag and a
  /// completed stamp — the live API's cascade.
  void _cascadeCompleteDescendants(String root) {
    for (final cid in _descendantsOf(root)) {
      final i = _tasks.indexWhere((r) => r.task.id == cid);
      if (i < 0) continue;
      if (_tasks[i].task.status == TaskStatus.completed) continue;
      final done = _tasks[i].task.copyWith(
        status: TaskStatus.completed,
        completed: _completedStamp,
        etag: _freshEtag(),
        updated: _freshUpdated(),
      );
      _tasks[i] = (listId: _tasks[i].listId, task: done);
    }
  }

  /// Soft-delete [id] and its whole subtree the way the live service does: the
  /// rows move out of the live set into [_deleted]. Returns how many rows were
  /// moved — `0` when [id] names no live task.
  int _softDeleteSubtree(String id) {
    if (!_tasks.any((r) => r.task.id == id)) return 0;
    final subtree = _descendantsOf(id)..add(id);
    var moved = 0;
    var i = 0;
    while (i < _tasks.length) {
      if (subtree.contains(_tasks[i].task.id)) {
        _deleted.add(_tasks.removeAt(i));
        moved += 1;
      } else {
        i += 1;
      }
    }
    return moved;
  }

  /// Build the 200-echo body a PATCH of a soft-deleted row returns: the stored
  /// (deleted) row with the requested edits applied, NOT persisted and NEVER a
  /// 412 on a stale etag.
  Task _applyEcho(Task deleted, TaskPatch patch) {
    var echo = deleted;
    if (patch.title != null) echo = echo.copyWith(title: patch.title);
    if (patch.notes != null) {
      echo = echo.copyWith(notes: patch.notes!.isEmpty ? null : patch.notes);
    }
    if (patch.due != null) {
      // `_validateDue` can reject a bad due even on the echo path; clearing
      // ("") normalizes to null, which needs an explicit rebuild since
      // copyWith cannot clear `due`.
      echo = _withDue(echo, _validateDue(patch.due));
    }
    if (patch.status != null) {
      echo = echo.copyWith(
        status: patch.status,
        completed: patch.status == TaskStatus.completed
            ? _completedStamp
            : null,
      );
    }
    return echo;
  }

  /// Return a copy of [t] with `due` set to [due] (possibly null). [Task.copyWith]
  /// cannot express a null-clear of `due`, so rebuild the row explicitly.
  Task _withDue(Task t, String? due) => Task(
    id: t.id,
    parent: t.parent,
    position: t.position,
    title: t.title,
    notes: t.notes,
    status: t.status,
    due: due,
    completed: t.completed,
    etag: t.etag,
    updated: t.updated,
    webViewLink: t.webViewLink,
    deleted: t.deleted,
  );
}

/// `u64::MAX` — the reference's descending top-insert base (see [_positionAfter]).
final BigInt _u64Max = BigInt.parse('18446744073709551615');
