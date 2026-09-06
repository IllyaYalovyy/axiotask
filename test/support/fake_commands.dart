// THE in-memory [Commands] double for the widget suites (#271) — one fake, one
// file. It ACTUALLY performs each command against its own task set and re-emits
// the set on the stream the widgets watch, so the tests assert the USER-VISIBLE
// result (what renders, in what order, what the fake holds afterwards) rather
// than that a method fired. It stays off drift's real event queue, which the
// testWidgets fake zone cannot drain (see the widget-test-drift-async memory).
//
// Where the real command raises, so does this: a missing id throws the same
// [CommandError], so a bulk op must skip it here exactly as it would in
// production. The recording lists exist for the few assertions that can only be
// made about the ARGUMENTS a widget passed (which list a task was moved to);
// they are never a substitute for asserting the resulting state.

import 'dart:async';

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/attention.dart' show strippedCopyTitle;
import 'package:axiotask/src/model/dates.dart'
    show DateMove, applyDateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:clock/clock.dart';

/// Records the commands the panel fires AND performs them against its own task
/// set, re-emitting the mutated set on the stream the panel watches.
class FakeCommands implements Commands {
  FakeCommands(
    List<StoredTask> initial, {
    String Function()? newId,
    this.newestFirst = false,
  }) : _tasks = [...initial],
       _newId = newId ?? (() => 'gen');

  final List<StoredTask> _tasks;
  final String Function() _newId;
  final _controller = StreamController<List<StoredTask>>.broadcast();

  /// Put a created row at the FRONT of the emitted set rather than the back.
  /// The list view renders in POSITION order, so this only decides the order of
  /// rows whose positions tie — which is what the list suites pin.
  final bool newestFirst;

  /// When set, the next [setDue]/[setDueRaw] reports this cascade instead of the
  /// default no-cascade result — lets a test drive the #164 toast surface.
  SetDueResult? nextDueResult;

  /// The entries the last [undoSetDue] was handed (the Undo-was-wired probe).
  List<DueUndoEntry>? undoneWith;

  final List<String> renamed = [];
  final List<String> notesSet = [];
  final List<DeleteToken> deleted = [];
  final List<String> setDueCalls = [];
  final List<String> reordered = [];
  final List<String> movedTasks = [];
  final List<String> movedToList = [];
  final List<String> clearedLists = [];

  List<StoredTask> get tasks => List.unmodifiable(_tasks);

  Stream<List<StoredTask>> get tasksStream async* {
    yield List.of(_tasks);
    yield* _controller.stream;
  }

  void dispose() => _controller.close();
  void _emit() => _controller.add(List.of(_tasks));

  StoredTask _rebuild(StoredTask t, Task task) => StoredTask(
    task: task,
    listId: t.listId,
    syncState: SyncState.dirty,
    localUpdated: 't',
  );

  /// Simulate a sync PULL rewriting the whole local set: rows appear, rows
  /// disappear, exactly as the store's stream reports them after a pull.
  void pushAll(List<StoredTask> tasks) {
    _tasks
      ..clear()
      ..addAll(tasks);
    _emit();
  }

