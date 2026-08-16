import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/task_lists_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets(
    'search opens child parent context and system back follows route state',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      final navigation = AppNavigationController();
      addTearDown(fixture.dispose);
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveShell(
            viewModel: fixture.viewModel,
            navigation: navigation,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Search tasks'));
      await tester.pumpAndSettle();
      expect(navigation.state.predictiveBackRoute, const SearchRoute());
      await tester.enterText(
        find.byKey(const Key('search-input')),
        'Cached child',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Matched subtask: Cached child'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('search-result-0')));
      await tester.pumpAndSettle();

      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      expect(
        find.text('Stored locally while verification is pending.'),
        findsOneWidget,
      );
      expect(
        navigation.state.predictiveBackRoute,
        const TaskDetailRoute(TaskId(11)),
      );

      fixture.viewModel.clearTaskSelection();
      await tester.pump();
      await tester.tap(find.byTooltip('Search tasks'));
      await tester.pumpAndSettle();
      expect(navigation.state.predictiveBackRoute, const SearchRoute());
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsNothing);
      expect(navigation.state.canHandlePredictiveBack, isFalse);
    },
  );

  testWidgets('compact drawer is a back-aware navigation route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    final navigation = AppNavigationController();
    addTearDown(fixture.dispose);
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(
          viewModel: fixture.viewModel,
          navigation: navigation,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    expect(navigation.state.predictiveBackRoute, const DrawerRoute());
    expect(find.text('SMART VIEWS'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(navigation.state.canHandlePredictiveBack, isFalse);
    expect(find.text('SMART VIEWS'), findsNothing);
  });

  testWidgets('dialog back leaves the detail route beneath it', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    final navigation = AppNavigationController();
    addTearDown(fixture.dispose);
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(
          viewModel: fixture.viewModel,
          navigation: navigation,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Cached parent'));
    await tester.pump();
    await tester.tap(find.byTooltip('Edit task content'));
    await tester.pumpAndSettle();

    expect(navigation.state.dialog, AppDialogKind.taskEdit);
    expect(navigation.state.routes.whereType<TaskDetailRoute>(), hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(navigation.state.dialog, isNull);
    expect(
      navigation.state.predictiveBackRoute,
      const TaskDetailRoute(TaskId(11)),
    );
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
    final addSubtask = find.widgetWithText(OutlinedButton, 'Add subtask');
    await tester.ensureVisible(addSubtask);
    await tester.tap(addSubtask);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'New child',
    );
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

  testWidgets(
    'collection rows exclude children and share direct-child progress with details',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _detailSnapshot,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      expect(find.text('First direct child'), findsNothing);
      expect(find.text('Completed direct child'), findsNothing);
      expect(find.text('1 of 2 subtasks complete'), findsOneWidget);

      await tester.tap(find.text('Long-note parent'));
      await tester.pump();

      expect(find.text('First direct child'), findsOneWidget);
      expect(find.text('Completed direct child'), findsOneWidget);
      expect(find.text('1 of 2 subtasks complete'), findsNWidgets(2));
    },
  );

  testWidgets('long Unicode and intentionally empty notes remain plain text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      snapshot: _detailSnapshot,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    await tester.tap(find.text('Long-note parent'));
    await tester.pump();
    expect(find.text(_longUnicodeNotes), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Task notes',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Edit task content'));
    await tester.pumpAndSettle();
    final notesField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Notes',
    );
    await tester.enterText(notesField, '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final command = fixture.tasks.applied.last as UpdateTaskContentCommand;
    expect(command.notes, '', reason: 'empty is distinct from cleared notes');
  });

  testWidgets(
    'subtask menu routes edit, reorder, promote, and delete commands',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _detailSnapshot,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Long-note parent'));
      await tester.pump();

      await tester.ensureVisible(find.byTooltip('Manage First direct child'));
      await tester.tap(find.byTooltip('Manage First direct child'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move subtask down'));
      await tester.pump();
      final move = fixture.tasks.applied.last as MoveTaskCommand;
      expect(move.taskId, const TaskId(22));
      expect(move.parentTaskId, const TaskId(21));
      expect(move.previousTaskId, const TaskId(23));

      await tester.ensureVisible(find.byTooltip('Manage First direct child'));
      await tester.tap(find.byTooltip('Manage First direct child'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Promote subtask'));
      await tester.pump();
      expect(fixture.tasks.applied.last, isA<PromoteTaskCommand>());

      await tester.ensureVisible(
        find.byTooltip('Manage Completed direct child'),
      );
      await tester.tap(find.byTooltip('Manage Completed direct child'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete subtask'));
      await tester.pump();
      expect(fixture.tasks.deleted.last.taskId, const TaskId(23));
    },
  );

  testWidgets('narrow detail takes focus and Escape returns to collection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(760, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      snapshot: _detailSnapshot,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.text('Long-note parent'));
    await tester.pump();

    expect(find.byTooltip('Back to task collection'), findsOneWidget);
    expect(find.byKey(const Key('task-detail-title')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('task-detail-title')), findsNothing);
    expect(find.text('Long-note parent'), findsOneWidget);
    expect(
      Focus.of(
        tester.element(find.byKey(const Key('desktop-task-row-21'))),
      ).hasFocus,
      isTrue,
    );
  });

  testWidgets('detail honors safe padding and two-times text scaling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      snapshot: _detailSnapshot,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.fromLTRB(18, 28, 14, 20),
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: AdaptiveShell(viewModel: fixture.viewModel),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Long-note parent'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('Axiotask')).dy,
      greaterThanOrEqualTo(28),
    );
    expect(find.byKey(const Key('task-detail-scroll-view')), findsOneWidget);
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
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Offline project',
      );
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
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Stopped rename',
    );
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
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '離線 🌍',
      );
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

  testWidgets('quick add previews target and terminal date before Enter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('quick-add-input')),
      'Send synthetic invoice tomorrow',
    );
    await tester.pump();

    expect(find.text('Create “Send synthetic invoice”'), findsOneWidget);
    expect(find.text('Synthetic inbox'), findsWidgets);
    expect(find.text('Due 2026-08-16'), findsOneWidget);
    expect(fixture.tasks.created, isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fixture.tasks.created.single.title, 'Send synthetic invoice');
    expect(fixture.tasks.created.single.due, TaskDate(2026, 8, 16));
  });

  testWidgets('quick add smart-view default is explicit before creation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Focus').first);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('quick-add-input')),
      'Visible smart capture',
    );
    await tester.pump();

    expect(find.text('Due 2026-08-15'), findsOneWidget);
    expect(find.text('Synthetic inbox'), findsWidgets);
    await tester.tap(find.byKey(const Key('quick-add-submit')));
    await tester.pumpAndSettle();

    expect(fixture.tasks.created.single.due, TaskDate(2026, 8, 15));
  });

  testWidgets('bulk paste previews and acknowledges one repository command', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bulk-add-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('bulk-add-input')),
      'Synthetic alpha\nSynthetic beta',
    );
    await tester.pump();

    expect(find.text('2 tasks ready'), findsOneWidget);
    expect(find.text('Target: Synthetic inbox'), findsOneWidget);
    expect(fixture.tasks.bulkCreated, isEmpty);
    await tester.tap(find.byKey(const Key('bulk-add-submit')));
    await tester.pumpAndSettle();

    expect(fixture.tasks.bulkCreated.single.entries, hasLength(2));
    expect(
      find.text('2 tasks saved locally and waiting for Google.'),
      findsOneWidget,
    );
  });

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
    await tester.enterText(titleField, 'Edited title');
    await tester.enterText(notesField, '空 🌍\nsecond line');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(fixture.tasks.applied, isEmpty, reason: 'editor text is transient');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final command = fixture.tasks.applied.single as UpdateTaskContentCommand;
    expect(command.taskId, const TaskId(11));
    expect(command.title, 'Edited title');
    expect(command.notes, '空 🌍\nsecond line');
    expect(command.due, TaskDate(2026, 8, 16));
  });

  testWidgets(
    'task detail routes completion, date shortcut, custom date, and durable Undo',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Cached parent'));
      await tester.pump();

      expect(find.text('2026-08-16'), findsWidgets);
      await tester.tap(find.byTooltip('Complete selected task'));
      await tester.pump();
      final completion =
          fixture.tasks.applied.single as SetTaskCompletionCommand;
      expect(completion.taskId, const TaskId(11));
      expect(completion.status, TaskStatus.completed);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today'));
      await tester.pump();
      expect(fixture.tasks.dueChanges.single.taskId, const TaskId(11));
      expect(fixture.tasks.dueChanges.single.due, TaskDate(2026, 8, 15));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Choose date'));
      await tester.pumpAndSettle();
      final dueField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Due date (YYYY-MM-DD)',
      );
      await tester.enterText(dueField, '2026-02-30');
      await tester.tap(find.widgetWithText(FilledButton, 'Set date'));
      await tester.pump();
      expect(find.text('Use a valid YYYY-MM-DD date.'), findsOneWidget);
      await tester.enterText(dueField, '2026-08-20');
      await tester.tap(find.widgetWithText(FilledButton, 'Set date'));
      await tester.pumpAndSettle();
      expect(fixture.tasks.dueChanges.last.due, TaskDate(2026, 8, 20));

      fixture.tasks.dueUndoController.add(<TaskDueChangeUndo>[
        TaskDueChangeUndo(
          groupId: 41,
          editedTaskId: const TaskId(11),
          editedTaskTitle: 'Cached parent',
          cascadedCount: 1,
          cascadedParent: false,
          createdAt: DateTime.utc(2026, 8, 15, 12),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.taskDueChangeUndos, hasLength(1));
      expect(
        TaskDetailViewModel.fromTasks(
          fixture.viewModel,
        ).state?.dueChangeUndo?.groupId,
        41,
      );
      expect(find.text('Date changed for 2 related tasks'), findsOneWidget);
      final undo = find.widgetWithText(TextButton, 'Undo due changes');
      await tester.ensureVisible(undo);
      await tester.tap(undo);
      await tester.pump();
      expect(fixture.tasks.dueUndos.single.groupId, 41);
    },
  );

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

  testWidgets(
    'PAR-DESKTOP-001 shortcuts are discoverable and do not capture text input',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      await tester.tap(find.byTooltip('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('Ctrl+N'), findsOneWidget);
      expect(find.text('Ctrl+F'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
      expect(find.text('M'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final input = find.byKey(const Key('quick-add-input'));
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );

      await tester.enterText(input, 'Edit date move stay literal');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(find.text('Edit task'), findsNothing);
      expect(find.text('Choose due date'), findsNothing);
      expect(find.text('Move task to list'), findsNothing);
      expect(fixture.tasks.deleted, isEmpty);
    },
  );

  testWidgets(
    'PAR-DESKTOP-001 task focus traverses rows and keyboard actions share routes',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        Focus.of(
          tester.element(find.byKey(const Key('desktop-navigation-pane'))),
        ).hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(fixture.viewModel.state.selectedSmartView, SmartView.all);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        Focus.of(
          tester.element(find.byKey(const Key('desktop-task-row-11'))),
        ).hasFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        Focus.of(
          tester.element(find.byKey(const Key('desktop-task-row-13'))),
        ).hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Leaf task'), findsWidgets);
      expect(find.byKey(const Key('task-detail-title')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        Focus.of(
          tester.element(find.byKey(const Key('desktop-detail-pane'))),
        ).hasFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Edit task'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(find.text('Choose due date'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(find.text('Move task to list'), findsOneWidget);
    },
  );

  testWidgets(
    'PAR-DESKTOP-002 hover and secondary-click actions do not reflow the row',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      final row = find.byKey(const Key('desktop-task-row-11'));
      final before = tester.getRect(row);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();
      expect(tester.getRect(row), before);
      expect(find.byTooltip('Open Cached parent'), findsOneWidget);
      expect(find.byTooltip('Task actions for Cached parent'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Task actions for Cached parent'),
        findsOneWidget,
      );

      await tester.tapAt(
        tester.getCenter(row),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Open details'), findsOneWidget);
      expect(find.text('Complete task'), findsOneWidget);
      expect(find.text('Edit task…'), findsOneWidget);
      expect(find.text('Choose date…'), findsOneWidget);
      expect(find.text('Move to list…'), findsOneWidget);
      expect(find.text('Delete task'), findsOneWidget);
    },
  );

  testWidgets(
    'PAR-DESKTOP-003 drag previews without reflow and drops through MOVE anchor',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      final source = find.byKey(const Key('desktop-task-row-13'));
      final target = find.byKey(const Key('desktop-task-row-11'));
      final sourceBefore = tester.getRect(source);
      final targetBefore = tester.getRect(target);
      expect(
        find.bySemanticsLabel(
          'Drag Leaf task to reorder or move. '
          'Move buttons are available in task details.',
        ),
        findsOneWidget,
      );
      final drag = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getTopLeft(target) + const Offset(80, 8));
      await tester.pump();

      expect(
        find.byKey(const Key('desktop-task-drag-preview')),
        findsOneWidget,
      );
      expect(
        find.text('Move “Leaf task” before “Cached parent”'),
        findsOneWidget,
      );
      expect(tester.getRect(source), sourceBefore);
      expect(tester.getRect(target), targetBefore);

      await drag.up();
      await tester.pumpAndSettle();
      final command = fixture.tasks.applied.single as MoveTaskCommand;
      expect(command.taskId, const TaskId(13));
      expect(command.destinationTaskListId, const TaskListId(7));
      expect(command.parentTaskId, isNull);
      expect(command.previousTaskId, isNull);
      expect(find.byKey(const Key('desktop-task-drag-preview')), findsNothing);
    },
  );

  testWidgets('drag cancel and invalid targets commit nothing', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    final source = find.byKey(const Key('desktop-task-row-13'));
    final drag = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(tester.getCenter(find.text('Focus').first));
    await tester.pump();
    expect(find.text('Cannot drop “Leaf task” here'), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();

    expect(fixture.tasks.applied, isEmpty);
    expect(find.text('Leaf task'), findsOneWidget);
  });

  testWidgets('touch input does not activate the Fedora pointer adapter', (
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

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('desktop-task-row-13'))),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(
      tester.getTopLeft(find.byKey(const Key('desktop-task-row-11'))) +
          const Offset(80, 8),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('desktop-task-drag-preview')), findsNothing);
    expect(fixture.tasks.applied, isEmpty);
  });

  testWidgets('dropping on another Google list uses stable cross-list move', (
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

    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('desktop-task-row-11'))),
      kind: PointerDeviceKind.mouse,
    );
    final archiveTarget = find.descendant(
      of: find.byKey(const Key('desktop-navigation-pane')),
      matching: find.text('Synthetic archive'),
    );
    await drag.moveTo(tester.getCenter(archiveTarget));
    await tester.pump();
    expect(
      find.text('Move “Cached parent” to “Synthetic archive”'),
      findsOneWidget,
    );
    await drag.up();
    await tester.pumpAndSettle();

    final command = fixture.tasks.applied.single as MoveTaskCommand;
    expect(command.taskId, const TaskId(11));
    expect(command.destinationTaskListId, const TaskListId(8));
    expect(command.parentTaskId, isNull);
    expect(command.previousTaskId, isNull);
  });

  testWidgets(
    'failed drag command clears preview and restores canonical projection',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.failed));
      fixture.tasks.applyResult = Future.value(
        const Outcome<void>.failure(
          Failure(
            code: 'sync.synthetic_structure_rejected',
            category: FailureCategory.remote,
            operation: FailureOperation.write,
            retry: RetryClassification.permanent,
            impact: 'Synthetic structure failure.',
            safeSummary: 'Synthetic structure failure.',
          ),
        ),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      final source = find.byKey(const Key('desktop-task-row-13'));
      final target = find.byKey(const Key('desktop-task-row-11'));
      final canonicalSourceTop = tester.getTopLeft(source).dy;
      final canonicalTargetTop = tester.getTopLeft(target).dy;
      final drag = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getTopLeft(target) + const Offset(80, 8));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(find.text('The task could not be saved safely.'), findsOneWidget);
      expect(find.byKey(const Key('desktop-task-drag-preview')), findsNothing);
      expect(
        tester.getTopLeft(target).dy,
        lessThan(tester.getTopLeft(source).dy),
      );
      expect(canonicalTargetTop, lessThan(canonicalSourceTop));
    },
  );

  testWidgets('drag autoscrolls the task collection near its edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.pending),
      snapshot: _scrollSnapshot,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('desktop-task-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.pixels, 0);
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('desktop-task-row-100'))),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(const Offset(600, 775));
    await tester.pump(const Duration(milliseconds: 180));
    expect(scrollable.position.pixels, greaterThan(0));
    await drag.up();
    await tester.pumpAndSettle();
  });

  testWidgets('desktop panes hold at named widths and high text scaling', (
    tester,
  ) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final width in <double>[1024, 1280, 1440]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: AdaptiveShell(viewModel: fixture.viewModel),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('desktop-navigation-pane')), findsOneWidget);
      expect(find.byKey(const Key('desktop-task-pane')), findsOneWidget);
      expect(find.byKey(const Key('desktop-detail-pane')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'desktop width $width');
    }
  });
}

