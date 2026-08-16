import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/task_lists_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cached Pending shell exposes non-color status semantics', (
    tester,
  ) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    expect(find.text('Cached parent'), findsOneWidget);
    expect(find.text('Pending'), findsWidgets);
    expect(find.text('Verifying with Google'), findsOneWidget);
    expect(find.text('Last successful sync: Never'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Synchronization Pending. Verifying with Google. '
        'Last successful sync Never. 0 unresolved changes.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('every inactive and failed reason renders its allowed action', (
    tester,
  ) async {
    final cases = <(SyncHealth, String, String)>[
      (
        _health(
          SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.connect,
        ),
        'No authorization',
        'Connect',
      ),
      (
        _health(
          SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.reauthorize,
        ),
        'No authorization',
        'Reauthorize',
      ),
      (
        _health(
          SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.syncStopped,
          action: SyncHealthAction.resume,
        ),
        'Sync stopped',
        'Resume',
      ),
      for (final reason in SyncFailureReason.values)
        (
          _health(
            SyncHealthOutcome.failed,
            failureReason: reason,
            action: reason == SyncFailureReason.applicationFailure
                ? SyncHealthAction.none
                : SyncHealthAction.retry,
          ),
          switch (reason) {
            SyncFailureReason.noConnection => 'No connection',
            SyncFailureReason.remoteFailure => 'Google Tasks failed',
            SyncFailureReason.applicationFailure => 'Application failure',
            SyncFailureReason.stale => 'Cached data is stale',
          },
          reason == SyncFailureReason.applicationFailure ? '' : 'Retry',
        ),
    ];

    for (final (health, reason, action) in cases) {
      final fixture = _ShellFixture(health);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      expect(find.text(reason), findsOneWidget);
      if (action.isNotEmpty) expect(find.text(action), findsOneWidget);
      fixture.dispose();
    }
  });

  testWidgets('wide shell opens a read-only detail pane with subtasks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.text('Cached parent'));
    await tester.pump();

    expect(
      find.text('Stored locally while verification is pending.'),
      findsOneWidget,
    );
    expect(find.text('Subtasks'), findsOneWidget);
    expect(find.text('Cached child'), findsOneWidget);
    expect(find.text('Add task'), findsNothing);
  });

  testWidgets('task details add, promote, and demote one-level subtasks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.text('Cached parent'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add subtask'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New child');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(fixture.tasks.created.last.parentTaskId, const TaskId(11));

    await tester.tap(find.text('Cached child'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Change parent'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ListTile, 'Leaf task'),
      ),
    );
    await tester.pumpAndSettle();
    final reparent = fixture.tasks.applied.last as DemoteTaskCommand;
    expect(reparent.taskId, const TaskId(12));
    expect(reparent.parentTaskId, const TaskId(13));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Promote'));
    await tester.pump();
    expect(fixture.tasks.applied.last, isA<PromoteTaskCommand>());
    expect(
      (fixture.tasks.applied.last as PromoteTaskCommand).taskId,
      const TaskId(12),
    );

    await tester.tap(find.text('Leaf task'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Make subtask'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ListTile, 'Cached parent'),
      ),
    );
    await tester.pumpAndSettle();
    final demote = fixture.tasks.applied.last as DemoteTaskCommand;
    expect(demote.taskId, const TaskId(13));
    expect(demote.parentTaskId, const TaskId(11));
  });

  testWidgets('task details reorder by anchor and move across lists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.text('Leaf task'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Move up'));
    await tester.pump();
    final reorder = fixture.tasks.applied.last as MoveTaskCommand;
    expect(reorder.taskId, const TaskId(13));
    expect(reorder.destinationTaskListId, const TaskListId(7));
    expect(reorder.previousTaskId, isNull);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Move to list'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ListTile, 'Synthetic archive'),
      ),
    );
    await tester.pumpAndSettle();
    final crossList = fixture.tasks.applied.last as MoveTaskCommand;
    expect(crossList.taskId, const TaskId(13));
    expect(crossList.destinationTaskListId, const TaskListId(8));
    expect(crossList.parentTaskId, isNull);
  });

  testWidgets('Refresh button invokes the ViewModel foreground action', (
    tester,
  ) async {
    var refreshes = 0;
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.good),
      refreshRequested: () async {
        refreshes += 1;
      },
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Refresh'));
    await tester.pump();

    expect(refreshes, 1);
  });

  testWidgets('active sync exposes Stop and stopped sync exposes Resume', (
    tester,
  ) async {
    var stops = 0;
    var resumes = 0;
    var fixture = _ShellFixture(
      _health(SyncHealthOutcome.good),
      stopSyncRequested: () async {
        stops += 1;
      },
    );
    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop sync'));
    await tester.pump();
    expect(stops, 1);
    fixture.dispose();

    fixture = _ShellFixture(
      _health(
        SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.syncStopped,
        action: SyncHealthAction.resume,
      ),
      resumeSyncRequested: () async {
        resumes += 1;
      },
    );
    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    expect(find.widgetWithText(OutlinedButton, 'Stop sync'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Resume'));
    await tester.pump();
    expect(resumes, 1);
    fixture.dispose();
  });

  testWidgets(
    'create dialog has no local-only mode and disables duplicate submit',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final durable = Completer<Outcome<TaskListId>>();
      final lists = _TaskListsRepository()..createResult = durable.future;
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        taskListsRepository: lists,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      await tester.tap(find.byTooltip('Create Google task list'));
      await tester.pumpAndSettle();
      expect(find.text('Create task list'), findsOneWidget);
      expect(find.textContaining('local-only'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Offline project');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pump();
      final dialogSubmit = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(dialogSubmit).onPressed, isNull);
      await tester.tap(dialogSubmit, warnIfMissed: false);
      expect(lists.createCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      durable.complete(const Outcome<TaskListId>.success(TaskListId(31)));
      await tester.pumpAndSettle();
      expect(find.text('Create task list'), findsNothing);
    },
  );

  testWidgets('rename dialog submits the selected stable list identity', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lists = _TaskListsRepository();
    final fixture = _ShellFixture(
      _health(
        SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.syncStopped,
        action: SyncHealthAction.resume,
      ),
      taskListsRepository: lists,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.byTooltip('Rename selected task list'));
    await tester.pumpAndSettle();
    expect(find.text('Rename task list'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Stopped rename');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(lists.renamed, isEmpty, reason: 'uncommitted editor text is inert');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(lists.renamed.single.taskListId, const TaskListId(7));
    expect(lists.renamed.single.title, 'Stopped rename');
  });

  testWidgets(
    'task create waits for durable success and blocks duplicate taps',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final durable = Completer<Outcome<TaskId>>();
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      fixture.tasks.createResult = durable.future;
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      await tester.tap(find.byTooltip('Create task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '離線 🌍');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pump();
      final submit = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(submit, warnIfMissed: false);
      expect(fixture.tasks.created, hasLength(1));
      expect(fixture.tasks.created.single.taskListId, const TaskListId(7));

      durable.complete(const Outcome<TaskId>.success(TaskId(91)));
      await tester.pumpAndSettle();
      expect(find.text('Create task'), findsNothing);
    },
  );

  testWidgets('task content editor keeps text inert until one valid save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.text('Cached parent'));
    await tester.pump();
    await tester.tap(find.byTooltip('Edit task content'));
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Task title',
    );
    final notesField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Notes',
    );
    final dueField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Due date (YYYY-MM-DD)',
    );
    await tester.enterText(titleField, 'Edited title');
    await tester.enterText(notesField, '空 🌍\nsecond line');
    await tester.enterText(dueField, '2026-02-30');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(fixture.tasks.applied, isEmpty, reason: 'editor text is transient');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    expect(find.text('Use a valid YYYY-MM-DD date.'), findsOneWidget);
    expect(fixture.tasks.applied, isEmpty);

    await tester.enterText(dueField, '2026-08-20');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final command = fixture.tasks.applied.single as UpdateTaskContentCommand;
    expect(command.taskId, const TaskId(11));
    expect(command.title, 'Edited title');
    expect(command.notes, '空 🌍\nsecond line');
    expect(command.due, TaskDate(2026, 8, 20));
  });

  testWidgets('completion control sends one status command', (tester) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.byTooltip('Complete task').first);
    await tester.pump();

    final command = fixture.tasks.applied.single as SetTaskCompletionCommand;
    expect(command.taskId, const TaskId(11));
    expect(command.status, TaskStatus.completed);
  });

  testWidgets(
    'task delete hides through repository and durable Undo restores it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Cached parent'));
      await tester.pump();

      await tester.tap(find.byTooltip('Delete task'));
      await tester.pump();
      expect(fixture.tasks.deleted.single.taskId, const TaskId(11));

      fixture.tasks.undoController.add(<TaskDeleteUndo>[
        TaskDeleteUndo(
          taskId: const TaskId(11),
          title: 'Cached parent',
          notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
        ),
      ]);
      await tester.pump();
      expect(find.text('“Cached parent” deleted'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Undo'));
      await tester.pump();
      expect(fixture.tasks.undone.single.taskId, const TaskId(11));
    },
  );

  testWidgets('task list deletion requires explicit destructive confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lists = _TaskListsRepository();
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      taskListsRepository: lists,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.byTooltip('Delete selected task list'));
    await tester.pumpAndSettle();
    expect(find.text('Delete “Synthetic inbox”?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(lists.deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(lists.deleted, isEmpty);

    await tester.tap(find.byTooltip('Delete selected task list'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete list'));
    await tester.pumpAndSettle();
    expect(lists.deleted.single.taskListId, const TaskListId(7));
  });
}

final class _ShellFixture {
  _ShellFixture(
    SyncHealth health, {
    Future<void> Function()? refreshRequested,
    Future<void> Function()? stopSyncRequested,
    Future<void> Function()? resumeSyncRequested,
    TaskListsRepository? taskListsRepository,
  }) : tasks = _TasksRepository(),
       healthRepository = _HealthRepository() {
    viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      taskListsRepository: taskListsRepository,
      syncHealthRepository: healthRepository,
      refreshRequested: refreshRequested,
      stopSyncRequested: stopSyncRequested,
      resumeSyncRequested: resumeSyncRequested,
    );
    tasks.snapshot = _snapshot;
    healthRepository.health = health;
  }

  final _TasksRepository tasks;
  final _HealthRepository healthRepository;
  late final TasksViewModel viewModel;

  Widget get widget => MaterialApp(home: AdaptiveShell(viewModel: viewModel));

  void dispose() => viewModel.dispose();
}

