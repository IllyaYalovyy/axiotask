import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
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
}

final class _ShellFixture {
  _ShellFixture(SyncHealth health, {Future<void> Function()? refreshRequested})
    : tasks = _TasksRepository(),
      healthRepository = _HealthRepository() {
    viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      syncHealthRepository: healthRepository,
      refreshRequested: refreshRequested,
    );
    tasks.snapshot = _snapshot;
    healthRepository.health = health;
  }

  final _TasksRepository tasks;
  final _HealthRepository healthRepository;
  late final TasksViewModel viewModel;

  Widget get widget => MaterialApp(
    home: AdaptiveShell(viewModel: viewModel, onHealthAction: (_) {}),
  );

  void dispose() => viewModel.dispose();
}

final class _TasksRepository implements TasksRepository {
  late CachedTasksSnapshot snapshot;

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) =>
      Stream.value(snapshot);
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
  ],
  completeness: CacheCompleteness.complete,
);
