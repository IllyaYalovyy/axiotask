import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/app/navigation_state.dart';
import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/policy/task_duplication.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/task_lists_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:axiotask/src/features/tasks/task_detail_view_model.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/features/tasks/widgets/task_details.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/calendar_date.dart';
import '../../support/selection_toolbar.dart';
import '../../support/touch_targets.dart';

void main() {
  group('short phone feedback keeps task rows available', () {
    setUpAll(loadAndroidTextFont);
    for (final outcome in SyncHealthOutcome.values) {
      testWidgets('startup and $outcome at landscape 2x', (tester) async {
        await _pumpPhoneShell(
          tester,
          const PhoneViewport(320, PhoneOrientation.landscape, 2),
          health: _health(outcome),
        );
        expect(tester.takeException(), isNull);
        final feedback = tester.getSize(
          find.byKey(const Key('shell-feedback-scroll')),
        );
        expect(feedback.height, lessThanOrEqualTo(124));
        final rows = find.byKey(const Key('desktop-task-scroll'));
        expect(tester.getSize(rows).height, greaterThan(48));
        await tester.ensureVisible(find.text('Cached parent'));
        expect(find.text('Cached parent').hitTestable(), findsOneWidget);
        final details = find.byKey(const Key('sync-health-details'));
        if (details.evaluate().isNotEmpty) {
          await tester.ensureVisible(details);
          await tester.pumpAndSettle();
          expectTouchTarget(tester, details, label: 'Sync details');
          await tester.tap(details);
          await tester.pumpAndSettle();
          expect(find.text('Close'), findsOneWidget);
        }
      });
    }
  });

  for (final width in <double>[412, 1280]) {
    testWidgets('routine sync stays compact at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        SyncHealth(
          outcome: SyncHealthOutcome.pending,
          pendingReason: SyncPendingReason.verifying,
          counts: const SyncWorkCounts(),
          lastSuccessfulSyncAt: DateTime.utc(2026, 8, 15, 12),
          evaluatedAt: DateTime.utc(2026, 8, 15, 12, 1),
        ),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      expect(find.byKey(const Key('sync-health-pending')), findsOneWidget);
      expect(find.textContaining('Verifying with Google'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('sync-health-pending')));
      await tester.pumpAndSettle();
      expect(find.text('Pending: Verifying with Google'), findsOneWidget);
    });
  }

  testWidgets('cached Pending shell exposes non-color status semantics', (
    tester,
  ) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    expect(find.text('Cached parent'), findsOneWidget);
    expect(find.textContaining('Pending'), findsWidgets);
    expect(find.textContaining('Verifying with Google'), findsOneWidget);
    expect(find.text('Last successful sync: Never'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Synchronization Pending. Verifying with Google. '
        'No unresolved changes. Checking Google for changes. '
        'Last successful sync Never.',
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
            SyncFailureReason.applicationFailure =>
              'Sync could not finish. Cause unknown',
            SyncFailureReason.stale => 'Cached data is stale',
          },
          reason == SyncFailureReason.applicationFailure ? '' : 'Retry',
        ),
    ];

    for (final (health, reason, action) in cases) {
      final fixture = _ShellFixture(health);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      expect(find.textContaining(reason), findsOneWidget);
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
    'search opens the matched child in its parent context and system back '
    'follows route state',
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

      expect(fixture.viewModel.state.selectedTaskId, const TaskId(12));
      expect(find.widgetWithText(TextField, 'Cached child'), findsOneWidget);
      expect(find.byTooltip('Back to parent task'), findsOneWidget);
      expect(navigation.state.routes, <AppRoute>[
        const CollectionRoute(),
        const TaskDetailRoute(TaskId(12)),
      ]);

      // Back walks up to the parent's details, then to the collection.
      await tester.binding.handlePopRoute();
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
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      expect(navigation.state.canHandlePredictiveBack, isFalse);

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
    final addSubtask = find.widgetWithText(TextButton, 'Add subtask');
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
    // Each task's details open scrolled to their top (title and notes).
    await tester.ensureVisible(
      find.byKey(const Key('task-detail-structure-menu')),
    );
    await tester.tap(find.byKey(const Key('task-detail-structure-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change parent'));
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

    await tester.ensureVisible(
      find.byKey(const Key('task-detail-structure-menu')),
    );
    await tester.tap(find.byKey(const Key('task-detail-structure-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Promote to task'));
    await tester.pump();
    expect(fixture.tasks.applied.last, isA<PromoteTaskCommand>());
    expect(
      (fixture.tasks.applied.last as PromoteTaskCommand).taskId,
      const TaskId(12),
    );

    await tester.tap(find.text('Leaf task'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('task-detail-structure-menu')),
    );
    await tester.tap(find.byKey(const Key('task-detail-structure-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make subtask'));
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
    final moveUp = find.widgetWithText(OutlinedButton, 'Move up');
    await tester.ensureVisible(moveUp);
    await tester.tap(moveUp);
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
      expect(find.text('1 of 2 subtasks complete'), findsNWidgets(2));
    },
  );

  testWidgets(
    'details hide completed subtasks by default and the toggle shows and hides them',
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

      final toggle = find.byKey(const Key('toggle-completed-subtasks'));
      expect(find.text('First direct child'), findsOneWidget);
      expect(find.text('Completed direct child'), findsNothing);
      expect(find.text('Show 1 completed subtask'), findsOneWidget);

      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Completed direct child'), findsOneWidget);
      expect(find.text('Hide completed subtasks'), findsOneWidget);

      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Completed direct child'), findsNothing);
      expect(find.text('Show 1 completed subtask'), findsOneWidget);
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

      final toggle = find.byKey(const Key('toggle-completed-subtasks'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
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
      Focus.of(tester.element(find.byKey(const Key('desktop-task-row-21'))))
          .hasFocus,
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
        theme: axiotaskTheme(
          Brightness.light,
          DensityPreference.standard,
          platform: TargetPlatform.linux,
        ),
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
      tester.getTopLeft(find.byKey(const Key('desktop-application-header'))).dy,
      greaterThanOrEqualTo(28),
    );
    expect(find.byKey(const Key('task-detail-scroll-view')), findsOneWidget);
  });

  testWidgets(
    'compact inspector keeps one due control and lower actions reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _detailSnapshot,
      );
      addTearDown(fixture.dispose);
      fixture.viewModel.start();
      final detail = TaskDetailViewModel.fromTasks(fixture.viewModel);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: detail,
              builder: (context, _) =>
                  TaskDetailsPane(viewModel: detail, compact: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Select a cached task to view details'), findsOneWidget);
      expect(
        find.byKey(const Key('task-detail-empty-scroll-view')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      fixture.viewModel.selectTask(const TaskId(21));
      await tester.pumpAndSettle();

      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Due'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);
      expect(find.text('Google Tasks'), findsOneWidget);
      expect(find.text('Subtasks'), findsOneWidget);
      expect(find.byKey(const Key('task-detail-due-action')), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Choose date'), findsNothing);

      final inspector = find.byKey(const Key('task-detail-scroll-view'));
      await tester.drag(inspector, const Offset(0, -1200));
      await tester.pumpAndSettle();
      final taskActions = find.byKey(const Key('task-detail-actions-menu'));
      await tester.ensureVisible(taskActions);
      expect(taskActions, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();

    expect(refreshes, 1);
  });

  testWidgets('Refresh is disabled until an account is authorized', (
    tester,
  ) async {
    final fixture = _ShellFixture(
      _health(
        SyncHealthOutcome.inactive,
        inactiveReason: SyncInactiveReason.noAuthorization,
        action: SyncHealthAction.connect,
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    final refresh = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(refresh.onPressed, isNull);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Refresh is disabled when no foreground action exists', (
    tester,
  ) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    final refresh = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(refresh.onPressed, isNull);
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
    await tester.tap(find.byTooltip('Stop sync'));
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
    expect(find.byTooltip('Stop sync'), findsNothing);
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

      await _chooseCollectionAction(tester, 'Create Google task list');
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

    await _chooseCollectionAction(tester, 'Rename task list');
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

      await _chooseCollectionAction(tester, 'Add task with details');
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

    await _chooseCollectionAction(tester, 'Paste multiple tasks');
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

  group('inline detail editing', () {
    const phone = Size(412, 900);
    final title = find.byKey(const Key('task-detail-title'));
    final notes = find.byKey(const Key('task-detail-notes'));
    const debounce = TaskContentAutosave.defaultDebounce;

    Future<_ShellFixture> openPhoneDetail(WidgetTester tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Cached parent'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      return fixture;
    }

    List<String> writes(_ShellFixture fixture) => <String>[
      for (final command in fixture.tasks.applied)
        switch (command) {
          SetTaskTitleCommand(:final taskId, :final title) =>
            '${taskId.value} title $title',
          SetTaskNotesCommand(:final taskId, :final notes) =>
            '${taskId.value} notes $notes',
          _ => '${command.taskId.value} ${command.runtimeType}',
        },
    ];

    testWidgets('title and multiline notes are fields that save on blur', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      expect(find.widgetWithText(TextField, 'Cached parent'), findsOneWidget);
      expect(
        find.widgetWithText(
          TextField,
          'Stored locally while verification is pending.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(notes).keyboardType,
        TextInputType.multiline,
      );

      await tester.tap(title);
      await tester.enterText(title, 'Renamed parent');
      await tester.pump();
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(fixture.tasks.applied, isEmpty, reason: 'still typing');
      // Moving focus to the notes stores the title without a Save button.
      await tester.tap(notes);
      await tester.pump();
      expect(writes(fixture), <String>['11 title Renamed parent']);
      await tester.enterText(notes, 'Line one\nLine two');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(writes(fixture), <String>[
        '11 title Renamed parent',
        '11 notes Line one\nLine two',
      ]);
      expect(find.text('Changes save automatically'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    });

    testWidgets('viewing a padded-title task changes nothing', (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: CachedTasksSnapshot(
          accountId: _snapshot.accountId,
          taskLists: _snapshot.taskLists,
          tasks: <CachedTask>[
            _snapshot.tasks.first.copyWith(title: '  Padded parent '),
            ..._snapshot.tasks.skip(1),
          ],
          completeness: _snapshot.completeness,
        ),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.textContaining('Padded parent'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      expect(find.text('Changes save automatically'), findsOneWidget);
      expect(
        find.text('Enter a title. The saved title stays until you do.'),
        findsNothing,
      );
      await tester.pump(debounce * 2);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      expect(fixture.tasks.applied, isEmpty, reason: 'nothing was edited');
    });

    testWidgets('typing saves after a pause and Back stores the rest', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      await tester.tap(notes);
      for (final text in <String>['N', 'No', 'Not', 'Note']) {
        await tester.enterText(notes, text);
        await tester.pump(debounce ~/ 2);
      }
      expect(fixture.tasks.applied, isEmpty, reason: 'one save per burst');
      await tester.pump(debounce);
      expect(writes(fixture), <String>['11 notes Note']);

      await tester.enterText(notes, 'Notes before Back');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      expect(writes(fixture), <String>[
        '11 notes Note',
        '11 notes Notes before Back',
      ]);
    });

    testWidgets('opening a subtask stores the parent edit for the parent', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      await tester.tap(title);
      await tester.enterText(title, 'Parent while switching');
      await tester.pump();
      final child = find.text('Cached child');
      await tester.ensureVisible(child);
      await tester.tap(child);
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(12));
      expect(find.widgetWithText(TextField, 'Cached child'), findsOneWidget);
      expect(writes(fixture), <String>['11 title Parent while switching']);

      await tester.tap(title);
      await tester.enterText(title, 'Child renamed');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      expect(writes(fixture), <String>[
        '11 title Parent while switching',
        '12 title Child renamed',
      ]);
    });

    testWidgets('a failed save keeps the text and offers Retry', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      fixture.tasks.applyResult = Future.value(
        const Outcome<void>.failure(
          Failure(
            code: 'task.persistence_failed',
            category: FailureCategory.persistence,
            operation: FailureOperation.write,
            retry: RetryClassification.transient,
            impact: 'The task was not saved.',
            safeSummary: 'Synthetic persistence failure.',
          ),
        ),
      );
      await tester.tap(notes);
      await tester.enterText(notes, 'Must not be lost');
      await tester.pump(debounce);
      await tester.pump();
      expect(
        find.text(
          'Not saved: The task could not be saved safely. '
          'Your text is kept here.',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextField, 'Must not be lost'),
        findsOneWidget,
      );

      // Leaving and returning still shows the unsaved text.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cached parent'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'Must not be lost'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('task-content-save-failure')),
        findsOneWidget,
      );

      fixture.tasks.applyResult = Future.value(
        const Outcome<void>.success(null),
      );
      await tester.ensureVisible(
        find.byKey(const Key('task-content-save-retry')),
      );
      await tester.tap(find.byKey(const Key('task-content-save-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-content-save-failure')), findsNothing);
      expect(writes(fixture).last, '11 notes Must not be lost');
    });

    testWidgets('an empty title is rejected and the notes still save', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      await tester.tap(title);
      await tester.enterText(title, '');
      await tester.pump();
      expect(
        find.text('Enter a title. The saved title stays until you do.'),
        findsOneWidget,
      );
      await tester.tap(notes);
      await tester.enterText(notes, 'Notes kept');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(writes(fixture), <String>['11 notes Notes kept']);

      // Leaving keeps the stored title; the next visit shows it again.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cached parent'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Cached parent'), findsOneWidget);
      expect(writes(fixture), <String>['11 notes Notes kept']);
    });

    testWidgets('keyboard composition defers saving until it commits', (
      tester,
    ) async {
      final fixture = await openPhoneDetail(tester);
      await tester.tap(notes);
      await tester.enterText(notes, 'Draft ');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Draft かな',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 6, end: 8),
        ),
      );
      await tester.pump(debounce * 3);
      expect(fixture.tasks.applied, isEmpty, reason: 'composition is open');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Draft 仮名',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump(debounce);
      expect(writes(fixture), <String>['11 notes Draft 仮名']);

      // Leaving mid-composition stores the text the field shows.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Draft 仮名 x',
          selection: TextSelection.collapsed(offset: 10),
          composing: TextRange(start: 9, end: 10),
        ),
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(writes(fixture), <String>[
        '11 notes Draft 仮名',
        '11 notes Draft 仮名 x',
      ]);
    });

    testWidgets('backgrounding the app stores a pending edit', (tester) async {
      final fixture = await openPhoneDetail(tester);
      await tester.tap(notes);
      await tester.enterText(notes, 'Saved on pause');
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(writes(fixture), <String>['11 notes Saved on pause']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    });
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

      await tester.tap(find.byKey(const Key('task-detail-due-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today'));
      await tester.pump();
      expect(fixture.tasks.dueChanges.single.taskId, const TaskId(11));
      expect(fixture.tasks.dueChanges.single.due, TaskDate(2026, 8, 15));

      await tester.tap(find.byKey(const Key('task-detail-due-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose date'));
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
        TaskDetailViewModel.fromTasks(fixture.viewModel)
            .state
            ?.dueChangeUndo
            ?.groupId,
        41,
      );
      expect(find.text('Date changed for 2 related tasks'), findsOneWidget);
      final undo = find.widgetWithText(TextButton, 'Undo due changes');
      await tester.ensureVisible(undo);
      await tester.tap(undo);
      await tester.pump();
      expect(fixture.tasks.dueUndos.single.groupId, 41);
    },
    // Desktop keeps the keyboard-first typed date; touch platforms get the
    // calendar (see the phone calendar group).
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
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

      final taskActions = find.byKey(const Key('task-detail-actions-menu'));
      await tester.ensureVisible(taskActions);
      await tester.tap(taskActions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete task'));
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

  testWidgets(
    'phone task details offer Duplicate as a reachable action that copies '
    'the open task through the repository (Android audit 14)',
    (tester) async {
      tester.view.physicalSize = const Size(443, 986);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Cached parent'));
      await tester.pumpAndSettle();

      final taskActions = find.byKey(const Key('task-detail-actions-menu'));
      await tester.ensureVisible(taskActions);
      await tester.pumpAndSettle();
      await tester.tap(taskActions);
      await tester.pumpAndSettle();
      final duplicate = find.byKey(const Key('task-detail-duplicate'));
      expect(find.textContaining('Duplicate').hitTestable(), findsOneWidget);
      expect(tester.getSize(duplicate).height, greaterThanOrEqualTo(48));
      await tester.tap(duplicate);
      await tester.pumpAndSettle();

      expect(fixture.tasks.duplicated.single.sourceTaskId, const TaskId(11));
      expect(fixture.tasks.created, isEmpty, reason: 'no raw create bypass');
      expect(
        fixture.viewModel.state.selectedTaskId,
        const TaskId(11),
        reason: 'the source stays open, as in v1.5.3',
      );
      final confirmation = find.byKey(const Key('task-detail-duplicated'));
      await tester.ensureVisible(confirmation);
      expect(find.text('Duplicated as “Cached parent (copy)”'), findsOneWidget);
      expect(
        find.byKey(const Key('task-detail-open-duplicate')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pump(TasksViewModel.transientFeedbackDuration);
      await tester.pumpAndSettle();
      expect(confirmation, findsNothing);
    },
  );

  testWidgets('Duplicate is not offered without a duplication repository', (
    tester,
  ) async {
    final repository = _TasksRepository()..snapshot = _snapshot;
    final model = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: _PlainTasksRepository(repository),
      syncHealthRepository: _HealthRepository()
        ..health = _health(SyncHealthOutcome.pending),
    );
    addTearDown(model.dispose);
    model.start();
    await tester.pump();
    model.selectTask(const TaskId(11));
    final detail = TaskDetailViewModel.fromTasks(model);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: detail,
            builder: (context, _) =>
                TaskDetailsPane(viewModel: detail, compact: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final taskActions = find.byKey(const Key('task-detail-actions-menu'));
    await tester.ensureVisible(taskActions);
    await tester.tap(taskActions);
    await tester.pumpAndSettle();

    expect(find.text('Delete task'), findsOneWidget);
    expect(find.byKey(const Key('task-detail-duplicate')), findsNothing);
  });

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

    await _chooseCollectionAction(tester, 'Delete task list');
    await tester.pumpAndSettle();
    expect(find.text('Delete “Synthetic inbox”?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(lists.deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(lists.deleted, isEmpty);

    await _chooseCollectionAction(tester, 'Delete task list');
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

      await tester.tap(find.byTooltip('More app actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
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

  testWidgets('desktop header opens Settings with native navigation', (
    tester,
  ) async {
    final fixture = _ShellFixture(_health(SyncHealthOutcome.pending));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AdaptiveShell(
          viewModel: fixture.viewModel,
          settingsBuilder: (_) => const Scaffold(
            body: Center(child: Text('Settings presentation')),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('More app actions'), findsOneWidget);
    await tester.tap(find.byTooltip('More app actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings presentation'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Settings presentation'), findsNothing);
  });

  testWidgets(
    'desktop header keeps frequent controls visible and app actions in overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in <double>[800, 1024, 1280]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        final fixture = _ShellFixture(
          _health(SyncHealthOutcome.good),
          refreshRequested: () async {},
          stopSyncRequested: () async {},
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: axiotaskTheme(
              Brightness.light,
              DensityPreference.standard,
              platform: TargetPlatform.linux,
            ),
            home: AdaptiveShell(
              viewModel: fixture.viewModel,
              diagnosticsBuilder: (_) => const Scaffold(),
              settingsBuilder: (_) => const Scaffold(),
              accountBackupBuilder: (_) => const Scaffold(),
              localDataRecoveryBuilder: (_) => const Scaffold(),
            ),
          ),
        );
        await tester.pump();

        final expectedActions = <String>[
          if (width < 900) 'Open navigation',
          'Search tasks',
          'Refresh',
          'Stop sync',
          'More app actions',
        ];
        for (final label in expectedActions) {
          final action = find.byTooltip(label);
          expect(action, findsOneWidget, reason: '$label at ${width}px');
          expect(action.hitTestable(), findsOneWidget, reason: label);
          final center = tester.getCenter(action);
          expect(center.dx, inInclusiveRange(0, width), reason: label);
          expect(center.dy, inInclusiveRange(0, 800), reason: label);
        }
        expect(tester.takeException(), isNull, reason: '${width}px header');
        expect(find.text('Axiotask'), findsNothing);
        expect(
          find.byKey(const Key('desktop-application-header')),
          findsOneWidget,
        );
        expect(
          tester
              .getSize(find.byKey(const Key('desktop-application-header')))
              .height,
          lessThanOrEqualTo(64),
        );
        final focusOrders = tester
            .widgetList<FocusTraversalOrder>(
              find.descendant(
                of: find.byKey(const Key('desktop-application-header')),
                matching: find.byType(FocusTraversalOrder),
              ),
            )
            .map((widget) => (widget.order as NumericFocusOrder).order)
            .toList();
        expect(
          focusOrders,
          width < 900
              ? <double>[1, 2, 2.5, 3, 4, 5]
              : <double>[2, 2.5, 3, 4, 5],
        );
        await tester.tap(find.byTooltip('More app actions'));
        await tester.pumpAndSettle();
        for (final label in <String>[
          'Keyboard shortcuts',
          'Settings',
          'Account backup',
          'Local data recovery',
        ]) {
          expect(
            find.text(label),
            findsOneWidget,
            reason: '$label at ${width}px',
          );
        }
        await tester.tapAt(const Offset(0, 0));
        await tester.pumpAndSettle();
        fixture.dispose();
      }
    },
  );

  testWidgets(
    'desktop chrome keeps visible state and density at 100 and 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.good),
        refreshRequested: () async {},
        stopSyncRequested: () async {},
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey<String>('standard-theme'),
          theme: axiotaskTheme(
            Brightness.light,
            DensityPreference.standard,
            platform: TargetPlatform.linux,
          ),
          home: AdaptiveShell(viewModel: fixture.viewModel),
        ),
      );
      await tester.pump();
      final standardHeader = tester.getSize(
        find.byKey(const Key('desktop-application-header')),
      );
      final search = find.byTooltip('Search tasks');
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey<String>('compact-theme'),
          theme: axiotaskTheme(
            Brightness.dark,
            DensityPreference.compact,
            platform: TargetPlatform.linux,
          ),
          home: AdaptiveShell(viewModel: fixture.viewModel),
        ),
      );
      await tester.pump();
      final compactHeader = tester.getSize(
        find.byKey(const Key('desktop-application-header')),
      );
      expect(standardHeader.height, 48);
      expect(compactHeader.height, 44);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey<String>('large-text-theme'),
          theme: axiotaskTheme(
            Brightness.light,
            DensityPreference.standard,
            platform: TargetPlatform.linux,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AdaptiveShell(viewModel: fixture.viewModel),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('desktop-application-header')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
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
        Focus.of(tester.element(find.byKey(const Key('desktop-task-row-11'))))
            .hasFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.byKey(const Key('desktop-task-row-13'))))
            .hasFocus,
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
        Focus.of(tester.element(find.byKey(const Key('desktop-detail-pane'))))
            .hasFocus,
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
    'desktop rows keep a compact two-line rhythm in both density preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final standard = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _scrollSnapshot,
      );
      addTearDown(standard.dispose);
      await tester.pumpWidget(standard.widget);
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('desktop-task-row-100'))).height,
        inInclusiveRange(52, 60),
        reason: 'standard rows leave room for a concise metadata line',
      );
      final scaled = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _snapshot,
      );
      addTearDown(scaled.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AdaptiveShell(viewModel: scaled.viewModel),
        ),
      );
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('desktop-task-row-11'))).height,
        greaterThan(60),
        reason: 'large text grows a row instead of clipping its readable title',
      );

      final preferences = _WorkspacePreferences()
        ..current = const DevicePreferences.defaults().copyWith(
          density: DensityPreference.compact,
        );
      final compact = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _scrollSnapshot,
        preferencesRepository: preferences,
      );
      addTearDown(compact.dispose);
      await tester.pumpWidget(compact.widget);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('desktop-task-row-100'))).height,
        inInclusiveRange(44, 52),
        reason: 'compact rows improve visible desktop density without clipping',
      );
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
          'Move up and Move down are in the task actions menu.',
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
        find.byKey(const Key('desktop-task-drop-indicator-11')),
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
      expect(
        find.byKey(const Key('desktop-task-drop-indicator-11')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'drag rejection marks its target and uses a bounded row-safe message',
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
      final drag = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getCenter(find.text('Focus').first));
      await tester.pump();
      expect(find.byKey(const Key('desktop-task-drag-preview')), findsNothing);
      await drag.up();
      await tester.pumpAndSettle();

      expect(fixture.tasks.applied, isEmpty);
      expect(find.text('Leaf task'), findsOneWidget);
      expect(find.byKey(const Key('transient-task-feedback')), findsOneWidget);
      expect(find.text('This drop target is not available.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const Key('transient-task-feedback')), findsNothing);
    },
  );

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
    expect(find.byKey(const Key('desktop-list-drop-target-8')), findsOneWidget);
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

  testWidgets(
    'desktop panes collapse empty details and restore selected details',
    (tester) async {
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
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.8)),
              child: child!,
            ),
            home: AdaptiveShell(viewModel: fixture.viewModel),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('desktop-navigation-pane')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('desktop-task-pane')), findsOneWidget);
        expect(find.byKey(const Key('desktop-detail-pane')), findsNothing);
        await tester.tap(find.text('Cached parent'));
        await tester.pump();
        expect(find.byKey(const Key('desktop-detail-pane')), findsOneWidget);
        fixture.viewModel.backFromTaskDetail();
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'desktop width $width');
      }
    },
  );

  testWidgets(
    'desktop splitters resize by pointer and keyboard with semantic alternatives',
    (tester) async {
      tester.view.physicalSize = const Size(1355, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = _WorkspacePreferences();
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        preferencesRepository: preferences,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Cached parent'));
      await tester.pump();

      final navigation = find.byKey(const Key('desktop-navigation-pane'));
      final splitter = find.byKey(const Key('desktop-navigation-splitter'));
      expect(tester.getSize(navigation).width, 244);
      expect(
        tester.widget<MouseRegion>(
          find.descendant(of: splitter, matching: find.byType(MouseRegion)),
        ),
        isA<MouseRegion>().having(
          (widget) => widget.cursor,
          'resize cursor',
          SystemMouseCursors.resizeColumn,
        ),
      );
      expect(
        tester.getSize(splitter).width,
        greaterThanOrEqualTo(12),
        reason: 'splitter keeps a robust pointer target',
      );

      final drag = await tester.startGesture(
        tester.getCenter(splitter),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(48, 0));
      await drag.up();
      await tester.pump();
      expect(preferences.workspaceWrites, isNotEmpty);
      expect(tester.getSize(navigation).width, 292);
      expect(preferences.workspaceWrites.last.navigationWidth, 292);

      await tester.tap(splitter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(tester.getSize(navigation).width, 276);
      expect(find.bySemanticsLabel('Resize navigation pane'), findsOneWidget);
      final detail = find.byKey(const Key('desktop-detail-pane'));
      final detailSplitter = find.byKey(const Key('desktop-detail-splitter'));
      expect(detailSplitter, findsOneWidget);
      expect(tester.getSize(detail).width, 360);
      final detailDrag = await tester.startGesture(
        tester.getCenter(detailSplitter),
        kind: PointerDeviceKind.mouse,
      );
      await detailDrag.moveBy(const Offset(-32, 0));
      await detailDrag.up();
      await tester.pump();
      expect(tester.getSize(detail).width, 392);
      expect(preferences.workspaceWrites.last.detailWidth, 392);
    },
  );

  testWidgets(
    'collection command modes replace each other and describe freshness truthfully',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.good),
        preferencesRepository: _WorkspacePreferences(),
        taskListsRepository: _TaskListsRepository(),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      expect(
        find.byKey(const Key('normal-collection-command-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('selection-collection-command-bar')),
        findsNothing,
      );
      expect(find.byKey(const Key('collection-sort')), findsOneWidget);
      expect(find.byKey(const Key('bulk-select-open')), findsOneWidget);
      expect(find.byTooltip('Collection actions'), findsOneWidget);
      expect(find.text('2 tasks'), findsAtLeastNWidgets(1));
      expect(find.textContaining('cached tasks'), findsNothing);
      expect(find.byTooltip('Create Google task list'), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('collection-header'))).height,
        lessThanOrEqualTo(144),
      );

      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      expect(find.text('Add task with details'), findsOneWidget);
      expect(find.text('Create Google task list'), findsOneWidget);
      expect(find.text('Rename task list'), findsOneWidget);
      expect(find.text('Delete task list'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('bulk-select-open')));
      await tester.pump();
      expect(
        find.byKey(const Key('normal-collection-command-bar')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('selection-collection-command-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('collection-sort')), findsNothing);
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byTooltip('Exit task selection'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-select-task-13')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byKey(const Key('bulk-complete-open')), findsOneWidget);
      expect(find.byKey(const Key('bulk-delete-open')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-selection-close')));
      await tester.pump();
      expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
      expect(
        find.byKey(const Key('normal-collection-command-bar')),
        findsOneWidget,
      );
    },
  );

  testWidgets('collection count calls stale data stale, never current', (
    tester,
  ) async {
    final fixture = _ShellFixture(
      _health(
        SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.stale,
        action: SyncHealthAction.retry,
      ),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pump();

    expect(find.text('2 stale tasks'), findsOneWidget);
    expect(find.text('2 tasks'), findsNothing);
  });

  testWidgets(
    'collection commands retain ordered focus and fit responsive large text',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final density in DensityPreference.values) {
        for (final textScale in <double>[1, 2]) {
          final fixture = _ShellFixture(
            _health(SyncHealthOutcome.good),
            preferencesRepository: _WorkspacePreferences(),
          );
          addTearDown(fixture.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: axiotaskTheme(
                Brightness.light,
                density,
                platform: TargetPlatform.linux,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: AdaptiveShell(viewModel: fixture.viewModel),
            ),
          );
          await tester.pump();
          final orders = tester
              .widgetList<FocusTraversalOrder>(
                find.descendant(
                  of: find.byKey(const Key('normal-collection-command-bar')),
                  matching: find.byType(FocusTraversalOrder),
                ),
              )
              .map((widget) => (widget.order as NumericFocusOrder).order)
              .toList();
          expect(orders, <double>[1, 2, 3]);
          expect(
            tester
                .getRect(find.byKey(const Key('normal-collection-command-bar')))
                .bottom,
            lessThanOrEqualTo(800),
          );
          if (textScale == 1) {
            expect(
              tester.getSize(find.byKey(const Key('collection-header'))).height,
              lessThanOrEqualTo(
                density == DensityPreference.standard ? 144 : 128,
              ),
            );
          }
          expect(
            tester.takeException(),
            isNull,
            reason: '$density at ${textScale * 100}%',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );

  testWidgets(
    'bulk selection, confirmation, exact result, and back share route state',
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

      await tester.tap(find.byKey(const Key('bulk-select-open')));
      await tester.pump();
      expect(fixture.viewModel.state.bulkSelectedTaskIds, {const TaskId(11)});
      expect(
        navigation.state.predictiveBackRoute,
        TaskSelectionRoute({const TaskId(11)}),
      );
      await tester.tap(find.byKey(const Key('bulk-select-task-13')));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bulk-complete-open')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bulk-complete-confirmation')),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.tasks.bulkApplied, isEmpty);
      expect(fixture.viewModel.state.bulkSelectedTaskIds, hasLength(2));

      await tester.tap(find.byKey(const Key('bulk-complete-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-complete-confirm')));
      await tester.pumpAndSettle();

      expect(fixture.tasks.bulkApplied, hasLength(1));
      expect(fixture.tasks.bulkApplied.single, isA<BulkCompleteTasksCommand>());
      expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
      expect(navigation.state.canHandlePredictiveBack, isFalse);
      expect(
        find.text(
          'Bulk complete: 1 confirmed • 1 pending • 0 failed '
          '(2 Google updates from 2 selected)',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('bulk-select-open')));
      await tester.pump();
      expect(
        navigation.state.predictiveBackRoute,
        TaskSelectionRoute({const TaskId(11)}),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
      expect(find.byKey(const Key('bulk-action-bar')), findsNothing);
    },
  );

  testWidgets('bulk reschedule and move dialogs dispatch validated commands', (
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
    await tester.pump();

    await tester.tap(find.byKey(const Key('bulk-select-open')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-reschedule-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bulk-reschedule-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bulk-reschedule-tomorrow')));
    await tester.pumpAndSettle();
    final reschedule = fixture.tasks.bulkApplied.single;
    expect(reschedule, isA<BulkRescheduleTasksCommand>());
    expect(
      (reschedule as BulkRescheduleTasksCommand).due,
      TaskDate(2026, 8, 16),
    );

    await tester.tap(find.byKey(const Key('bulk-select-open')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-move-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bulk-move-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bulk-move-list-8')));
    await tester.pumpAndSettle();
    expect(fixture.tasks.bulkApplied, hasLength(2));
    final move = fixture.tasks.bulkApplied.last;
    expect(move, isA<BulkMoveTasksCommand>());
    expect(
      (move as BulkMoveTasksCommand).destinationTaskListId,
      const TaskListId(8),
    );
  });

  testWidgets('grouped bulk delete confirms once and exposes one Undo all', (
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

    await tester.tap(find.byKey(const Key('bulk-select-open')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-select-task-13')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bulk-delete-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bulk-delete-confirmation')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.tasks.bulkApplied, isEmpty);

    await tester.tap(find.byKey(const Key('bulk-delete-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk-delete-confirm')));
    await tester.pumpAndSettle();
    expect(fixture.tasks.bulkApplied.single, isA<BulkDeleteTasksCommand>());
    fixture.tasks.groupUndoController.add(<TaskDeleteGroupUndo>[
      TaskDeleteGroupUndo(
        groupId: 91,
        selectedCount: 2,
        rootCount: 2,
        notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(fixture.viewModel.state.taskDeleteGroupUndos, hasLength(1));
    expect(find.byKey(const Key('bulk-delete-undo')), findsOneWidget);
    expect(find.text('2 selected tasks deleted'), findsOneWidget);
    await tester.tap(find.text('Undo all'));
    await tester.pump();
    expect(fixture.tasks.groupUndos.single.groupId, 91);
  });

  testWidgets(
    'Clear completed cancel is inert and confirmation names skipped parent',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.pending),
        snapshot: _destructiveSnapshot,
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.widget);
      await tester.pump();

      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear completed'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('clear-completed-confirmation')),
        findsOneWidget,
      );
      expect(find.textContaining('1 completed parent is kept'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.tasks.clearedCompleted, isEmpty);

      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear completed'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-completed-confirm')));
      await tester.pumpAndSettle();
      expect(
        fixture.tasks.clearedCompleted.single.taskListId,
        const TaskListId(7),
      );
      expect(find.byKey(const Key('bulk-delete-undo')), findsNothing);
      expect(
        find.textContaining('Clear completed: 0 confirmed'),
        findsOneWidget,
      );
    },
  );

  group('phone search and Previous/Next (Android audit 13, 17 and 23)', () {
    setUpAll(loadAndroidTextFont);

    const viewports = <PhoneViewport>[
      PhoneViewport(320, PhoneOrientation.portrait, 2),
      PhoneViewport(360, PhoneOrientation.portrait, 1),
      PhoneViewport(443, PhoneOrientation.landscape, 2),
    ];

    Future<_ShellFixture> pump(WidgetTester tester, PhoneViewport viewport) =>
        _pumpPhoneShell(tester, viewport, snapshot: _navigationSnapshot);

    for (final viewport in viewports) {
      testWidgets('17 identical parent and child hits open their own task '
          'at $viewport', (tester) async {
        final fixture = await pump(tester, viewport);
        TasksViewState state() => fixture.viewModel.state;

        await _search(tester, 'Shared title');
        expect(find.byType(ListTile), findsNWidgets(2));
        await tester.tap(_searchHit('Matched subtask: Shared title'));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(12));
        expect(find.widgetWithText(TextField, 'Shared title'), findsOneWidget);
        expect(find.byTooltip('Back to parent task'), findsOneWidget);
        expect(find.byKey(const Key('search-input')), findsNothing);

        // Back returns to the parent's details, then to the collection.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(11));
        expect(find.byTooltip('Back to task collection'), findsOneWidget);
        expect(find.text('Second child'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, isNull);
        expect(find.byKey(const Key('desktop-task-row-11')), findsOneWidget);

        await _search(tester, 'Shared title');
        await tester.tap(_searchHit('Matched title'));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(11));
        expect(find.byTooltip('Back to task collection'), findsOneWidget);
        expect(fixture.tasks.applied, isEmpty, reason: 'navigation only');
        expect(tester.takeException(), isNull);
      });

      testWidgets('23 Previous/Next step through the visible order by touch '
          'at $viewport', (tester) async {
        final fixture = await pump(tester, viewport);
        TasksViewState state() => fixture.viewModel.state;
        await tester.tap(find.byKey(const Key('desktop-task-row-11')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(11));

        // A disabled control at the boundary keeps its 48 dp footprint.
        expect(
          tester.getSize(find.byKey(const Key('task-detail-previous'))),
          const Size(48, 48),
        );
        expect(_detailNavigationEnabled(tester), (false, true));
        await tester.tap(find.byKey(const Key('task-detail-previous')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(11), reason: 'boundary');

        // Collection order: Shared title, Leaf task, Another leaf.
        await tester.tap(find.byKey(const Key('task-detail-next')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(13));
        expect(find.widgetWithText(TextField, 'Leaf task'), findsOneWidget);
        expect(_detailNavigationEnabled(tester), (true, true));
        final previousRegion = expectTouchTarget(
          tester,
          find.byKey(const Key('task-detail-previous')),
          label: 'Previous task',
        );
        final nextRegion = expectTouchTarget(
          tester,
          find.byKey(const Key('task-detail-next')),
          label: 'Next task',
        );
        for (final probe in edgeProbes(previousRegion)) {
          expect(
            reachesControl(
              tester,
              find.byKey(const Key('task-detail-next')),
              probe,
            ),
            isFalse,
          );
        }
        for (final probe in edgeProbes(nextRegion)) {
          expect(
            reachesControl(
              tester,
              find.byKey(const Key('task-detail-previous')),
              probe,
            ),
            isFalse,
          );
        }
        expect(
          tester.getTopLeft(find.byKey(const Key('task-detail-title'))).dy,
          greaterThanOrEqualTo(nextRegion.bottom),
          reason: 'the title gets its own full-width line',
        );
        await tester.tap(find.byKey(const Key('task-detail-next')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(15));
        expect(_detailNavigationEnabled(tester), (true, false));
        await tester.tap(find.byKey(const Key('task-detail-next')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(15), reason: 'boundary');
        await tester.tap(find.byKey(const Key('task-detail-previous')));
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, const TaskId(13));

        // Stepping is lateral: one Back leaves details.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(state().selectedTaskId, isNull);
        expect(fixture.tasks.applied, isEmpty, reason: 'navigation only');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('17 a hit in another list opens in that list', (tester) async {
      final fixture = await pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      TasksViewState state() => fixture.viewModel.state;
      expect(state().selectedTaskListId, const TaskListId(7));

      await _search(tester, 'Archive needle');
      await tester.tap(_searchHit('Matched subtask: Archive needle child'));
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, const TaskId(17));
      expect(state().selectedTaskListId, const TaskListId(8));
      expect(
        find.widgetWithText(TextField, 'Archive needle child'),
        findsOneWidget,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, const TaskId(16));
      expect(_detailNavigationEnabled(tester), (false, false), reason: 'alone');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, isNull);
      expect(find.byKey(const Key('desktop-task-row-16')), findsOneWidget);
      expect(find.byKey(const Key('desktop-task-row-11')), findsNothing);
    });

    testWidgets('23 a subtask steps through its siblings and keeps its '
        'parent as Back', (tester) async {
      final fixture = await pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      TasksViewState state() => fixture.viewModel.state;
      await tester.tap(find.byKey(const Key('desktop-task-row-11')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Second child'));
      await tester.tap(find.text('Second child'));
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, const TaskId(14));
      expect(_detailNavigationEnabled(tester), (true, false));
      await tester.tap(find.byKey(const Key('task-detail-previous')));
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, const TaskId(12));
      expect(_detailNavigationEnabled(tester), (false, true));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state().selectedTaskId, const TaskId(11));
    });

    testWidgets('23 a pending inline edit is stored on its own task before '
        'Next opens another', (tester) async {
      final fixture = await pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      await tester.tap(find.byKey(const Key('desktop-task-row-13')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('task-detail-title')),
        'Leaf edited',
      );
      await tester.pump();
      expect(fixture.tasks.applied, isEmpty, reason: 'still debouncing');

      await tester.tap(find.byKey(const Key('task-detail-next')));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(15));
      final title = fixture.tasks.applied.single as SetTaskTitleCommand;
      expect(title.taskId, const TaskId(13));
      expect(title.title, 'Leaf edited');
      expect(find.widgetWithText(TextField, 'Another leaf'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Leaf edited'), findsNothing);
      expect(fixture.tasks.applied, hasLength(1), reason: 'Another leaf kept');
    });

    testWidgets('17 a search without results opens nothing', (tester) async {
      final fixture = await pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      await _search(tester, 'No such task');
      expect(find.textContaining('No supported tasks match'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsNothing);
      expect(fixture.viewModel.state.selectedTaskId, isNull);
    });
  });

  testWidgets('desktop details step with Previous/Next and keep keyboard '
      'navigation', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _ShellFixture(
      _health(SyncHealthOutcome.good),
      snapshot: _navigationSnapshot,
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.widget);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
    expect(_detailNavigationEnabled(tester), (false, true));

    await tester.tap(find.byKey(const Key('task-detail-next')));
    await tester.pumpAndSettle();
    expect(fixture.viewModel.state.selectedTaskId, const TaskId(13));
    expect(find.byKey(const Key('desktop-task-row-11')), findsOneWidget);

    await tester.tap(find.byKey(const Key('task-detail-previous')));
    await tester.pumpAndSettle();
    expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));

    // Task shortcuts still act on the task the controls opened.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextField, 'Shared title'),
      ),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fixture.viewModel.state.selectedTaskId, isNull);
    expect(fixture.tasks.applied, isEmpty);
  });

  group('phone task-row touch contract (Android audit 01 and 22)', () {
    setUpAll(loadAndroidTextFont);

    for (final viewport in phoneViewports) {
      testWidgets('01 overflow menu is readable and reachable at $viewport', (
        tester,
      ) async {
        final fixture = await _pumpPhoneShell(tester, viewport);
        await tester.tap(_rowOverflow(11, 'Cached parent'));
        await tester.pumpAndSettle();
        await expectReadableMenu(tester, _taskMenuLabels);
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Edit task…'), findsNothing);
        expect(fixture.tasks.applied, isEmpty);
      });

      testWidgets('22 row controls have separate 48 dp targets at $viewport', (
        tester,
      ) async {
        for (final density in DensityPreference.values) {
          final fixture = await _pumpPhoneShell(
            tester,
            viewport,
            density: density,
          );
          final completion = _rowCompletion(11);
          final overflow = _rowOverflow(11, 'Cached parent');
          final completionRegion = expectTouchTarget(
            tester,
            completion,
            label: 'Complete task',
          );
          final overflowRegion = expectTouchTarget(
            tester,
            overflow,
            label: 'Task actions for Cached parent',
          );
          expect(
            completionRegion.overlaps(overflowRegion),
            isFalse,
            reason: '$density: $completionRegion and $overflowRegion overlap',
          );
          for (final probe in edgeProbes(completionRegion)) {
            expect(reachesControl(tester, overflow, probe), isFalse);
          }
          for (final probe in edgeProbes(overflowRegion)) {
            expect(reachesControl(tester, completion, probe), isFalse);
          }

          for (final probe in edgeProbes(completionRegion)) {
            fixture.tasks.applied.clear();
            await tester.tapAt(probe);
            await tester.pumpAndSettle();
            final command =
                fixture.tasks.applied.single as SetTaskCompletionCommand;
            expect(command.taskId, const TaskId(11), reason: '$probe');
            expect(command.status, TaskStatus.completed);
          }
          for (final probe in edgeProbes(overflowRegion)) {
            await tester.tapAt(probe);
            await tester.pumpAndSettle();
            expect(
              find.text('Edit task…').hitTestable(),
              findsOneWidget,
              reason: '$density: a tap at $probe opens the menu',
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    }

    testWidgets('01 overflow Edit and Delete run their task commands', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.landscape, 2),
      );
      await tester.tap(_rowOverflow(11, 'Cached parent'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit task…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit task…').hitTestable());
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('Edit task')),
        findsOneWidget,
      );
      await tester.enterText(
        find.descendant(
          of: dialog,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == 'Task title',
          ),
        ),
        'Edited parent',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final edit = fixture.tasks.applied.single as UpdateTaskContentCommand;
      expect(edit.taskId, const TaskId(11));
      expect(edit.title, 'Edited parent');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(_rowOverflow(11, 'Cached parent'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete task'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete task').hitTestable());
      await tester.pumpAndSettle();
      expect(fixture.tasks.deleted.single.taskId, const TaskId(11));
      expect(tester.takeException(), isNull);
    });
  });

  group('phone selection toolbar touch contract (Android audit 06)', () {
    setUpAll(loadAndroidTextFont);

    for (final viewport in selectionViewports) {
      testWidgets('06 long press keeps every bulk control reachable at '
          '$viewport', (tester) async {
        final fixture = await _pumpSelectionShell(tester, viewport);
        await _longPressRowTitle(tester, 'Cached parent');
        await tester.pumpAndSettle();
        expect(fixture.viewModel.state.bulkSelectedTaskIds, {const TaskId(11)});
        expectSelectionToolbarReachable(
          tester,
          count: 1,
          reason: '$viewport after long press',
        );
        await _tapRowTitle(tester, 'Leaf task');
        expect(fixture.viewModel.state.bulkSelectedTaskIds, {
          const TaskId(11),
          const TaskId(13),
        });
        expectSelectionToolbarReachable(
          tester,
          count: 2,
          reason: '$viewport with two selected',
        );

        // Every action opens by a real tap and cancels without a command.
        for (final (control, dialog) in <(SelectionControl, String)>[
          (completeSelectionControl, 'bulk-complete-confirmation'),
          (rescheduleSelectionControl, 'bulk-reschedule-dialog'),
          (moveSelectionControl, 'bulk-move-dialog'),
          (deleteSelectionControl, 'bulk-delete-confirmation'),
        ]) {
          await tapSelectionControl(tester, control);
          await tester.pumpAndSettle();
          expect(
            find.byKey(Key(dialog)),
            findsOneWidget,
            reason: '$viewport: ${control.label} opens its dialog',
          );
          expect(tester.takeException(), isNull, reason: '$dialog layout');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byKey(Key(dialog)), findsNothing);
          expect(fixture.viewModel.state.bulkSelectedTaskIds, hasLength(2));
        }

        await tapSelectionControl(tester, exitSelectionControl);
        await tester.pumpAndSettle();
        expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
        expect(find.byKey(const Key('bulk-action-bar')), findsNothing);
        expect(fixture.tasks.bulkApplied, isEmpty);
        expect(fixture.tasks.applied, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    for (final viewport in <PhoneViewport>[
      const PhoneViewport(320, PhoneOrientation.portrait, 2),
      const PhoneViewport(320, PhoneOrientation.landscape, 2),
      const PhoneViewport(360, PhoneOrientation.landscape, 2),
      const PhoneViewport(443, PhoneOrientation.portrait, 1),
    ]) {
      testWidgets('06 every bulk action dispatches its command at $viewport', (
        tester,
      ) async {
        final fixture = await _pumpSelectionShell(
          tester,
          viewport,
          clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
        );
        Future<void> selectBoth() async {
          await _longPressRowTitle(tester, 'Cached parent');
          await _tapRowTitle(tester, 'Leaf task');
          expect(fixture.viewModel.state.bulkSelectedTaskIds, {
            const TaskId(11),
            const TaskId(13),
          });
          // Earlier results stay on screen as banners above the collection.
          expectSelectionToolbarReachable(
            tester,
            count: 2,
            reason: '$viewport with any earlier bulk result shown',
          );
        }

        await selectBoth();
        await tapSelectionControl(tester, completeSelectionControl);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel').hitTestable());
        await tester.pumpAndSettle();
        expect(fixture.tasks.bulkApplied, isEmpty);
        expect(fixture.viewModel.state.bulkSelectedTaskIds, hasLength(2));
        await tapSelectionControl(tester, completeSelectionControl);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bulk-complete-confirm')).hitTestable(),
        );
        await tester.pumpAndSettle();
        final complete =
            fixture.tasks.bulkApplied.single as BulkCompleteTasksCommand;
        expect(complete.taskIds, {const TaskId(11), const TaskId(13)});
        expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);

        await selectBoth();
        await tapSelectionControl(tester, rescheduleSelectionControl);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bulk-reschedule-tomorrow')).hitTestable(),
        );
        await tester.pumpAndSettle();
        final reschedule =
            fixture.tasks.bulkApplied.last as BulkRescheduleTasksCommand;
        expect(reschedule.taskIds, {const TaskId(11), const TaskId(13)});
        expect(reschedule.due, TaskDate(2026, 8, 16));

        await selectBoth();
        await tapSelectionControl(tester, moveSelectionControl);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bulk-move-list-8')).hitTestable(),
        );
        await tester.pumpAndSettle();
        final move = fixture.tasks.bulkApplied.last as BulkMoveTasksCommand;
        expect(move.taskIds, {const TaskId(11), const TaskId(13)});
        expect(move.destinationTaskListId, const TaskListId(8));

        await selectBoth();
        await tapSelectionControl(tester, deleteSelectionControl);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('bulk-delete-confirm')).hitTestable(),
        );
        await tester.pumpAndSettle();
        final delete = fixture.tasks.bulkApplied.last as BulkDeleteTasksCommand;
        expect(delete.taskIds, {const TaskId(11), const TaskId(13)});
        expect(fixture.tasks.bulkApplied, hasLength(4));
        fixture.tasks.groupUndoController.add(<TaskDeleteGroupUndo>[
          TaskDeleteGroupUndo(
            groupId: 91,
            selectedCount: 2,
            rootCount: 2,
            notBefore: DateTime.utc(2026, 8, 15, 12, 0, 30),
          ),
        ]);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Undo all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Undo all').hitTestable());
        await tester.pumpAndSettle();
        expect(fixture.tasks.groupUndos.single.groupId, 91);
        expect(fixture.tasks.applied, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('06 a pending bulk command disables every control', (
      tester,
    ) async {
      final fixture = await _pumpSelectionShell(
        tester,
        const PhoneViewport(320, PhoneOrientation.portrait, 1),
      );
      final gate = Completer<void>();
      fixture.tasks.bulkGate = gate.future;
      await _longPressRowTitle(tester, 'Cached parent');
      await tester.pumpAndSettle();
      await _tapRowTitle(tester, 'Leaf task');
      await tapSelectionControl(tester, completeSelectionControl);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('bulk-complete-confirm')).hitTestable(),
      );
      // The progress indicator never settles; let the dialog close.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Dialog), findsNothing);
      expect(fixture.viewModel.state.isBulkCommandPending, isTrue);
      expect(fixture.tasks.bulkApplied, hasLength(1));
      expect(
        find.descendant(
          of: find.byKey(const Key('bulk-action-bar')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      for (final control in selectionControls) {
        final semantics = tester
            .getSemantics(selectionControlFinder(control))
            .getSemanticsData();
        expect(
          semantics.hasAction(SemanticsAction.tap),
          isFalse,
          reason: '${control.label} is disabled while the command is pending',
        );
        await tester.tapAt(tester.getCenter(selectionControlFinder(control)));
        await tester.pump();
        expect(find.byType(Dialog), findsNothing, reason: control.label);
        expect(fixture.viewModel.state.bulkSelectedTaskIds, hasLength(2));
      }
      expect(fixture.tasks.bulkApplied, hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.isBulkCommandPending, isFalse);
      expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
      expect(fixture.tasks.bulkApplied.single, isA<BulkCompleteTasksCommand>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('06 Back clears the selection without a command', (
      tester,
    ) async {
      final fixture = await _pumpSelectionShell(
        tester,
        const PhoneViewport(320, PhoneOrientation.landscape, 2),
      );
      await _longPressRowTitle(tester, 'Cached parent');
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.bulkSelectedTaskIds, hasLength(1));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.bulkSelectedTaskIds, isEmpty);
      expect(find.byKey(const Key('bulk-action-bar')), findsNothing);
      expect(fixture.tasks.bulkApplied, isEmpty);
      expect(fixture.tasks.applied, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'desktop rows keep dense controls and a readable secondary-click menu',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final (density, controlSize) in <(DensityPreference, double)>[
        (DensityPreference.standard, 40),
        (DensityPreference.compact, 36),
      ]) {
        final preferences = _WorkspacePreferences()
          ..current = const DevicePreferences.defaults().copyWith(
            density: density,
          );
        final fixture = _ShellFixture(
          _health(SyncHealthOutcome.pending),
          preferencesRepository: preferences,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: axiotaskTheme(Brightness.light, density),
            home: AdaptiveShell(
              viewModel: fixture.viewModel,
              preferencesRepository: preferences,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(AdaptiveShell))).platform,
          TargetPlatform.linux,
        );
        final completion = measureHitRegion(tester, _rowCompletion(11));
        final overflow = measureHitRegion(
          tester,
          _rowOverflow(11, 'Cached parent'),
        );
        for (final region in <Rect>[completion, overflow]) {
          expect(
            region.width,
            closeTo(controlSize, hitRegionTolerance),
            reason: '$density keeps dense desktop controls: $region',
          );
          expect(
            region.height,
            closeTo(controlSize, hitRegionTolerance),
            reason: '$density keeps dense desktop controls: $region',
          );
        }
        expect(completion.overlaps(overflow), isFalse);

        await tester.tap(_rowOverflow(11, 'Cached parent'));
        await tester.pumpAndSettle();
        await expectReadableMenu(tester, _taskMenuLabels);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        final row = find.byKey(const Key('desktop-task-row-11'));
        await tester.tapAt(
          tester.getCenter(row),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await expectReadableMenu(tester, _taskMenuLabels);
        await tester.tap(find.text('Delete task'));
        await tester.pumpAndSettle();
        expect(fixture.tasks.deleted.single.taskId, const TaskId(11));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.dispose();
      }
    },
  );

  group('phone capture composer (Android audit 08, 20 and 27)', () {
    setUpAll(loadAndroidTextFont);
    final addButton = find.byKey(const Key('phone-add-task'));
    final composer = find.byKey(const Key('composer-surface'));
    final title = find.byKey(const Key('quick-add-input'));
    final notes = find.byKey(const Key('quick-add-notes'));
    final submit = find.byKey(const Key('quick-add-submit'));
    final cancel = find.byKey(const Key('composer-cancel'));

    bool focused(WidgetTester tester, Finder field) => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .focusNode
        .hasFocus;

    String text(WidgetTester tester, Finder field) => tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .controller
        .text;

    /// Raises a simulated keyboard over the bottom [fraction] of the view
    /// (about 40% in portrait and half in landscape, as phone keyboards
    /// take). As on Android, the keyboard covers the navigation bar, so the
    /// bottom padding becomes zero.
    Future<double> raiseKeyboard(
      WidgetTester tester, {
      double? fraction,
    }) async {
      final size = tester.view.physicalSize;
      final share = fraction ?? (size.width > size.height ? 0.5 : 0.4);
      tester.view
        ..viewInsets = FakeViewPadding(bottom: size.height * share)
        ..padding = const FakeViewPadding(top: 24);
      await tester.pumpAndSettle();
      return size.height * (1 - share);
    }

    Future<void> lowerKeyboard(WidgetTester tester) async {
      tester.view
        ..viewInsets = FakeViewPadding.zero
        ..padding = const FakeViewPadding(top: 24, bottom: 48);
      await tester.pumpAndSettle();
    }

    /// The control is whole on screen, above [keyboardTop] and below the
    /// status bar, and a touch at its centre reaches it.
    void expectReachable(
      WidgetTester tester,
      Finder control, {
      required String label,
      required double keyboardTop,
    }) {
      final rect = tester.getRect(control);
      expect(
        rect.top,
        greaterThanOrEqualTo(24),
        reason: '$label clears the status bar',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(keyboardTop),
        reason: '$label stays above the keyboard ($keyboardTop)',
      );
      expectTouchTarget(tester, control, label: label);
    }

    Future<void> openComposer(WidgetTester tester) async {
      expect(addButton.hitTestable(), findsOneWidget);
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      expect(composer, findsOneWidget);
      expect(focused(tester, title), isTrue, reason: 'Title takes focus');
      expect(addButton, findsNothing, reason: 'The button yields to it');
    }

    for (final viewport in selectionViewports) {
      testWidgets('20/27 add button opens a reachable composer at $viewport', (
        tester,
      ) async {
        // Starts in portrait and rotates, as the selection contract does.
        final fixture = await _pumpSelectionShell(tester, viewport);
        expect(composer, findsNothing, reason: 'Composer is on demand');
        expect(title, findsNothing, reason: 'No always-visible capture bar');
        expectTouchTarget(tester, addButton, label: 'New task');
        // The button never hides a visible row's controls.
        final button = measureHitRegion(tester, addButton);
        for (final id in <int>[11, 13]) {
          final row = find.byKey(Key('desktop-task-row-$id'));
          if (row.hitTestable().evaluate().isEmpty) continue;
          for (final control in <Finder>[
            find.descendant(of: row, matching: find.byTooltip('Complete task')),
            find.descendant(
              of: row,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Tooltip &&
                    (widget.message ?? '').startsWith('Task actions for'),
              ),
            ),
          ]) {
            if (control.evaluate().isEmpty) continue;
            final rect = tester.getRect(control);
            final visible = rect.intersect(
              tester.getRect(find.byKey(const Key('desktop-task-scroll'))),
            );
            if (visible.isEmpty || visible.height < 1) continue;
            expect(
              button.overlaps(visible),
              isFalse,
              reason: 'Add button $button covers $control at $visible',
            );
          }
        }

        await openComposer(tester);
        final keyboardTop = await raiseKeyboard(tester);
        expect(tester.takeException(), isNull, reason: '$viewport layout');
        expectReachable(
          tester,
          cancel,
          label: 'Cancel',
          keyboardTop: keyboardTop,
        );
        expectReachable(
          tester,
          submit,
          label: 'Add task',
          keyboardTop: keyboardTop,
        );
        final titleRect = tester.getRect(title);
        expect(titleRect.bottom, lessThanOrEqualTo(keyboardTop));
        expect(fixture.tasks.created, isEmpty);
      });
    }

    testWidgets('08 keyboard submit stores title and notes in the selected '
        'list, twice without duplicates', (tester) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      fixture.viewModel.selectTaskList(const TaskListId(8));
      await tester.pumpAndSettle();
      await openComposer(tester);

      await tester.enterText(title, 'Phone capture one');
      await tester.enterText(notes, 'First line\nSecond line');
      await tester.tap(title);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(fixture.tasks.created, hasLength(1));
      expect(fixture.tasks.created.single.title, 'Phone capture one');
      expect(fixture.tasks.created.single.notes, 'First line\nSecond line');
      expect(fixture.tasks.created.single.taskListId, const TaskListId(8));
      // Rapid entry: still open, cleared and focused on the title.
      expect(composer, findsOneWidget);
      expect(text(tester, title), isEmpty);
      expect(text(tester, notes), isEmpty);
      expect(focused(tester, title), isTrue);

      await tester.enterText(title, 'Phone capture two');
      await tester.pump();
      await tester.tap(submit);
      // A second tap while the first is saving is not a second task.
      await tester.tap(submit, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(fixture.tasks.created.map((command) => command.title), <String>[
        'Phone capture one',
        'Phone capture two',
      ]);
      expect(fixture.tasks.created.last.notes, isNull);
      expect(fixture.tasks.created.last.taskListId, const TaskListId(8));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty title is rejected and keeps the notes', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 2),
      );
      await openComposer(tester);
      await tester.enterText(notes, 'Notes without a title');
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(fixture.tasks.created, isEmpty);
      expect(find.text('Enter a task title.'), findsOneWidget);
      expect(text(tester, notes), 'Notes without a title');
      expect(composer, findsOneWidget);

      // Keyboard submit of a blank title is rejected the same way.
      await tester.enterText(title, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(fixture.tasks.created, isEmpty);
      expect(text(tester, notes), 'Notes without a title');
    });

    testWidgets('a storage failure keeps title and notes for a retry', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      fixture.tasks.createResult = Future.value(
        const Outcome<TaskId>.failure(
          Failure(
            code: 'task.persistence_failed',
            category: FailureCategory.persistence,
            operation: FailureOperation.write,
            retry: RetryClassification.unknown,
            impact: 'The task was not saved.',
            safeSummary: 'The task transaction failed.',
          ),
        ),
      );
      await openComposer(tester);
      await tester.enterText(title, 'Survives failure');
      await tester.enterText(notes, 'Kept notes');
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.text('The task could not be saved safely.'), findsOneWidget);
      expect(text(tester, title), 'Survives failure');
      expect(text(tester, notes), 'Kept notes');
      expect(composer, findsOneWidget);

      fixture.tasks.createResult = Future.value(
        const Outcome<TaskId>.success(TaskId(92)),
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(fixture.tasks.created, hasLength(2));
      expect(fixture.tasks.created.last.title, 'Survives failure');
      expect(fixture.tasks.created.last.notes, 'Kept notes');
      expect(text(tester, notes), isEmpty);
    });

    testWidgets('Back lowers the keyboard, then closes; Cancel discards', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      await openComposer(tester);
      await tester.enterText(title, 'Draft kept by Back');
      await tester.enterText(notes, 'Draft notes');
      await raiseKeyboard(tester);
      expect(focused(tester, notes), isTrue);

      // First Back: the keyboard goes, the composer stays.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(composer, findsOneWidget);
      expect(focused(tester, notes), isFalse);
      expect(focused(tester, title), isFalse);
      await lowerKeyboard(tester);

      // Second Back: the composer folds away; the button returns.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(composer, findsNothing);
      expect(addButton.hitTestable(), findsOneWidget);
      expect(fixture.tasks.created, isEmpty);

      // Back kept the draft; Cancel discards it without a task.
      await openComposer(tester);
      expect(text(tester, title), 'Draft kept by Back');
      expect(text(tester, notes), 'Draft notes');
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(composer, findsNothing);
      expect(fixture.tasks.created, isEmpty);
      await openComposer(tester);
      expect(text(tester, title), isEmpty);
      expect(text(tester, notes), isEmpty);

      // Cancel on an empty draft creates nothing either.
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(fixture.tasks.created, isEmpty);
      expect(fixture.tasks.applied, isEmpty);
    });

    testWidgets('rotation keeps the open composer and its draft', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 2),
      );
      await openComposer(tester);
      await tester.enterText(title, 'Rotated capture');
      await tester.enterText(notes, 'Rotated notes');

      tester.view.physicalSize = const PhoneViewport(
        360,
        PhoneOrientation.landscape,
        2,
      ).logicalSize;
      await tester.pumpAndSettle();
      final keyboardTop = await raiseKeyboard(tester);
      expect(tester.takeException(), isNull);
      expect(composer, findsOneWidget);
      expect(text(tester, title), 'Rotated capture');
      expect(text(tester, notes), 'Rotated notes');
      expectReachable(
        tester,
        submit,
        label: 'Add task',
        keyboardTop: keyboardTop,
      );
      expectReachable(
        tester,
        cancel,
        label: 'Cancel',
        keyboardTop: keyboardTop,
      );

      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(fixture.tasks.created.single.title, 'Rotated capture');
      expect(fixture.tasks.created.single.notes, 'Rotated notes');

      tester.view.physicalSize = const PhoneViewport(
        360,
        PhoneOrientation.portrait,
        2,
      ).logicalSize;
      await lowerKeyboard(tester);
      expect(tester.takeException(), isNull);
      expect(composer, findsOneWidget);
    });

    testWidgets('the quick-add shortcut never opens a composer over details', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      await _tapRowTitle(tester, 'Cached parent');
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      expect(addButton, findsNothing, reason: 'Details replace the list');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(composer, findsNothing);

      // One Back leaves the details; no hidden composer swallows it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      expect(addButton.hitTestable(), findsOneWidget);
      expect(composer, findsNothing);

      // On the list itself the shortcut opens the composer.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(composer, findsOneWidget);
      expect(focused(tester, title), isTrue);
      expect(fixture.tasks.created, isEmpty);
    });

    testWidgets('a parsed date is previewed with an explained dismiss chip', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      await openComposer(tester);
      await tester.enterText(title, 'Call tomorrow');
      await tester.pump();

      expect(find.text('Create “Call”'), findsOneWidget);
      expect(
        find.byTooltip('Dismiss interpreted date and keep it in the title'),
        findsOneWidget,
      );
      expect(fixture.tasks.created, isEmpty);
    });

    testWidgets('selection mode hides the add button', (tester) async {
      final fixture = await _pumpPhoneShell(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
      );
      fixture.viewModel.beginBulkSelection(const TaskId(11));
      await tester.pumpAndSettle();
      expect(addButton, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(addButton.hitTestable(), findsOneWidget);
    });
  });

  for (final (platform, width) in <(TargetPlatform, double)>[
    (TargetPlatform.linux, 412),
    (TargetPlatform.linux, 1280),
    (TargetPlatform.android, 1280),
  ]) {
    testWidgets('${platform.name} at $width keeps the desktop quick-add bar', (
      tester,
    ) async {
      tester.view
        ..physicalSize = Size(width, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _ShellFixture(
        _health(SyncHealthOutcome.good),
        taskListsRepository: _TaskListsRepository(),
      );
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: axiotaskTheme(
            Brightness.light,
            DensityPreference.standard,
            platform: platform,
          ),
          home: AdaptiveShell(viewModel: fixture.viewModel),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('phone-add-task')), findsNothing);
      expect(find.byKey(const Key('composer-surface')), findsNothing);
      expect(find.byKey(const Key('quick-add-notes')), findsNothing);
      expect(
        find.byKey(const Key('quick-add-input')).hitTestable(),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('quick-add-input')),
        'Desktop capture',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(fixture.tasks.created.single.title, 'Desktop capture');
      expect(fixture.tasks.created.single.notes, isNull);
      expect(find.byKey(const Key('quick-add-input')), findsOneWidget);
    });
  }

  group('phone swipe contract (Android audit 02, 03 and 32)', () {
    setUpAll(loadAndroidTextFont);
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    const viewport = PhoneViewport(360, PhoneOrientation.portrait, 1);
    final row11 = find.byKey(const Key('desktop-task-row-11'));
    final row13 = find.byKey(const Key('desktop-task-row-13'));
    final sheet = find.byKey(const Key('quick-date-sheet'));

    testWidgets('35 touch handle drops through the shared move command', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      final handle = find.byKey(const Key('touch-reorder-13'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 600));
      expect(fixture.viewModel.state.isBulkSelectionActive, isFalse);
      await gesture.moveTo(tester.getTopLeft(row11) + const Offset(100, 8));
      await tester.pump();
      expect(
        find.byKey(const Key('desktop-task-drop-indicator-11')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final command = fixture.tasks.applied.single as MoveTaskCommand;
      expect(command.taskId, const TaskId(13));
      expect(command.parentTaskId, isNull);
      expect(command.previousTaskId, isNull);
      expect(fixture.viewModel.state.isBulkSelectionActive, isFalse);
      expect(fixture.tasks.dueChanges, isEmpty);
    });

    testWidgets('35 row menu steps a task through the shared move command', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      await tester.tap(_rowOverflow(13, 'Leaf task'));
      await tester.pumpAndSettle();
      expect(find.text('Move up'), findsOneWidget);
      expect(find.text('Move down'), findsOneWidget);
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      final command = fixture.tasks.applied.single as MoveTaskCommand;
      expect(command.taskId, const TaskId(13));
      expect(command.parentTaskId, isNull);
      expect(command.previousTaskId, isNull);
    });

    Future<void> chooseFromSheet(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(of: sheet, matching: find.text(label)));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    }

    testWidgets('02 a right swipe completes exactly the swiped row', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);

      await tester.drag(row13, const Offset(130, 0));
      await tester.pumpAndSettle();
      final command = fixture.tasks.applied.single as SetTaskCompletionCommand;
      expect(command.taskId, const TaskId(13));
      expect(command.status, TaskStatus.completed);
      expect(fixture.viewModel.state.selectedTaskId, isNull);

      // Short or vertical drags send nothing.
      fixture.tasks.applied.clear();
      await tester.drag(row11, const Offset(60, 0));
      await tester.drag(row11, const Offset(100, 200));
      await tester.pumpAndSettle();
      expect(fixture.tasks.applied, isEmpty);
      expect(fixture.tasks.dueChanges, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('03 a left swipe schedules exactly the swiped row', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);

      await tester.drag(row11, const Offset(-130, 0));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Schedule “Cached parent”'),
        ),
        findsOneWidget,
      );
      // Back and a tap outside cancel without a command.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      await tester.drag(row11, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(180, 80));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(fixture.tasks.dueChanges, isEmpty);
      expect(fixture.tasks.applied, isEmpty);

      await tester.drag(row11, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await chooseFromSheet(tester, 'Next week');
      await tester.drag(row13, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await chooseFromSheet(tester, 'Tomorrow');
      await tester.drag(row13, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await chooseFromSheet(tester, 'Clear date');
      await tester.drag(row13, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await chooseFromSheet(tester, 'Choose date');
      // The cleared row opens the calendar on today's month, unselected.
      expectCalendarState(tester, year: 2026, month: 8, selected: null);
      await navigateCalendar(tester, from: (2026, 8), to: (2026, 9));
      await tapCalendarDay(tester, 30);
      await tapCalendarAction(tester, calendarSet);
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);

      expect(
        fixture.tasks.dueChanges.map(
          (command) => (command.taskId, command.due),
        ),
        <(TaskId, TaskDate?)>[
          (const TaskId(11), TaskDate(2026, 8, 22)),
          (const TaskId(13), TaskDate(2026, 8, 16)),
          (const TaskId(13), null),
          (const TaskId(13), TaskDate(2026, 9, 30)),
        ],
      );
      expect(fixture.tasks.applied, isEmpty, reason: 'no completion');
      expect(
        fixture.viewModel.state.selectedTaskId,
        isNull,
        reason: 'scheduling from the list keeps the list',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('row tap, long press and selection keep their meaning', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);

      await _tapRowTitle(tester, 'Leaf task');
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(13));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await _longPressRowTitle(tester, 'Leaf task');
      expect(fixture.viewModel.state.bulkSelectedTaskIds, {const TaskId(13)});
      // In selection mode a swipe neither completes nor schedules.
      await tester.drag(row11, const Offset(130, 0));
      await tester.drag(row11, const Offset(-130, 0));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(fixture.viewModel.state.bulkSelectedTaskIds, {const TaskId(13)});
      expect(fixture.tasks.applied, isEmpty);
      expect(fixture.tasks.dueChanges, isEmpty);
      expect(fixture.tasks.bulkApplied, isEmpty);
    });

    testWidgets('a mouse drag picks the row up for reordering, not a swipe', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);

      final mouse = await tester.startGesture(
        tester.getCenter(row13),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(70, 0));
      await mouse.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(find.text('Drop to reorder or move'), findsOneWidget);
      await mouse.up();
      await tester.pumpAndSettle();

      // A touch swipe of the same row never starts the pointer drag.
      await tester.drag(row11, const Offset(-130, 0));
      await tester.pump();
      expect(find.text('Drop to reorder or move'), findsNothing);
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        fixture.tasks.applied.whereType<SetTaskCompletionCommand>(),
        isEmpty,
      );
      expect(fixture.tasks.dueChanges, isEmpty);
    });

    testWidgets('32 subtask swipes act on the child, never the parent', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      await _tapRowTitle(tester, 'Cached parent');
      final child = find.byKey(const ValueKey<String>('subtask-12'));
      await tester.ensureVisible(child);
      await tester.pumpAndSettle();

      await tester.drag(child, const Offset(-60, 0));
      await tester.drag(child, const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(fixture.tasks.applied, isEmpty);

      await tester.drag(child, const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Schedule “Cached child”'),
        ),
        findsOneWidget,
      );
      await chooseFromSheet(tester, 'Tomorrow');
      expect(fixture.tasks.dueChanges.single.taskId, const TaskId(12));
      expect(fixture.tasks.dueChanges.single.due, TaskDate(2026, 8, 16));

      await tester.drag(child, const Offset(140, 0));
      await tester.pumpAndSettle();
      final command = fixture.tasks.applied.single as SetTaskCompletionCommand;
      expect(command.taskId, const TaskId(12));
      expect(command.status, TaskStatus.completed);
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));

      // A tap on the subtask still opens it.
      await tester.tap(find.text('Cached child'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(12));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a completed subtask is never reopened by a swipe', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(
        tester,
        viewport,
        clock: clock,
        snapshot: CachedTasksSnapshot(
          accountId: _snapshot.accountId,
          taskLists: _snapshot.taskLists,
          tasks: <CachedTask>[
            for (final task in _snapshot.tasks)
              task.id == const TaskId(12)
                  ? CachedTask(
                      id: task.id,
                      accountId: task.accountId,
                      taskListId: task.taskListId,
                      parentTaskId: task.parentTaskId,
                      remoteId: task.remoteId,
                      title: task.title,
                      notes: task.notes,
                      status: TaskStatus.completed,
                      due: task.due,
                    )
                  : task,
          ],
          completeness: _snapshot.completeness,
        ),
      );
      await _tapRowTitle(tester, 'Cached parent');
      // Completed subtasks are hidden until the toggle reveals them.
      final toggle = find.byKey(const Key('toggle-completed-subtasks'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final child = find.byKey(const ValueKey<String>('subtask-12'));
      await tester.ensureVisible(child);
      await tester.pumpAndSettle();

      await tester.drag(child, const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(fixture.tasks.applied, isEmpty);
    });
  });

  group('phone calendar date selection (Android audit 09 and 25)', () {
    setUpAll(loadAndroidTextFont);
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    const viewport = PhoneViewport(360, PhoneOrientation.portrait, 1);

    Future<void> openCalendar(WidgetTester tester) async {
      final due = find.byKey(const Key('task-detail-due-action'));
      await tester.ensureVisible(due);
      await tester.pumpAndSettle();
      await tester.tap(due);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose date').hitTestable());
      await tester.pumpAndSettle();
      expect(calendarDialog, findsOneWidget);
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Due date (YYYY-MM-DD)'),
        findsNothing,
        reason: 'phones choose from the calendar, not a typed date',
      );
    }

    List<(TaskId, TaskDate?)> dueCommands(_ShellFixture fixture) =>
        <(TaskId, TaskDate?)>[
          for (final command in fixture.tasks.dueChanges)
            (command.taskId, command.due),
        ];

    testWidgets('09 Choose date opens the calendar on the current date; '
        'Cancel, Back and a tap outside change nothing', (tester) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      await _tapRowTitle(tester, 'Cached parent');
      await openCalendar(tester);
      expectCalendarState(
        tester,
        year: 2026,
        month: 8,
        selected: TaskDate(2026, 8, 16),
      );
      expect(
        tester.getSemantics(
          find.descendant(of: calendarPicker, matching: find.text('15')),
        ),
        isSemantics(isSelected: false),
        reason: 'today (the application clock) is not the selection',
      );

      // Navigation and a tapped day only change the pending selection.
      await navigateCalendar(tester, from: (2026, 8), to: (2027, 1));
      await navigateCalendar(tester, from: (2027, 1), to: (2026, 12));
      await tapCalendarDay(tester, 31);
      expectCalendarState(
        tester,
        year: 2026,
        month: 12,
        selected: TaskDate(2026, 12, 31),
      );
      expect(fixture.tasks.dueChanges, isEmpty, reason: 'nothing committed');
      await tapCalendarAction(tester, calendarCancel);
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);

      // Cancel discarded the selection; Back and an outside tap also close.
      await openCalendar(tester);
      expectCalendarState(
        tester,
        year: 2026,
        month: 8,
        selected: TaskDate(2026, 8, 16),
      );
      await tapCalendarDay(tester, 20);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);
      await openCalendar(tester);
      await tapCalendarDay(tester, 21);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);

      expect(fixture.tasks.dueChanges, isEmpty);
      expect(fixture.tasks.applied, isEmpty);
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(11));
      expect(tester.takeException(), isNull);
    });

    testWidgets('09 the calendar commits month, year and leap-day boundaries '
        'as the exact chosen date', (tester) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      await _tapRowTitle(tester, 'Cached parent');
      final targets = <TaskDate>[
        TaskDate(2026, 8, 31),
        TaskDate(2026, 9, 1),
        TaskDate(2026, 12, 31),
        TaskDate(2027, 1, 1),
        TaskDate(2028, 2, 29),
        TaskDate(2024, 2, 29),
        TaskDate(2026, 3, 8), // US daylight-saving start
        TaskDate(2026, 11, 1), // US daylight-saving end
        TaskDate(2026, 9, 6), // Chile skips local midnight
        TaskDate(2018, 11, 4), // Brazil skipped local midnight
        TaskDate(2011, 12, 30), // Samoa skipped the whole day
        TaskDate(2100, 2, 28),
      ];
      for (final target in targets) {
        await openCalendar(tester);
        // The stored date never changes in this fixture, so every open
        // starts from it.
        await navigateCalendar(
          tester,
          from: (2026, 8),
          to: (target.year, target.month),
        );
        await tapCalendarDay(tester, target.day);
        expectCalendarState(
          tester,
          year: target.year,
          month: target.month,
          selected: target,
        );
        await tapCalendarAction(tester, calendarSet);
        await tester.pumpAndSettle();
        expect(calendarDialog, findsNothing, reason: '$target committed');
        expect(dueCommands(fixture).last, (const TaskId(11), target));
      }
      expect(dueCommands(fixture), hasLength(targets.length));

      // 2100 is not a leap year: February has no 29th.
      await openCalendar(tester);
      await navigateCalendar(tester, from: (2026, 8), to: (2100, 2));
      expect(
        find.descendant(of: calendarPicker, matching: find.text('29')),
        findsNothing,
      );
      await tapCalendarAction(tester, calendarCancel);
      await tester.pumpAndSettle();
      expect(dueCommands(fixture), hasLength(targets.length));
      expect(tester.takeException(), isNull);
    });

    testWidgets('09 Clear date clears; an unchanged date and an undated task '
        'send nothing until a day is chosen', (tester) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      await _tapRowTitle(tester, 'Cached parent');

      // Committing the stored date is not a change.
      await openCalendar(tester);
      await tapCalendarAction(tester, calendarSet);
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);
      expect(fixture.tasks.dueChanges, isEmpty);

      await openCalendar(tester);
      await tapCalendarAction(tester, calendarClear);
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing);
      expect(dueCommands(fixture), <(TaskId, TaskDate?)>[
        (const TaskId(11), null),
      ]);

      // The undated child opens on today's month with nothing selected;
      // only a chosen day enables Set date, and Clear has nothing to clear.
      await tester.ensureVisible(find.text('Cached child'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cached child'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(12));
      await openCalendar(tester);
      expectCalendarState(tester, year: 2026, month: 8, selected: null);
      expect(tester.widget<FilledButton>(calendarSet).onPressed, isNull);
      expect(tester.widget<TextButton>(calendarClear).onPressed, isNull);
      await tapCalendarDay(tester, 15);
      expectCalendarState(
        tester,
        year: 2026,
        month: 8,
        selected: TaskDate(2026, 8, 15),
      );
      await tapCalendarAction(tester, calendarSet);
      await tester.pumpAndSettle();
      expect(dueCommands(fixture).last, (
        const TaskId(12),
        TaskDate(2026, 8, 15),
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('09 a failed date change keeps the calendar and its choice', (
      tester,
    ) async {
      final fixture = await _pumpPhoneShell(tester, viewport, clock: clock);
      fixture.tasks.dueResult = const Outcome<TaskDueChangeReceipt>.failure(
        Failure(
          code: 'task.synthetic_due_rejected',
          category: FailureCategory.persistence,
          operation: FailureOperation.write,
          retry: RetryClassification.permanent,
          impact: 'Synthetic due failure.',
          safeSummary: 'Synthetic due failure.',
        ),
      );
      await _tapRowTitle(tester, 'Cached parent');
      await openCalendar(tester);
      await tapCalendarDay(tester, 25);
      await tapCalendarAction(tester, calendarSet);
      await tester.pumpAndSettle();

      expect(calendarDialog, findsOneWidget, reason: 'nothing was stored');
      expect(
        find.byKey(const Key('task-date-calendar-failure')),
        findsOneWidget,
      );
      expectCalendarState(
        tester,
        year: 2026,
        month: 8,
        selected: TaskDate(2026, 8, 25),
      );
      fixture.tasks.dueResult = null;
      await tapCalendarAction(tester, calendarSet);
      await tester.pumpAndSettle();
      expect(calendarDialog, findsNothing, reason: 'the retry succeeded');
      expect(dueCommands(fixture), <(TaskId, TaskDate?)>[
        (const TaskId(11), TaskDate(2026, 8, 25)),
        (const TaskId(11), TaskDate(2026, 8, 25)),
      ]);
      expect(tester.takeException(), isNull);
    });

    for (final calendarViewport in <PhoneViewport>[
      for (final shortSide in <double>[320, 360, 443])
        for (final orientation in PhoneOrientation.values)
          for (final textScale in <double>[1, 2])
            PhoneViewport(shortSide, orientation, textScale),
    ]) {
      testWidgets('09 a subtask date from the calendar at $calendarViewport', (
        tester,
      ) async {
        final fixture = await _pumpSelectionShell(
          tester,
          calendarViewport,
          clock: clock,
        );
        await _tapRowTitle(tester, 'Cached parent');
        final child = find.text('Cached child');
        await tester.ensureVisible(child);
        await tester.pumpAndSettle();
        await tester.tap(child);
        await tester.pumpAndSettle();
        expect(fixture.viewModel.state.selectedTaskId, const TaskId(12));
        await openCalendar(tester);
        expect(tester.takeException(), isNull, reason: 'calendar layout');

        final dialog = tester.getRect(calendarDialog);
        final screen = Offset.zero & calendarViewport.logicalSize;
        expect(
          screen.contains(dialog.topLeft) &&
              screen.contains(dialog.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: 'the calendar fits the screen: $dialog',
        );
        for (final (action, label) in <(Finder, String)>[
          (calendarCancel, 'Cancel'),
          (calendarSet, 'Set date'),
        ]) {
          expect(action.hitTestable(), findsOneWidget, reason: label);
          expect(
            dialog.contains(tester.getCenter(action)),
            isTrue,
            reason: '$label stays inside the dialog',
          );
        }
        await tapCalendarDay(tester, 20);
        expectCalendarState(
          tester,
          year: 2026,
          month: 8,
          selected: TaskDate(2026, 8, 20),
        );
        expectTouchTarget(tester, calendarSet, label: 'Set date');
        expectTouchTarget(tester, calendarCancel, label: 'Cancel');
        await tapCalendarAction(tester, calendarSet);
        await tester.pumpAndSettle();
        expect(calendarDialog, findsNothing);
        expect(dueCommands(fixture), <(TaskId, TaskDate?)>[
          (const TaskId(12), TaskDate(2026, 8, 20)),
        ]);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

const _taskMenuLabels = <String>[
  'Open details',
  'Complete task',
  'Edit task…',
  'Choose date…',
  'Move to list…',
  'Delete task',
];

Finder _rowCompletion(int taskId) => find.descendant(
  of: find.byKey(Key('desktop-task-row-$taskId')),
  matching: find.byTooltip('Complete task'),
);

Finder _rowOverflow(int taskId, String title) => find.descendant(
  of: find.byKey(Key('desktop-task-row-$taskId')),
  matching: find.byTooltip('Task actions for $title'),
);

/// Starts the phone shell upright at [viewport]'s width and text scale, then
/// rotates to [viewport], as a user turning the phone would.
Future<_ShellFixture> _pumpSelectionShell(
  WidgetTester tester,
  PhoneViewport viewport, {
  Clock? clock,
}) async {
  final fixture = await _pumpPhoneShell(
    tester,
    PhoneViewport(
      viewport.shortSide,
      PhoneOrientation.portrait,
      viewport.textScale,
    ),
    clock: clock,
  );
  tester.view.physicalSize = viewport.logicalSize;
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '$viewport row layout');
  return fixture;
}

/// Scrolls the task row titled [title] into view and taps it by touch.
Future<void> _tapRowTitle(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title, skipOffstage: false));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).hitTestable());
  await tester.pumpAndSettle();
}

/// Scrolls the task row titled [title] into view and long-presses it.
Future<void> _longPressRowTitle(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title, skipOffstage: false));
  await tester.pumpAndSettle();
  await tester.longPress(find.text(title).hitTestable());
  await tester.pumpAndSettle();
}

/// Pumps the real shell with the Android theme at a phone [viewport] and
/// text scale, so touch-sized tap targets apply.
Future<_ShellFixture> _pumpPhoneShell(
  WidgetTester tester,
  PhoneViewport viewport, {
  DensityPreference density = DensityPreference.standard,
  Clock? clock,
  CachedTasksSnapshot? snapshot,
  SyncHealth? health,
}) async {
  // Android status and navigation bars take room from the shell.
  tester.view
    ..physicalSize = viewport.logicalSize
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(top: 24, bottom: 48)
    ..viewPadding = const FakeViewPadding(top: 24, bottom: 48);
  tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final preferences = _WorkspacePreferences()
    ..current = const DevicePreferences.defaults().copyWith(density: density);
  final fixture = _ShellFixture(
    health ?? _health(SyncHealthOutcome.good),
    preferencesRepository: preferences,
    taskListsRepository: _TaskListsRepository(),
    clock: clock,
    snapshot: snapshot,
  );
  addTearDown(fixture.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: axiotaskTheme(
        Brightness.light,
        density,
        fontFamily: androidTextFontFamily,
        platform: TargetPlatform.android,
      ),
      home: AdaptiveShell(
        viewModel: fixture.viewModel,
        preferencesRepository: preferences,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('desktop-task-row-11')), findsOneWidget);
  expect(tester.takeException(), isNull, reason: '$viewport row layout');
  return fixture;
}

Future<void> _chooseCollectionAction(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Collection actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
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
    this.preferencesRepository,
  }) : tasks = _TasksRepository(),
       healthRepository = _HealthRepository() {
    viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      taskListsRepository: taskListsRepository,
      preferencesRepository: preferencesRepository,
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
  final PreferencesRepository? preferencesRepository;
  late final TasksViewModel viewModel;

  Widget get widget => MaterialApp(
    home: AdaptiveShell(
      viewModel: viewModel,
      preferencesRepository: preferencesRepository,
    ),
  );

  void dispose() => viewModel.dispose();
}