final class _TaskListsRepository implements TaskListsRepository {
  Future<Outcome<TaskListId>> createResult = Future.value(
    const Outcome<TaskListId>.success(TaskListId(99)),
  );
  Future<Outcome<void>> renameResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<RenameTaskListCommand> renamed = <RenameTaskListCommand>[];
  final List<DeleteTaskListCommand> deleted = <DeleteTaskListCommand>[];
  var createCalls = 0;

  @override
  Future<Outcome<TaskListId>> createTaskList(CreateTaskListCommand command) {
    createCalls += 1;
    return createResult;
  }

  @override
  Future<Outcome<void>> renameTaskList(RenameTaskListCommand command) {
    renamed.add(command);
    return renameResult;
  }

  @override
  Future<Outcome<void>> deleteTaskList(DeleteTaskListCommand command) async {
    deleted.add(command);
    return const Outcome<void>.success(null);
  }
}

final class _TasksRepository implements TasksRepository {
  late CachedTasksSnapshot snapshot;
  Future<Outcome<TaskId>> createResult = Future.value(
    const Outcome<TaskId>.success(TaskId(90)),
  );
  Future<Outcome<void>> applyResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  final undoController = StreamController<List<TaskDeleteUndo>>.broadcast();
  final List<DeleteTaskCommand> deleted = <DeleteTaskCommand>[];
  final List<UndoTaskDeleteCommand> undone = <UndoTaskDeleteCommand>[];

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) {
    created.add(command);
    return createResult;
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) {
    applied.add(command);
    return applyResult;
  }

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      Stream.value(snapshot);

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      undoController.stream;

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async {
    deleted.add(command);
    return Outcome<TaskDeleteReceipt>.success(
      TaskDeleteReceipt(
        taskId: command.taskId,
        notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
      ),
    );
  }

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async {
    undone.add(command);
    return const Outcome<void>.success(null);
  }
}

