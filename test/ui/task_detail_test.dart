// The detail-panel skeleton (T2.4) — WIDGET tests that drive the real
// [TaskDetail] and assert what RENDERS and which command the gesture fires. The
// backend is the same lightweight in-memory [Commands] double used by the list
// slice, so the tests stay off drift's real event queue (which the testWidgets
// fake zone cannot drain — see the widget-test-drift-async memory).
//
// Covered here: the two-level guard (a subtask's panel offers no add-subtask
// input — invariant #1; TwoLevelTree at the widget layer), subtask add-with-
// kept-focus + toggle, title/notes diff-only auto-save on blur, and the deleted-
// row reaction. The pure predicates behind the guard are unit-tested in
// task_tree_test.dart; these prove the panel actually honors them.

import 'dart:async';

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/dates.dart' show DateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTask row(
  String id,
  String title, {
  String? parent,
  bool done = false,
  String? notes,
  String position = '1',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// Records the commands the panel fires and re-emits the mutated task set on the
/// stream the panel watches — enough to exercise add / toggle / save / delete
/// without a database.
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

  Stream<List<StoredTask>> get tasksStream async* {
    yield List.of(_tasks);
    yield* _controller.stream;
  }

  void dispose() => _controller.close();
  void _emit() => _controller.add(List.of(_tasks));

  /// Simulate an external write (e.g. a sync pull) retitling a task, so tests
  /// can exercise the panel's live-tracking / clobber-avoidance.
  void pushExternal(String id, String title) {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(title: title),
      listId: _tasks[i].listId,
      syncState: _tasks[i].syncState,
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
    _tasks.add(t);
    _emit();
    return t;
  }

  @override
  Future<void> renameTask(String id, String title) async {
    renamed.add('$id=$title');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(title: title),
      listId: _tasks[i].listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
    );
    _emit();
  }

  @override
  Future<void> setNotes(String id, String notes) async {
    notesSet.add('$id=$notes');
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(notes: notes.isEmpty ? null : notes),
      listId: _tasks[i].listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
    );
    _emit();
  }

  @override
  Future<void> toggleComplete(String id) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    final completing = _tasks[i].task.status == TaskStatus.needsAction;
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(
        status: completing ? TaskStatus.completed : TaskStatus.needsAction,
      ),
      listId: _tasks[i].listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
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

  @override
  Future<SetDueResult> setDue(String id, DateMove move) async =>
      throw UnimplementedError();

  @override
  Future<SetDueResult> setDueRaw(String id, String rawDate) async =>
      throw UnimplementedError();

  @override
  Future<void> undoSetDue(List<DueUndoEntry> entries) async =>
      throw UnimplementedError();

  @override
  Future<int> clearCompleted(String listId) async => throw UnimplementedError();

  // T5.2 structural moves — the detail skeleton does not drive these yet.
  @override
  Future<void> moveTask(
    String id, {
    String? parentId,
    String? previousId,
  }) async => throw UnimplementedError();

  @override
  Future<void> reorderTask(String id, String direction) async =>
      throw UnimplementedError();

  @override
  Future<String> moveTaskToList(String id, String targetListId) async =>
      throw UnimplementedError();

  @override
  Future<void> freshSync() async => throw UnimplementedError();

  @override
  void setEditing(String? id) {}

  @override
  String? get heldCreateId => null;
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<FakeBackend> pumpDetail(
    WidgetTester tester, {
    required String taskId,
    required List<StoredTask> initial,
    List<String>? closed,
    List<String>? opened,
    String Function()? newId,
  }) async {
    final fake = FakeBackend(initial, newId: newId);
    addTearDown(fake.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commandsProvider.overrideWithValue(fake),
          allTasksProvider.overrideWith((ref) => fake.tasksStream),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TaskDetail(
              taskId: taskId,
              onClose: () => (closed ?? <String>[]).add('close'),
              onOpenTask: (opened ?? <String>[]).add,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return fake;
  }

  testWidgets('renders the task title and notes in editable fields', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      taskId: 'P',
      initial: [row('P', 'parent task', notes: 'some notes')],
    );
    expect(find.widgetWithText(TextField, 'parent task'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'some notes'), findsOneWidget);
  });

  group('two-level guard (TwoLevelTree)', () {
    testWidgets('a top-level task offers the add-subtask input', (
      tester,
    ) async {
      await pumpDetail(tester, taskId: 'P', initial: [row('P', 'parent')]);
      // The add-subtask field (its hint renders as a Text) and its + button.
      expect(find.widgetWithText(TextField, 'Add a subtask'), findsOneWidget);
      expect(find.byTooltip('Add subtask'), findsOneWidget);
      expect(find.text('Subtasks'), findsOneWidget);
    });

    testWidgets('a subtask panel offers NO add-subtask input (invariant #1)', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'S',
        initial: [
          row('P', 'parent'),
          row('S', 'child', parent: 'P'),
        ],
      );
      // A subtask can never gain a subtask — the whole section is absent.
      expect(find.byTooltip('Add subtask'), findsNothing);
      expect(find.text('Subtasks'), findsNothing);
      // The header names it a Subtask, not "Task Details".
      expect(find.text('Subtask'), findsOneWidget);
    });
  });

  group('subtasks', () {
    testWidgets('renders existing subtasks as a checklist under the parent', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid one', parent: 'P', position: '1'),
          row('C2', 'kid two', parent: 'P', position: '2', done: true),
        ],
      );
      expect(find.text('kid one'), findsOneWidget);
      expect(find.text('kid two'), findsOneWidget);
      // The completed subtask's checkbox is checked.
      final checks = tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .toList();
      expect(checks.where((c) => c.value == true), hasLength(1));
    });

    testWidgets(
      'typing a title and pressing Enter adds a subtask, keeps focus',
      (tester) async {
        final fake = await pumpDetail(
          tester,
          taskId: 'P',
          initial: [row('P', 'parent')],
          newId: () => 'NEW',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Add a subtask').first,
          'buy milk',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);

        // The new subtask renders under the parent…
        expect(find.text('buy milk'), findsOneWidget);
        final created = fake._tasks.firstWhere((t) => t.task.id == 'NEW');
        expect(created.task.parent, 'P', reason: 'born under the parent');
        // …and the field cleared + kept focus for the next entry.
        final field = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Add a subtask'),
        );
        expect(field.controller?.text, isEmpty);
        expect(field.focusNode?.hasFocus, isTrue);
      },
    );

    testWidgets('an empty add creates nothing (non-happy path)', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'parent')],
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Add a subtask'),
        '   ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(fake._tasks.where((t) => t.task.parent == 'P'), isEmpty);
    });

    testWidgets('tapping a subtask checkbox toggles its completion', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid', parent: 'P'),
        ],
      );
      await tester.tap(find.byType(Checkbox));
      await settle(tester);
      expect(
        fake._tasks.firstWhere((t) => t.task.id == 'C1').task.status,
        TaskStatus.completed,
      );
    });

    testWidgets('tapping a subtask title opens its own panel', (tester) async {
      final opened = <String>[];
      await pumpDetail(
        tester,
        taskId: 'P',
        initial: [
          row('P', 'parent'),
          row('C1', 'kid', parent: 'P'),
        ],
        opened: opened,
      );
      await tester.tap(find.text('kid'));
      await settle(tester);
      expect(opened, ['C1']);
    });
  });

  group('auto-save (diff-only, on blur)', () {
    testWidgets('an edited title saves once the field loses focus', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'old title')],
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'old title'),
        'new title',
      );
      // Move focus away → blur triggers the save.
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settle(tester);
      expect(fake.renamed, ['P=new title']);
    });

    testWidgets('an untouched field never queues a write (diff-only)', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'title', notes: 'notes')],
      );
      // Focus the title then blur it WITHOUT editing.
      await tester.tap(find.widgetWithText(TextField, 'title'));
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settle(tester);
      expect(fake.renamed, isEmpty);
      expect(fake.notesSet, isEmpty);
    });

    testWidgets('edited notes save on blur', (tester) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'title', notes: 'old')],
      );
      await tester.enterText(find.widgetWithText(TextField, 'old'), 'updated');
      await tester.tap(find.widgetWithText(TextField, 'Add a subtask'));
      await settle(tester);
      expect(fake.notesSet, ['P=updated']);
    });
  });

  group('live-tracking (without clobbering typing)', () {
    testWidgets('an external retitle refreshes an unfocused title field', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'v1')],
      );
      expect(find.widgetWithText(TextField, 'v1'), findsOneWidget);

      // A sync pull renames the task while the field is unfocused.
      fake.pushExternal('P', 'v2');
      await settle(tester);
      expect(find.widgetWithText(TextField, 'v2'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'v1'), findsNothing);
    });

    testWidgets('an external retitle does NOT clobber the field being typed in', (
      tester,
    ) async {
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'v1')],
      );
      // Focus the title and type — but do not blur (no save yet).
      await tester.tap(find.widgetWithText(TextField, 'v1'));
      await tester.enterText(find.widgetWithText(TextField, 'v1'), 'my draft');

      // A concurrent external write arrives (drift's table-granular
      // invalidation re-fires the watch); the user's in-progress text survives.
      fake.pushExternal('P', 'remote change');
      await settle(tester);
      expect(find.widgetWithText(TextField, 'my draft'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'remote change'), findsNothing);
    });
  });

  group('delete', () {
    testWidgets('the delete action removes the task, closes, offers Undo', (
      tester,
    ) async {
      final closed = <String>[];
      final fake = await pumpDetail(
        tester,
        taskId: 'P',
        initial: [row('P', 'doomed')],
        closed: closed,
      );
      await tester.tap(find.byTooltip('Delete'));
      await settle(tester);
      expect(fake.deleted, hasLength(1));
      expect(closed, ['close'], reason: 'panel closes after delete');
      // The undo affordance is reachable (the minimal home until the toast T7.8).
      expect(find.text('Undo'), findsOneWidget);
    });
  });

  testWidgets('a deleted task the panel is open on shows the missing state', (
    tester,
  ) async {
    await pumpDetail(tester, taskId: 'gone', initial: [row('P', 'parent')]);
    expect(find.text('This task is no longer available.'), findsOneWidget);
  });
}