final class _WorkspacePreferences implements PreferencesRepository {
  final StreamController<DevicePreferences> _changes =
      StreamController<DevicePreferences>.broadcast();
  final List<DesktopWorkspacePreferences> workspaceWrites =
      <DesktopWorkspacePreferences>[];
  var current = const DevicePreferences.defaults();

  @override
  Stream<DevicePreferences> watchDevicePreferences() async* {
    yield current;
    yield* _changes.stream;
  }

  @override
  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  ) async {
    workspaceWrites.add(preferences);
    current = current.copyWith(workspace: preferences);
    _changes.add(current);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => const Stream<Map<TaskListId, ListPreferences>>.empty();

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => const Stream<Map<ViewKey, ViewPreferences>>.empty();

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => const Stream<ListPreferences>.empty();

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => const Stream<ViewPreferences>.empty();
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

final class _TasksRepository
    implements
        TasksRepository,
        TaskDuplicationRepository,
        BulkTasksRepository,
        BulkTaskOperationsRepository,
        DestructiveTaskOperationsRepository {
  late CachedTasksSnapshot snapshot;
  Future<Outcome<TaskId>> createResult = Future.value(
    const Outcome<TaskId>.success(TaskId(90)),
  );
  Future<Outcome<void>> applyResult = Future.value(
    const Outcome<void>.success(null),
  );
  final List<CreateTaskCommand> created = <CreateTaskCommand>[];
  final List<DuplicateTaskCommand> duplicated = <DuplicateTaskCommand>[];
  final List<BulkCreateTasksCommand> bulkCreated = <BulkCreateTasksCommand>[];
  final List<ExistingTaskCommand> applied = <ExistingTaskCommand>[];
  final undoController = StreamController<List<TaskDeleteUndo>>.broadcast();
  final dueUndoController =
      StreamController<List<TaskDueChangeUndo>>.broadcast();
  final groupUndoController =
      StreamController<List<TaskDeleteGroupUndo>>.broadcast();
  final List<SetTaskDueCommand> dueChanges = <SetTaskDueCommand>[];

  /// When set, every due change is recorded and answered with this result.
  Outcome<TaskDueChangeReceipt>? dueResult;
  final List<UndoTaskDueChangeCommand> dueUndos = <UndoTaskDueChangeCommand>[];
  final List<DeleteTaskCommand> deleted = <DeleteTaskCommand>[];
  final List<UndoTaskDeleteCommand> undone = <UndoTaskDeleteCommand>[];
  final List<BulkExistingTaskCommand> bulkApplied = <BulkExistingTaskCommand>[];

  /// When set, bulk commands are recorded but complete only after it does.
  Future<void>? bulkGate;
  final List<ClearCompletedTasksCommand> clearedCompleted =
      <ClearCompletedTasksCommand>[];
  final List<UndoTaskDeleteGroupCommand> groupUndos =
      <UndoTaskDeleteGroupCommand>[];

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) {
    created.add(command);
    return createResult;
  }

  @override
  Future<Outcome<TaskDuplicateReceipt>> duplicateTask(
    DuplicateTaskCommand command,
  ) async {
    duplicated.add(command);
    final source = snapshot.tasks.singleWhere(
      (task) => task.id == command.sourceTaskId,
    );
    return Outcome.success(
      TaskDuplicateReceipt(
        sourceTaskId: source.id,
        taskId: const TaskId(95),
        title: planTaskDuplicate(source).title,
      ),
    );
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
    return dueResult ?? const Outcome.success(TaskDueChangeReceipt(undo: null));
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

  @override
  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  ) async {
    bulkApplied.add(command);
    await bulkGate;
    final summary = BulkOperationSummary(
      operationId: 41,
      kind: switch (command) {
        BulkCompleteTasksCommand() => BulkOperationKind.complete,
        BulkRescheduleTasksCommand() => BulkOperationKind.reschedule,
        BulkMoveTasksCommand() => BulkOperationKind.move,
        BulkDeleteTasksCommand() => BulkOperationKind.delete,
      },
      selectedCount: command.taskIds.length,
      affectedCount: command.taskIds.length,
      confirmedCount: 1,
      pendingCount: command.taskIds.length - 1,
      failedCount: 0,
      createdAt: DateTime.utc(2026, 8, 15, 12),
    );
    return Outcome.success(
      BulkOperationReceipt(
        summary: summary,
        taskIds: command.taskIds.toList(),
        deleteGroupId: command is BulkDeleteTasksCommand ? 91 : null,
        notBefore: command is BulkDeleteTasksCommand
            ? DateTime.utc(2026, 8, 15, 12, 0, 30)
            : null,
      ),
    );
  }

  @override
  Future<Outcome<BulkOperationReceipt>> clearCompleted(
    ClearCompletedTasksCommand command,
  ) async {
    clearedCompleted.add(command);
    return Outcome.success(
      BulkOperationReceipt(
        summary: BulkOperationSummary(
          operationId: 42,
          kind: BulkOperationKind.clearCompleted,
          selectedCount: 1,
          affectedCount: 1,
          confirmedCount: 0,
          pendingCount: 1,
          failedCount: 0,
          createdAt: DateTime.utc(2026, 8, 15, 12),
        ),
        taskIds: const <TaskId>[TaskId(33)],
      ),
    );
  }

  @override
  Stream<List<TaskDeleteGroupUndo>> watchUndoableTaskDeleteGroups(
    AccountId accountId,
  ) => groupUndoController.stream;

  @override
  Future<Outcome<void>> undoTaskDeleteGroup(
    UndoTaskDeleteGroupCommand command,
  ) async {
    groupUndos.add(command);
    return const Outcome<void>.success(null);
  }

  @override
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId) =>
      const Stream<BulkOperationSummary?>.empty();
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

