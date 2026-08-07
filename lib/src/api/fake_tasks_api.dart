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
// T3.3 adds the remainder — positioning ordering, `move`, pagination, and the
// full fault-injection surface (the seams below are no-op placeholders wired
// there). Together T3.2+T3.3 cover the entire `in_memory.rs` inventory.

import '../model/dates.dart';
import '../model/page.dart';
import '../model/task.dart';
import '../model/task_list.dart';
import 'api_error.dart';
import 'tasks_api.dart';

/// Per-method fault-injection key. Present now so the fault seams below have a
/// stable public signature; the seams that consume it are wired in T3.3.
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
const String _updatedStamp = '2026-01-01T00:00:00Z';

/// A stored row: which list it belongs to plus the task itself.
typedef _Row = ({String listId, Task task});

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

  String _freshEtag() {
    _etagCounter += 1;
    return 'etag-$_etagCounter';
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
  Future<List<TaskList>> listTasklists() async => List.of(_lists);

  @override
  Future<TaskList> insertTasklist(String title) async {
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
    final i = _lists.indexWhere((l) => l.id == id);
    if (i < 0) throw const NotFound();
    final updated = TaskList(
      id: id,
      title: title,
      etag: _freshEtag(),
      updated: _lists[i].updated,
    );
    _lists[i] = updated;
    return updated;
  }

  @override
  Future<void> deleteTasklist(String id) async {
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
    // T3.2 returns the whole (live) list in one page, ordered by the opaque,
    // lexicographic `position` string the live API sorts by. Real pagination
    // and per-page faults land in T3.3.
    final items =
        _tasks.where((r) => r.listId == listId).map((r) => r.task).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    return Page(items: items, nextPageToken: null);
  }

  @override
  Future<Task> insertTask(String listId, NewTask task) async {
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    // Live-API strictness: an unknown (or soft-deleted) parent id is a
    // permanent 400 — exactly what pushing a child create before its parent
    // resolved does.
    final parent = task.parent;
    if (parent != null && !_tasks.any((r) => r.task.id == parent)) {
      throw const OtherApiError('400: Invalid task ID (parent)');
    }
    _validateSizes(task.title, task.notes);
    final due = _validateDue(task.due);
    // A task inserted under a COMPLETED parent is completed by the cascade
    // immediately — the insert RESPONSE already carries status=completed.
    final parentCompleted = parent != null && _isCompleted(parent);
    final etag = _freshEtag();
    final position = _positionAfter(task.previous);
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
    return created;
  }

  @override
  Future<Task> getTask(String listId, String id) async {
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
    // Argument validation precedes resource lookup on the live API: an oversize
    // title/notes is a permanent 400 regardless of the target row's state.
    _validateSizes(patch.title, patch.notes);
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    final newEtag = _freshEtag();

    final idx = _tasks.indexWhere((r) => r.task.id == id);
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
      updated: current.updated,
      webViewLink: current.webViewLink,
    );
    _tasks[idx] = (listId: _tasks[idx].listId, task: updated);

    // Completing a parent auto-completes its whole subtree server-side. Un-
    // completing does NOT reopen children, so this only runs on completion.
    if (cascadeComplete) _cascadeCompleteDescendants(updated.id);
    return updated;
  }

  @override
  Future<void> deleteTask(String listId, String id) async {
    if (!_lists.any((l) => l.id == listId)) throw const NotFound();
    // DELETE soft-deletes; the server cascades to descendants, so the whole
    // subtree goes. Zero rows moved means `id` names no live task → 404.
    if (_softDeleteSubtree(id) == 0) throw const NotFound();
  }

  @override
  Future<Task> moveTask(
    String listId,
    String id, {
    String? parent,
    String? previous,
  }) {
    // Positioning/move lands in T3.3 (see the file header); the reference's
    // cycle/unknown-parent/cascade rules port there test-first.
    throw UnimplementedError('moveTask: implemented in T3.3');
  }

  // ── Fault-injection seams (no-op placeholders, wired + tested in T3.3) ───

  /// Schedule a fault returned by the next call to [m]. No-op until T3.3.
  void failNext(Method m, ApiError Function() err) {}

  /// Schedule a fault fired only when [m] is invoked against [id]. No-op until
  /// T3.3.
  void failNextForId(Method m, String id, ApiError Function() err) {}

  /// Schedule a fault fired only for the given 0-based `list_tasks` [page].
  /// No-op until T3.3.
  void failListTasksPage(int page, ApiError Function() err) {}

  /// Split `list_tasks` into pages of at most [size]. No-op until T3.3.
  void setPageSize(int size) {}

  /// Arm a lost-response (commit-then-fail) fault on the next call to [m].
  /// No-op until T3.3.
  void commitThenFailNext(Method m) {}

  /// Disarm every queued fault. No-op until T3.3.
  void clearFaults() {}

  /// Number of recorded calls to [m]. Call counting is wired in T3.3; returns
  /// `0` until then.
  int callCount(Method m) => 0;

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
  String _positionAfter(String? previous) {
    if (previous == null) {
      final descending = _u64Max - BigInt.from(_etagCounter);
      return '!${descending.toString().padLeft(19, '0')}';
    }
    for (final r in _tasks) {
      if (r.task.id == previous) return '${r.task.position}+';
    }
    // A `previous` that does not exist is a 404 — the asymmetry with an unknown
    // SUBJECT id (a 400) is verified live.
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