  /// Simulate an external write (e.g. a sync pull) retitling a task, so tests
  /// can exercise the panel's live-tracking / clobber-avoidance.
  ///
  /// The row lands CLEAN, exactly as `Store.upsertRemoteTask` writes a pulled
  /// row (its `WHERE sync_state = 'clean'` also means a pull can only ever land
  /// on a row that was already clean). That is what tells the app a change came
  /// from Google rather than from a local edit — the #252 commit flash reads it.
  void pushExternal(String id, String title) {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(title: title),
      listId: _tasks[i].listId,
      syncState: SyncState.clean,
      localUpdated: 't',
    );
    _emit();
  }

  @override
  Future<StoredTask> createTask({
    required String listId,
    String? parentId,
    required String title,
    String? due,
  }) async {
    final t = StoredTask(
      task: Task(
        id: _newId(),
        parent: parentId,
        position: '!new',
        title: title,
        status: TaskStatus.needsAction,
        due: due == null ? null : normalizeDue(due),
        updated: 't',
      ),
      listId: listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
      pendingOp: 'create',
    );
    if (newestFirst) {
      _tasks.insert(0, t);
    } else {
      _tasks.add(t);
    }
    _emit();
    return t;
  }

  @override
  Future<void> renameTask(String id, String title) async {
    renamed.add('$id=$title');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    _tasks[i] = _rebuild(_tasks[i], _tasks[i].task.copyWith(title: title));
    _emit();
  }

  @override
  Future<void> setNotes(String id, String notes) async {
    notesSet.add('$id=$notes');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    _tasks[i] = _rebuild(
      _tasks[i],
      _tasks[i].task.copyWith(notes: notes.isEmpty ? null : notes),
    );
    _emit();
  }

  @override
  Future<CompleteToken> toggleComplete(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    // Mirror Commands.toggleComplete: a missing/vanished id raises CommandError
    // (never a silent no-op), so bulk ops must skip it exactly like production.
    if (i < 0) throw CommandError('task $id not found');
    final completing = _tasks[i].task.status == TaskStatus.needsAction;
    _tasks[i] = _rebuild(
      _tasks[i],
      _tasks[i].task.copyWith(
        status: completing ? TaskStatus.completed : TaskStatus.needsAction,
      ),
    );
    if (!completing) {
      _emit();
      return CompleteToken(id: id, wasCompleting: false);
    }
    // Cascade completion to open descendants, recording exactly what flipped.
    final cascaded = <String>[];
    final frontier = <String>[id];
    while (frontier.isNotEmpty) {
      final pid = frontier.removeLast();
      for (var j = 0; j < _tasks.length; j++) {
        if (_tasks[j].task.parent != pid) continue;
        frontier.add(_tasks[j].task.id);
        if (_tasks[j].task.status == TaskStatus.completed) continue;
        cascaded.add(_tasks[j].task.id);
        _tasks[j] = _rebuild(
          _tasks[j],
          _tasks[j].task.copyWith(status: TaskStatus.completed),
        );
      }
    }
    _emit();
    return CompleteToken(
      id: id,
      wasCompleting: true,
      cascadedReopenIds: cascaded,
    );
  }

  @override
  Future<void> undoToggleComplete(CompleteToken token) async {
    if (token.wasCompleting) {
      for (final id in <String>[token.id, ...token.cascadedReopenIds]) {
        final i = _tasks.indexWhere((t) => t.task.id == id);
        if (i < 0) continue;
        _tasks[i] = _rebuild(
          _tasks[i],
          _tasks[i].task.copyWith(status: TaskStatus.needsAction),
        );
      }
    } else {
      final i = _tasks.indexWhere((t) => t.task.id == token.id);
      if (i >= 0) {
        _tasks[i] = _rebuild(
          _tasks[i],
          _tasks[i].task.copyWith(status: TaskStatus.completed),
        );
      }
    }
    _emit();
  }

  @override
  Future<DeleteToken> deleteTask(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    // Mirror Commands.deleteTask: a missing/already-tombstoned id raises
    // CommandError, so bulk delete must skip it rather than crash.
    if (i < 0) throw CommandError('task $id not found');
    final t = _tasks[i];
    // Snapshot the subtree (BFS) so undo can rebuild the whole thing.
    final subtree = <SubtreeEntry>[];
    final frontier = <String>[id];
    while (frontier.isNotEmpty) {
      final pid = frontier.removeLast();
      for (final c in _tasks.where((c) => c.task.parent == pid)) {
        frontier.add(c.task.id);
        subtree.add(
          SubtreeEntry(
            id: c.task.id,
            parentId: c.task.parent,
            title: c.task.title,
            notes: c.task.notes,
            status: c.task.status,
            due: c.task.due,
            position: c.task.position,
          ),
        );
      }
    }
    final token = DeleteToken(
      id: id,
      listId: t.listId,
      parentId: t.task.parent,
      title: t.task.title,
      notes: t.task.notes,
      status: t.task.status,
      due: t.task.due,
      position: t.task.position,
      hadEtag: t.task.etag != null,
      subtree: subtree,
    );
    deleted.add(token);
    final doomed = {id, ...subtree.map((e) => e.id)};
    _tasks.removeWhere((t) => doomed.contains(t.task.id));
    _emit();
    return token;
  }

  @override
  Future<void> undoDelete(DeleteToken token) async {
    void restore(
      String id,
      String? parentId,
      String position,
      String title,
      String? notes,
      TaskStatus status,
      String? due,
    ) {
      if (_tasks.any((t) => t.task.id == id)) return;
      _tasks.add(
        StoredTask(
          task: Task(
            id: id,
            parent: parentId,
            position: position,
            title: title,
            notes: notes,
            status: status,
            due: due,
            updated: 't',
          ),
          listId: token.listId,
          syncState: SyncState.dirty,
          localUpdated: 't',
          pendingOp: 'create',
        ),
      );
    }

    restore(
      token.id,
      token.parentId,
      token.position,
      token.title,
      token.notes,
      token.status,
      token.due,
    );
    for (final e in token.subtree) {
      restore(e.id, e.parentId, e.position, e.title, e.notes, e.status, e.due);
    }
    _emit();
  }

  /// Either the cascade a test configured via [nextDueResult], or a plain
  /// no-cascade result over the row's prior date.
  SetDueResult _noCascade(String id, String? prior) =>
      nextDueResult ??
      SetDueResult(
        undo: [DueUndoEntry(id: id, due: prior)],
        cascaded: 0,
        cascadedParent: false,
      );

  @override
  Future<SetDueResult> setDue(String id, DateMove move) async {
    setDueCalls.add('$id=$move');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return _noCascade(id, null);
    final n = clock.now().toUtc();
    final today = DateTime.utc(n.year, n.month, n.day);
    final d = applyDateMove(today, move);
    return _writeDue(
      i,
      d == null
          ? null
          : normalizeDue(
              '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}',
            ),
    );
  }

  @override
  Future<SetDueResult> setDueRaw(String id, String rawDate) async {
    setDueCalls.add('$id=raw:$rawDate');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return _noCascade(id, null);
    return _writeDue(i, normalizeDue(rawDate));
  }

  /// Write [due] onto the row at [i] and run the #164 consistency cascade
  /// exactly as `TaskEditCommands._setDue` does — a subtask's explicit date is
  /// never before its parent's, with the editor's intent winning. The fake
  /// mirrors it rather than reporting a bare no-cascade result so a surface
  /// that must SURVIVE a cascade (the bulk Undo, #274) is exercised against
  /// the real shape of one: the edited row's prior date first, then one entry
  /// per row the cascade moved.
  SetDueResult _writeDue(int i, String? due) {
    final edited = _tasks[i];
    final undo = <DueUndoEntry>[
      DueUndoEntry(id: edited.task.id, due: edited.task.due),
    ];
    _tasks[i] = _rebuild(edited, edited.task.copyWith(due: due));
    var cascadedParent = false;
    if (due != null) {
      final parentId = edited.task.parent;
      for (var j = 0; j < _tasks.length; j++) {
        final other = _tasks[j];
        if (other.listId != edited.listId) continue;
        final od = other.task.due;
        if (od == null) continue;
        if (parentId != null) {
          // Editing a CHILD: a parent sitting later is pulled DOWN to match.
          if (other.task.id != parentId || !_dueBefore(due, od)) continue;
          cascadedParent = true;
        } else {
          // Editing a PARENT: every child sitting earlier is pulled UP.
          if (other.task.parent != edited.task.id || !_dueBefore(od, due)) {
            continue;
          }
        }
        undo.add(DueUndoEntry(id: other.task.id, due: od));
        _tasks[j] = _rebuild(other, other.task.copyWith(due: due));
      }
    }
    _emit();
    return nextDueResult ??
        SetDueResult(
          undo: undo,
          cascaded: undo.length - 1,
          cascadedParent: cascadedParent,
        );
  }

  /// Date-only comparison over the canonical `YYYY-MM-DD...` due form. A value
  /// too short to carry a date compares as-is rather than throwing — a fixture
  /// with a malformed due must fail its own assertion, not the fake.
  static bool _dueBefore(String a, String b) {
    String day(String s) => s.length < 10 ? s : s.substring(0, 10);
    return day(a).compareTo(day(b)) < 0;
  }

  @override
  Future<void> undoSetDue(List<DueUndoEntry> entries) async {
    undoneWith = entries;
    // Actually RESTORE, so a suite can assert the rows the user sees go back
    // to their pre-edit dates rather than merely that the call was wired.
    for (final e in entries) {
      final i = _tasks.indexWhere((t) => t.task.id == e.id);
      if (i < 0) continue;
      _tasks[i] = _rebuild(_tasks[i], _tasks[i].task.copyWith(due: e.due));
    }
    _emit();
  }

  @override
  Future<int> clearCompleted(String listId) async {
    clearedLists.add(listId);
    // Mirror the real command: drop completed tasks in this list unless they
    // shelter an open descendant (a completed parent of an unfinished subtask).
    bool hasOpenDescendant(String root) {
      final frontier = <String>[root];
      while (frontier.isNotEmpty) {
        final pid = frontier.removeLast();
        for (final c in _tasks.where((c) => c.task.parent == pid)) {
          if (c.task.status != TaskStatus.completed) return true;
          frontier.add(c.task.id);
        }
      }
      return false;
    }

    final doomed = _tasks
        .where(
          (t) =>
              t.listId == listId &&
              t.task.status == TaskStatus.completed &&
              !hasOpenDescendant(t.task.id),
        )
        .map((t) => t.task.id)
        .toSet();
    if (doomed.isEmpty) return 0;
    _tasks.removeWhere((t) => doomed.contains(t.task.id));
    _emit();
    return doomed.length;
  }

  @override
  Future<void> moveTask(
    String id, {
    String? parentId,
    String? previousId,
  }) async {
    movedTasks.add('$id:parent=$parentId:prev=$previousId');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    final t = _tasks[i];
    // parent may be cleared to null (which copyWith cannot express) — rebuild.
    _tasks[i] = StoredTask(
      task: Task(
        id: t.task.id,
        parent: parentId,
        position: t.task.position,
        title: t.task.title,
        notes: t.task.notes,
        status: t.task.status,
        due: t.task.due,
        updated: t.task.updated,
      ),
      listId: t.listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
    );
    _emit();
  }

  @override
  Future<void> reorderTaskAfter(String id, String? previousId) async {
    reordered.add('$id:${previousId ?? '<front>'}');
    if (previousId == id) return;
    final cur = _tasks.firstWhere((t) => t.task.id == id);
    // The sibling store indices in position order (same parent + list).
    final sibIdx =
        <int>[
          for (var i = 0; i < _tasks.length; i++)
            if (_tasks[i].task.parent == cur.task.parent &&
                _tasks[i].listId == cur.listId)
              i,
        ]..sort(
          (a, b) => _tasks[a].task.position.compareTo(_tasks[b].task.position),
        );
    final from = sibIdx.indexWhere((i) => _tasks[i].task.id == id);
    if (from < 0) return;
    final currentPrevious = from == 0 ? null : _tasks[sibIdx[from - 1]].task.id;
    if (previousId == currentPrevious) return; // no-op

    // Reinsert right after the anchor (or at the front), then reassign position
    // strings by slot (mirrors Commands.reorderTaskAfter).
    final order = [...sibIdx]..removeAt(from);
    final int insertAt;
    if (previousId == null) {
      insertAt = 0;
    } else {
      final anchor = order.indexWhere((i) => _tasks[i].task.id == previousId);
      if (anchor < 0) return;
      insertAt = anchor + 1;
    }
    order.insert(insertAt, sibIdx[from]);

    final positions = [for (final i in sibIdx) _tasks[i].task.position];
    for (var slot = 0; slot < order.length; slot++) {
      final ti = order[slot];
      final desired = positions[slot];
      if (_tasks[ti].task.position == desired) continue;
      _tasks[ti] = _rebuild(
        _tasks[ti],
        _tasks[ti].task.copyWith(position: desired),
      );
    }
    _emit();
  }

  @override
  Future<MoveToListToken?> moveTaskToList(
    String id,
    String targetListId,
  ) async {
    movedToList.add('$id->$targetListId');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return null;
    final old = _tasks[i];
    if (old.listId == targetListId) return null;
    final original = DeleteToken(
      id: old.task.id,
      listId: old.listId,
      parentId: old.task.parent,
      title: old.task.title,
      notes: old.task.notes,
      status: old.task.status,
      due: old.task.due,
      position: old.task.position,
      hadEtag: old.task.etag != null,
    );
    final newId = '$id-moved';
    _tasks[i] = StoredTask(
      task: old.task.copyWith(id: newId),
      listId: targetListId,
      syncState: SyncState.dirty,
      localUpdated: 't',
      pendingOp: 'create',
    );
    _emit();
    return MoveToListToken(
      newRootId: newId,
      targetListId: targetListId,
      original: original,
    );
  }

  @override
  Future<void> undoMoveToList(MoveToListToken token) async {
    _tasks.removeWhere((t) => t.task.id == token.newRootId);
    final o = token.original;
    if (!_tasks.any((t) => t.task.id == o.id)) {
      _tasks.add(
        StoredTask(
          task: Task(
            id: o.id,
            parent: o.parentId,
            position: o.position,
            title: o.title,
            notes: o.notes,
            status: o.status,
            due: o.due,
            updated: 't',
          ),
          listId: o.listId,
          syncState: SyncState.dirty,
          localUpdated: 't',
          pendingOp: 'create',
        ),
      );
    }
    _emit();
  }

  // ── sync repairs (#296) ──────────────────────────────────────────────────
  //
  // The real commands read a row's BASE snapshot (its content as of the last
  // agreement with Google) out of the store; the fake has no such column, so a
  // test that exercises Discard seeds [serverTitles] with what the server
  // holds. Everything else is performed for real against the fake's own set,
  // so the suites assert the ROWS afterwards, not that a method fired.

  /// What Google holds for a row, keyed by task id — the stand-in for the store's
  /// base snapshot. A row absent from it has never been agreed (an unpushed
  /// create), and discarding its change discards the row, as in production.
  final Map<String, String> serverTitles = {};

  @override
  Future<DiscardToken> discardLocalChange(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) throw CommandError('task $id not found');
    final before = _tasks[i];
    final base = serverTitles[id];
    if (base == null) {
      return DiscardToken(rowBefore: before, deleted: await deleteTask(id));
    }
    _tasks[i] = StoredTask(
      task: before.task.copyWith(title: base),
      listId: before.listId,
      syncState: SyncState.clean,
      localUpdated: before.localUpdated,
      remoteId: before.remoteId,
    );
    _emit();
    return DiscardToken(rowBefore: before);
  }

  @override
  Future<void> undoDiscardLocalChange(DiscardToken token) async {
    final deleted = token.deleted;
    if (deleted != null) {
      await undoDelete(deleted);
      return;
    }
    _replace(token.rowBefore);
    _emit();
  }

  @override
  Future<ConflictToken> resolveConflict({
    required String originalId,
    required String copyId,
    required ConflictChoice choice,
  }) async {
    final oi = _tasks.indexWhere((t) => t.task.id == originalId);
    final ci = _tasks.indexWhere((t) => t.task.id == copyId);
    if (oi < 0 || ci < 0) throw CommandError('task $originalId not found');
    final original = _tasks[oi];
    final copy = _tasks[ci];
    final stripped = strippedCopyTitle(copy.task.title);
    switch (choice) {
      case ConflictChoice.keepMine:
        _tasks[oi] = _rebuild(
          original,
          original.task.copyWith(
            title: stripped,
            notes: copy.task.notes,
            due: copy.task.due,
            status: copy.task.status,
          ),
        );
        _tasks.removeWhere((t) => t.task.id == copyId);
      case ConflictChoice.keepTheirs:
        _tasks.removeWhere((t) => t.task.id == copyId);
      case ConflictChoice.keepBoth:
        _tasks[ci] = _rebuild(copy, copy.task.copyWith(title: stripped));
    }
    _emit();
    return ConflictToken(originalBefore: original, copyBefore: copy);
  }

  @override
  Future<void> undoResolveConflict(ConflictToken token) async {
    _replace(token.originalBefore);
    _replace(token.copyBefore);
    _emit();
  }

  /// Put [row] back at its id — restoring it if the resolution removed it.
  void _replace(StoredTask row) {
    final i = _tasks.indexWhere((t) => t.task.id == row.task.id);
    if (i < 0) {
      _tasks.add(row);
    } else {
      _tasks[i] = row;
    }
  }

  @override
  Future<void> freshSync() async => throw UnimplementedError();

  @override
  Future<StoredTaskList> createList(String title, {bool localOnly = false}) =>
      throw UnimplementedError();

  @override
  Future<void> renameList(String id, String title) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteList(String id) async => throw UnimplementedError();
}