Future<void> _search(WidgetTester tester, String query) async {
  await tester.tap(find.byTooltip('Search tasks'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('search-input')), query);
  await tester.pumpAndSettle();
}

/// The search result row whose subtitle contains [match].
Finder _searchHit(String match) => find.ancestor(
  of: find.textContaining(match),
  matching: find.byType(ListTile),
);

/// Whether the details' Previous and Next controls are enabled.
(bool, bool) _detailNavigationEnabled(WidgetTester tester) => (
  tester
          .widget<IconButton>(find.byKey(const Key('task-detail-previous')))
          .onPressed !=
      null,
  tester
          .widget<IconButton>(find.byKey(const Key('task-detail-next')))
          .onPressed !=
      null,
);

CachedTask _navigationTask(int id, String title, {int list = 7, int? parent}) =>
    CachedTask(
      id: TaskId(id),
      accountId: const AccountId(1),
      taskListId: TaskListId(list),
      parentTaskId: parent == null ? null : TaskId(parent),
      remoteId: TaskRemoteId('synthetic-navigation-$id'),
      title: title,
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    );

/// A parent and its child with the same title, a sibling subtask, two more
/// tasks in the inbox, and a parent with a child in another list.
final _navigationSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: _snapshot.taskLists,
  tasks: <CachedTask>[
    _navigationTask(11, 'Shared title'),
    _navigationTask(12, 'Shared title', parent: 11),
    _navigationTask(13, 'Leaf task'),
    _navigationTask(14, 'Second child', parent: 11),
    _navigationTask(15, 'Another leaf'),
    _navigationTask(16, 'Archive parent', list: 8),
    _navigationTask(17, 'Archive needle child', list: 8, parent: 16),
  ],
  completeness: CacheCompleteness.complete,
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

