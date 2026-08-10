// The All-Tasks slice — ports the NewTaskPrepend / QuickAdd / NewTaskDetailFollow
// [PORT] cases plus the checkbox-toggle path. These are WIDGET tests: they drive
// the real TaskListView and assert what RENDERS (the rows, the preview chip, the
// order) and the navigation the gesture fires. The store/command layers are
// covered against a real database in store_all_tasks_test.dart and
// commands_test.dart; here the backend is a lightweight in-memory double so the
// tests stay off drift's real-event-queue async (which the testWidgets fake
// zone cannot drain).

import 'dart:async';

import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/dates.dart' show DateMove, normalizeDue;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/task_list_view.dart';
import 'package:axiotask/src/ui/task_row.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

final _clock = Clock.fixed(DateTime.utc(2026, 6, 15, 12));

StoredTask row(
  String id,
  String title,
  String position, {
  bool done = false,
  String? parent,
  String? notes,
  String? due,
  bool dirty = false,
}) => StoredTask(
  task: Task(
    id: id,
    position: position,
    title: title,
    parent: parent,
    notes: notes,
    due: due,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    updated: 't',
  ),
  listId: 'L1',
  syncState: dirty ? SyncState.dirty : SyncState.clean,
  localUpdated: 't',
);

/// An in-memory stand-in for [Commands] that mutates a task list and re-emits it
/// on the stream the view watches — enough to exercise the widget's create /
/// pin / follow / toggle behavior without a database.
class FakeBackend implements Commands {
  FakeBackend(List<StoredTask> initial, {String Function()? newId})
    : _tasks = [...initial],
      _newId = newId ?? (() => 'gen');

  final List<StoredTask> _tasks;
  final String Function() _newId;
  final _controller = StreamController<List<StoredTask>>.broadcast();

  Stream<List<StoredTask>> get tasksStream async* {
    yield List.of(_tasks);
    yield* _controller.stream;
  }

