// Shared harness for the TaskDetail suites (TaskDetail, DetailWorkflow,
// SubtaskReorder). A lightweight in-memory [Commands] double that ACTUALLY
// mutates its task set and re-emits it on the stream the panel watches — so the
// tests assert the USER-VISIBLE result (what renders, what order, what the fake
// holds), never merely that a method fired. It stays off drift's real event
// queue, which the testWidgets fake zone cannot drain (see the
// widget-test-drift-async memory).

import 'dart:async';

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/dates.dart'
    show DateMove, applyDateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'toast_harness.dart' show wrapWithToast;

StoredTask row(
  String id,
  String title, {
  String? parent,
  bool done = false,
  String? notes,
  String? due,
  String position = '1',
  String listId = 'L1',
  String? webViewLink,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    due: due,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    webViewLink: webViewLink,
    updated: 't',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: 't',
);

StoredTaskList list(String id, String title) => StoredTaskList(
  list: TaskList(id: id, title: title, updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// Records the commands the panel fires AND performs them against its own task
/// set, re-emitting the mutated set on the stream the panel watches.
class FakeBackend implements Commands {
  FakeBackend(List<StoredTask> initial, {String Function()? newId})
    : _tasks = [...initial],
      _newId = newId ?? (() => 'gen');

  final List<StoredTask> _tasks;
  final String Function() _newId;
  final _controller = StreamController<List<StoredTask>>.broadcast();

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

  /// Simulate an external write (e.g. a sync pull) retitling a task, so tests
  /// can exercise the panel's live-tracking / clobber-avoidance.
  void pushExternal(String id, String title) {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    _tasks[i] = _rebuild(_tasks[i], _tasks[i].task.copyWith(title: title));
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
    _tasks.add(t);
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

  SetDueResult _noCascade(String id, String? prior) => SetDueResult(
    undo: [DueUndoEntry(id: id, due: prior)],
    cascaded: 0,
    cascadedParent: false,
  );

  @override
  Future<SetDueResult> setDue(String id, DateMove move) async {
    setDueCalls.add('$id=$move');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return _noCascade(id, null);
    final prior = _tasks[i].task.due;
    final n = clock.now().toUtc();
    final today = DateTime.utc(n.year, n.month, n.day);
    final d = applyDateMove(today, move);
    final due = d == null
        ? null
        : normalizeDue(
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}',
          );
    _tasks[i] = _rebuild(_tasks[i], _tasks[i].task.copyWith(due: due));
    _emit();
    return _noCascade(id, prior);
  }

  @override
  Future<SetDueResult> setDueRaw(String id, String rawDate) async {
    setDueCalls.add('$id=raw:$rawDate');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return _noCascade(id, null);
    final prior = _tasks[i].task.due;
    _tasks[i] = _rebuild(
      _tasks[i],
      _tasks[i].task.copyWith(due: normalizeDue(rawDate)),
    );
    _emit();
    return _noCascade(id, prior);
  }

  @override
  Future<void> undoSetDue(List<DueUndoEntry> entries) async {}

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

  @override
  void setEditing(String? id) {}

  @override
  String? get heldCreateId => null;
}

/// Pump the real [TaskDetail] over a [FakeBackend], with the lists and prefs
/// providers live so the List dropdown and the Hide-completed toggle work.
Future<FakeBackend> pumpDetail(
  WidgetTester tester, {
  required String taskId,
  required List<StoredTask> initial,
  List<StoredTaskList> lists = const [],
  List<String>? closed,
  List<String>? opened,
  String Function()? newId,
  VoidCallback? onPrev,
  VoidCallback? onNext,
  UrlOpener? urlOpener,
}) async {
  final fake = FakeBackend(initial, newId: newId);
  addTearDown(fake.dispose);
  // A tall surface so the whole panel lays out and every subtask row is built
  // (a lazy ListView culls children below the fold, hiding them from finders).
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => fake.tasksStream),
        if (lists.isNotEmpty)
          listsProvider.overrideWith((ref) => Stream.value(lists)),
        if (urlOpener != null) urlOpenerProvider.overrideWithValue(urlOpener),
      ],
      child: MaterialApp(
        // Mount the F19 toast overlay so the panel's delete/move undo renders.
        builder: wrapWithToast,
        home: Scaffold(
          body: TaskDetail(
            taskId: taskId,
            onClose: () => (closed ?? <String>[]).add('close'),
            onOpenTask: (opened ?? <String>[]).add,
            onPrev: onPrev,
            onNext: onNext,
          ),
        ),
      ),
    ),
  );
  await settleDetail(tester);
  return fake;
}

Future<void> settleDetail(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}