final class _ShellFixture {
  _ShellFixture(
    SyncHealth health, {
    Future<void> Function()? refreshRequested,
    Future<void> Function()? stopSyncRequested,
    Future<void> Function()? resumeSyncRequested,
    TaskListsRepository? taskListsRepository,
    CachedTasksSnapshot? snapshot,
    Clock? clock,
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
      clock: clock,
    );
    tasks.snapshot = snapshot ?? _snapshot;
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

final class _TasksRepository implements TasksRepository, BulkTasksRepository {
  late CachedTasksSnapshot snapshot;
  Future<Outcome<TaskId>> createResult = Future.value(
    const Outcome<TaskId>.success(TaskId(90)),
  );
  Future<Outcome<void>> applyResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<BulkCreateTasksCommand> bulkCreated = <BulkCreateTasksCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  final undoController = StreamController<List<TaskDeleteUndo>>.broadcast();
  final dueUndoController =
      StreamController<List<TaskDueChangeUndo>>.broadcast();
  final List<SetTaskDueCommand> dueChanges = <SetTaskDueCommand>[];
  final List<UndoTaskDueChangeCommand> dueUndos = <UndoTaskDueChangeCommand>[];
  final List<DeleteTaskCommand> deleted = <DeleteTaskCommand>[];
  final List<UndoTaskDeleteCommand> undone = <UndoTaskDeleteCommand>[];

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) {
    created.add(command);
    return createResult;
  }

  @override
  Future<Outcome<List<TaskId>>> createTasks(
    BulkCreateTasksCommand command,
  ) async {
    bulkCreated.add(command);
    return Outcome.success(
      List<TaskId>.generate(
        command.entries.length,
        (index) => TaskId(100 + index),
      ),
    );
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
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => dueUndoController.stream;

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async {
    dueChanges.add(command);
    return const Outcome.success(TaskDueChangeReceipt(undo: null));
  }

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async {
    dueUndos.add(command);
    return const Outcome.success(null);
  }

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

final _scrollSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: _snapshot.taskLists,
  tasks: List<CachedTask>.generate(
    24,
    (index) => CachedTask(
      id: TaskId(100 + index),
      accountId: const AccountId(1),
      taskListId: const TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-scroll-$index'),
      title: 'Synthetic scroll task ${index + 1}',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
  ),
  completeness: CacheCompleteness.complete,
);

const _longUnicodeNotes =
    'Planning notes — 安全な合成データ 🌍\n'
    'Line 02 keeps whitespace and punctuation exactly.\n'
    'Line 03 remains untrusted plain text: <b>not markup</b>.\n'
    'Line 04 checks a comfortably long desktop reading flow.\n'
    'Line 05 checks scrolling without clipping the subtasks below.\n'
    'Line 06 checks Unicode preservation: café, naïve, résumé.\n'
    'Line 07 checks bidirectional-safe ordinary task text.\n'
    'Line 08 is synthetic and contains no personal data.';

final _detailSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: const <CachedTaskList>[
    CachedTaskList(
      id: TaskListId(7),
      accountId: AccountId(1),
      remoteId: TaskListRemoteId('synthetic-detail-list'),
      title: 'Detail fixtures',
    ),
  ],
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(21),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-detail-parent'),
      title: 'Long-note parent',
      notes: _longUnicodeNotes,
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(22),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(21),
      remoteId: TaskRemoteId('synthetic-detail-child-a'),
      title: 'First direct child',
      notes: '',
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(23),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(21),
      remoteId: TaskRemoteId('synthetic-detail-child-b'),
      title: 'Completed direct child',
      notes: null,
      status: TaskStatus.completed,
      due: null,
    ),
  ],
  completeness: CacheCompleteness.complete,
);