  void dispose() => _controller.close();
  void _emit() => _controller.add(List.of(_tasks));

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
    _tasks.insert(0, t);
    _emit();
    return t;
  }

  @override
  Future<void> renameTask(String id, String title) async {
    final i = _tasks.indexWhere((t) => t.task.id == id);
    if (i < 0) return;
    _tasks[i] = StoredTask(
      task: _tasks[i].task.copyWith(title: title),
      listId: _tasks[i].listId,
      syncState: SyncState.dirty,
      localUpdated: 't',
      pendingOp: 'update',
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

  // The list slice never drives these (detail-panel / delete paths, T2.4); the
  // stubs only satisfy the [Commands] surface this double stands in for.
  @override
  Future<void> setNotes(String id, String notes) async {}

  @override
  Future<DeleteToken> deleteTask(String id) async => throw UnimplementedError();

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

  // T5.2 structural moves — the list slice does not drive these yet.
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

void main() {
  /// Bounded pump — pumpAndSettle hangs on a focused TextField's cursor timer.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<FakeBackend> pumpView(
    WidgetTester tester, {
    List<StoredTask> initial = const [],
    String? selectedTaskId,
    List<String>? opened,
    String Function()? newId,
    String viewId = 'all',
    bool showCompleted = false,
    List<Override> extraOverrides = const [],
  }) async {
    final fake = FakeBackend(initial, newId: newId);
    addTearDown(fake.dispose);
    await withClock(_clock, () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(
              Prefs(showCompleted: showCompleted),
            ),
            commandsProvider.overrideWithValue(fake),
            allTasksProvider.overrideWith((ref) => fake.tasksStream),
            ...extraOverrides,
            listsProvider.overrideWith(
              (ref) => Stream.value([
                StoredTaskList(
                  list: TaskList(
                    id: 'L1',
                    title: 'My Tasks',
                    etag: 'e1',
                    updated: 't',
                  ),
                  syncState: SyncState.clean,
                  localUpdated: 't',
                ),
              ]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TaskListView(
                viewId: viewId,
                selectedTaskId: selectedTaskId,
                onOpenTask: (opened ?? <String>[]).add,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    });
    return fake;
  }

  testWidgets('empty store shows the empty state and the quick-add bar', (
    tester,
  ) async {
    await pumpView(tester);
    expect(find.text('No tasks yet'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // always-visible quick-add
  });

  testWidgets('QuickAdd: creates a titled task without switching views', (
    tester,
  ) async {
    await pumpView(tester);
    await tester.enterText(find.byType(TextField), 'buy milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.widgetWithText(TaskRow, 'buy milk'), findsOneWidget);
  });

  testWidgets('QuickAdd: a blank submit creates nothing', (tester) async {
    await pumpView(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.byType(TaskRow), findsNothing);
    expect(find.text('No tasks yet'), findsOneWidget);
  });

  testWidgets(
    'QuickAdd: previews a trailing NL date and preserves the typed title',
    (tester) async {
      await pumpView(tester);
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'buy milk tomorrow');
        await tester.pump();
      });
      // Preview chip shows a FRIENDLY relative date, never the ISO (#78b).
      expect(find.widgetWithText(InputChip, 'tomorrow'), findsOneWidget);
      // The typed title is untouched in the field.
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text, 'buy milk tomorrow');
    },
  );

  testWidgets(
    'QuickAdd: keeping the date phrase as title text applies no due date',
    (tester) async {
      await pumpView(tester, newId: () => 'NEW');
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'call bank tomorrow');
        await tester.pump();
        // Dismiss the preview (the chip's ×) — keep the phrase as literal text.
        await tester.tap(
          find.descendant(
            of: find.byType(InputChip),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });
      // Row exists with the full phrase as its title…
      expect(
        find.widgetWithText(TaskRow, 'call bank tomorrow'),
        findsOneWidget,
      );
      // …and no due label was applied (a "tomorrow" due badge would be a
      // separate Text; there is none).
      expect(find.text('tomorrow'), findsNothing);
    },
  );

  testWidgets(
    'QuickAdd: an explicit YYYY-MM-DD applies the date, title verbatim',
    (tester) async {
      await pumpView(tester, newId: () => 'NEW');
      await withClock(_clock, () async {
        await tester.enterText(find.byType(TextField), 'pay rent 2026-07-01');
        await tester.pump();
        expect(find.widgetWithText(InputChip, 'Jul 1'), findsOneWidget);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
      });
      // The created row keeps the typed title verbatim…
      expect(
        find.widgetWithText(TaskRow, 'pay rent 2026-07-01'),
        findsOneWidget,
      );
      // …and renders the applied due as a friendly badge (not the ISO).
      expect(find.text('Jul 1'), findsOneWidget);
    },
  );

  testWidgets('NewTaskPrepend: a new task lands at the top of the list', (
    tester,
  ) async {
    await pumpView(
      tester,
      initial: [row('A', 'apples', '5'), row('B', 'bread', '6')],
      newId: () => 'NEW',
    );
    await tester.enterText(find.byType(TextField), 'zucchini');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final titles = tester
        .widgetList<TaskRow>(find.byType(TaskRow))
        .map((r) => r.title)
        .toList();
    expect(titles.first, 'zucchini', reason: 'pinned to top');
    expect(titles, containsAll(['apples', 'bread']));
  });

  testWidgets('checkbox completes a task and it leaves the open list', (
    tester,
  ) async {
    await pumpView(tester, initial: [row('A', 'apples', '5')]);
    expect(find.text('apples'), findsOneWidget);
    // The row's checkbox — the toolbar now also has a "Show completed" one.
    await tester.tap(
      find.descendant(
        of: find.byType(TaskRow),
        matching: find.byType(Checkbox),
      ),
    );
    await settle(tester);
    // Completed → hidden from the open list (show-completed defaults off).
    expect(find.text('apples'), findsNothing);
  });

  testWidgets('show-completed pref keeps completed tasks visible', (
    tester,
  ) async {
    await pumpView(
      tester,
      initial: [row('A', 'done thing', '5', done: true)],
      showCompleted: true,
    );
    // With the pref on, a completed task still renders (struck through).
    expect(find.text('done thing'), findsOneWidget);
  });

  group('NewTaskDetailFollow', () {
    testWidgets('an open panel follows to the newly created task', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpView(
        tester,
        initial: [row('A', 'apples', '5')],
        selectedTaskId: 'A', // panel open on a different task
        opened: opened,
        newId: () => 'NEW',
      );
      await tester.enterText(find.byType(TextField), 'zucchini');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(opened, ['NEW'], reason: 'panel follows to the new task');
    });

    testWidgets(
      'a closed panel stays closed when a task is created (non-happy path)',
      (tester) async {
        final opened = <String>[];
        await pumpView(
          tester,
          selectedTaskId: null, // panel closed
          opened: opened,
          newId: () => 'NEW',
        );
        await tester.enterText(find.byType(TextField), 'zucchini');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await settle(tester);
        expect(opened, isEmpty, reason: 'creating never opens the panel');
      },
    );
  });

  group('Toolbar', () {
    testWidgets('the show-completed toggle reveals completed tasks live', (
      tester,
    ) async {
      await pumpView(
        tester,
        initial: [
          row('A', 'apples', '5'),
          row('D', 'done thing', '6', done: true),
        ],
      );
      // Default hides the completed task…
      expect(find.text('done thing'), findsNothing);
      // …tapping the toolbar toggle (the live prefs path) reveals it.
      await tester.tap(find.byKey(const Key('show-completed-toggle')));
      await settle(tester);
      expect(find.text('done thing'), findsOneWidget);
    });

    testWidgets('picking a sort order reorders the rows live', (tester) async {
      await pumpView(
        tester,
        initial: [
          row('B', 'banana', '1'),
          row('A', 'apple', '2'),
          row('C', 'cherry', '3'),
        ],
      );
      // Manual (position) order first: banana, apple, cherry.
      var titles = tester
          .widgetList<TaskRow>(find.byType(TaskRow))
          .map((r) => r.title)
          .toList();
      expect(titles, ['banana', 'apple', 'cherry']);

      await tester.tap(find.byKey(const Key('sort-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alphabetical').last);
      await settle(tester);

      titles = tester
          .widgetList<TaskRow>(find.byType(TaskRow))
          .map((r) => r.title)
          .toList();
      expect(titles, ['apple', 'banana', 'cherry']);
    });

    testWidgets('a smart view with nothing to show has its own empty message', (
      tester,
    ) async {
      await pumpView(tester, viewId: 'focus');
      expect(find.text('All clear for this week'), findsOneWidget);
    });
  });

  group('FlatList (T7.2 metadata wiring)', () {
    testWidgets('a parent renders its subtask progress; subtasks are NEVER '
        'rows (invariant #1)', (tester) async {
      await pumpView(
        tester,
        initial: [
          row('P', 'ship release', '1'),
          row('C1', 'write notes', '1', parent: 'P', done: true),
          row('C2', 'tag build', '2', parent: 'P'),
          row('C3', 'announce', '3', parent: 'P'),
        ],
      );
      // Only the parent is a row.
      final rows = tester
          .widgetList<TaskRow>(find.byType(TaskRow))
          .map((r) => r.title)
          .toList();
      expect(rows, ['ship release']);
      // …and it carries the 1/3 progress from its subtasks.
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('an undated parent shows the inherited date from its earliest '
        'unfinished subtask', (tester) async {
      await pumpView(
        tester,
        initial: [
          row('P', 'plan trip', '1'), // no own date
          row('C1', 'book flight', '1', parent: 'P', due: '2026-07-20'),
          row('C2', 'book hotel', '2', parent: 'P', due: '2026-07-18'),
        ],
      );
      // Earliest unfinished subtask date (Jul 18) surfaces as the ↳ marker
      // (clock is fixed to 2026-06-15, so it renders as an absolute short date).
      expect(find.text('↳ Jul 18'), findsOneWidget);
    });

    testWidgets('a locally-edited row shows the pending-sync dot', (
      tester,
    ) async {
      await pumpView(
        tester,
        initial: [row('T', 'draft memo', '1', dirty: true)],
      );
      expect(find.byKey(const Key('pending-dot')), findsOneWidget);
    });

    testWidgets('a task with a URL exposes a link badge that opens via the '
        'opener', (tester) async {
      final opened = <String>[];
      await pumpView(
        tester,
        initial: [row('T', 'read https://example.com/rfc', '1')],
        extraOverrides: [
          urlOpenerProvider.overrideWithValue((url) async => opened.add(url)),
        ],
      );
      await tester.tap(find.byKey(const Key('link-badge')));
      await tester.pump();
      expect(opened, ['https://example.com/rfc']);
    });
  });
}
