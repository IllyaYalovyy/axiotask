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
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTask row(
  String id,
  String title, {
  String? parent,
  bool done = false,
  String? notes,
  String? due,
  String position = '1',
  String listId = 'L1',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    due: due,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
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
  Future<void> toggleComplete(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    final completing = _tasks[i].task.status == TaskStatus.needsAction;
    _tasks[i] = _rebuild(
      _tasks[i],
      _tasks[i].task.copyWith(
        status: completing ? TaskStatus.completed : TaskStatus.needsAction,
      ),
    );
    _emit();
  }

  @override
  Future<DeleteToken> deleteTask(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    final t = _tasks[i];
    final token = DeleteToken(
      id: id,
      listId: t.listId,
      title: t.task.title,
      status: t.task.status,
      position: t.task.position,
      hadEtag: t.task.etag != null,
    );
    deleted.add(token);
    _tasks.removeAt(i);
    _emit();
    return token;
  }

  @override
  Future<void> undoDelete(DeleteToken token) async {}

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
  Future<int> clearCompleted(String listId) async => throw UnimplementedError();

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
  Future<void> reorderTask(String id, String direction) async {
    reordered.add('$id:$direction');
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
    final pos = sibIdx.indexWhere((i) => _tasks[i].task.id == id);
    final swap = direction == 'up' ? pos - 1 : pos + 1;
    if (swap < 0 || swap >= sibIdx.length) return; // boundary no-op
    final a = sibIdx[pos];
    final b = sibIdx[swap];
    final pa = _tasks[a].task.position;
    final pb = _tasks[b].task.position;
    _tasks[a] = _rebuild(_tasks[a], _tasks[a].task.copyWith(position: pb));
    _tasks[b] = _rebuild(_tasks[b], _tasks[b].task.copyWith(position: pa));
    _emit();
  }

  @override
  Future<String> moveTaskToList(String id, String targetListId) async {
    movedToList.add('$id->$targetListId');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return id;
    final old = _tasks[i];
    final newId = '$id-moved';
    _tasks[i] = StoredTask(
      task: old.task.copyWith(id: newId),
      listId: targetListId,
      syncState: SyncState.dirty,
      localUpdated: 't',
      pendingOp: 'create',
    );
    _emit();
    return newId;
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
      ],
      child: MaterialApp(
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