final _destructiveSnapshot = CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: _snapshot.taskLists,
  tasks: const <CachedTask>[
    CachedTask(
      id: TaskId(31),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-unsafe-parent'),
      title: 'Completed parent kept safely',
      notes: null,
      status: TaskStatus.completed,
      due: null,
    ),
    CachedTask(
      id: TaskId(32),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: TaskId(31),
      remoteId: TaskRemoteId('synthetic-unfinished-child'),
      title: 'Unfinished child remains',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    ),
    CachedTask(
      id: TaskId(33),
      accountId: AccountId(1),
      taskListId: TaskListId(7),
      parentTaskId: null,
      remoteId: TaskRemoteId('synthetic-completed-leaf'),
      title: 'Completed leaf clears',
      notes: null,
      status: TaskStatus.completed,
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

/// Exposes only [TasksRepository], hiding the optional capabilities of
/// [_TasksRepository].
final class _PlainTasksRepository implements TasksRepository {
  _PlainTasksRepository(this._delegate);

  final _TasksRepository _delegate;

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      _delegate.watchTasks(query);

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      _delegate.watchUndoableTaskDeletes(accountId);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => _delegate.watchUndoableTaskDueChanges(accountId);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      _delegate.createTask(command);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      _delegate.apply(command);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      _delegate.setTaskDue(command);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      _delegate.deleteTask(command);

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      _delegate.undoTaskDelete(command);

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
      _delegate.undoTaskDueChange(command);
}