final class _HealthRepository implements SyncHealthRepository {
  late SyncHealth health;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(health);
}

SyncHealth _health(
  SyncHealthOutcome outcome, {
  SyncInactiveReason? inactiveReason,
  SyncFailureReason? failureReason,
  SyncHealthAction action = SyncHealthAction.none,
}) => SyncHealth(
  outcome: outcome,
  inactiveReason: inactiveReason,
  failureReason: failureReason,
  pendingReason: outcome == SyncHealthOutcome.pending
      ? SyncPendingReason.verifying
      : null,
  action: action,
  counts: const SyncWorkCounts(),
  lastSuccessfulSyncAt: null,
  evaluatedAt: DateTime.utc(2026, 8, 15, 12),
);

final _snapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-list'),
      title: 'Synthetic inbox',
    ),
    CachedTaskList(
      id: TaskListId(8),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-archive'),
      title: 'Synthetic archive',
    ),
  ],
  tasks: <CachedTask>[
    CachedTask(
      id: TaskId(11),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-parent'),
      title: 'Cached parent',
      notes: 'Stored locally while verification is pending.',
      status: TaskStatus.needsAction,
      due: TaskDate(2026, 8, 16),
    ),
    const CachedTask(
      id: TaskId(12),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(11),
      remoteId: TaskRemoteId('synthetic-child'),
      title: 'Cached child',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    const CachedTask(
      id: TaskId(13),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-leaf'),
      title: 'Leaf task',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);
