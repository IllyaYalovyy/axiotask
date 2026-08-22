import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_external_link_launcher.dart';

void main() {
  testWidgets(
    'PAR-LINK-001/002/003 keep Google and user-authored actions distinct',
    (tester) async {
      final launcher = FakeExternalLinkLauncher();
      final fixture = _Fixture(
        launcher,
        webViewLink: Uri.parse(
          'https://tasks.google.com/task/synthetic-widget-task',
        ),
        notes:
            'Reference https://docs.example.test/guide and '
            'mailto:ignored@example.test.',
      );
      addTearDown(fixture.dispose);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(fixture.widget);
      await tester.pump();
      await tester.tap(find.text('Synthetic linked task'));
      await tester.pump();

      expect(find.text('Open in Google Tasks'), findsOneWidget);
      expect(find.text('Links in task content'), findsOneWidget);
      expect(find.text('docs.example.test/guide'), findsOneWidget);
      expect(
        find.textContaining('features not exposed by the API'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('task-content-link-1')), findsNothing);

      final semantics = tester.getSemantics(
        find.byKey(const Key('open-in-google-tasks-action')),
      );
      expect(semantics.label, 'Open task in Google Tasks');
      expect(semantics.flagsCollection.isButton, isTrue);
      final externalSemantics = tester.getSemantics(
        find.byKey(const Key('task-content-link-0')),
      );
      expect(externalSemantics.label, contains('Open external task link'));
      expect(externalSemantics.label, isNot(contains('Google Tasks')));

      await tester.ensureVisible(
        find.byKey(const Key('open-in-google-tasks-action')),
      );
      await tester.tap(find.byKey(const Key('open-in-google-tasks-action')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('task-content-link-0')));
      await tester.tap(find.byKey(const Key('task-content-link-0')));
      await tester.pump();
      expect(launcher.launched, <Uri>[
        Uri.parse('https://tasks.google.com/task/synthetic-widget-task'),
        Uri.parse('https://docs.example.test/guide'),
      ]);
    },
  );

  testWidgets('every task keeps an explained Google action without a link', (
    tester,
  ) async {
    final launcher = FakeExternalLinkLauncher();
    final fixture = _Fixture(launcher, webViewLink: null, notes: null);
    addTearDown(fixture.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.text('Synthetic linked task'));
    await tester.pump();

    expect(find.text('Open in Google Tasks'), findsOneWidget);
    expect(
      find.byKey(const Key('open-in-google-tasks-action')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Google has not provided a usable link'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('open-in-google-tasks-action')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('invalid Google link is explained and never launched', (
    tester,
  ) async {
    final launcher = FakeExternalLinkLauncher();
    final fixture = _Fixture(
      launcher,
      webViewLink: Uri.parse('javascript:alert(1)'),
      notes: null,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.text('Synthetic linked task'));
    await tester.pump();

    expect(
      find.textContaining('Google has not provided a usable link'),
      findsOneWidget,
    );
    expect(launcher.launched, isEmpty);
  });

  testWidgets('launch failure is visible and remains retryable', (
    tester,
  ) async {
    final launcher = FakeExternalLinkLauncher(succeeds: false);
    final fixture = _Fixture(
      launcher,
      webViewLink: Uri.parse(
        'https://tasks.google.com/task/synthetic-widget-task',
      ),
      notes: 'https://docs.example.test/guide',
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.widget);
    await tester.pump();
    await tester.tap(find.text('Synthetic linked task'));
    await tester.pump();
    final googleAction = find.byKey(const Key('open-in-google-tasks-action'));
    await tester.ensureVisible(googleAction);
    await tester.tap(googleAction);
    await tester.pump();

    expect(find.text('Could not open Google Tasks.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(googleAction).onPressed, isNotNull);

    await tester.ensureVisible(find.byKey(const Key('task-content-link-0')));
    await tester.tap(find.byKey(const Key('task-content-link-0')));
    await tester.pump();
    expect(find.text('Could not open the external link.'), findsOneWidget);
    expect(launcher.launched, hasLength(2));
  });
}

final class _Fixture {
  _Fixture(
    FakeExternalLinkLauncher launcher, {
    required Uri? webViewLink,
    required String? notes,
  }) : repository = _TasksRepository(
         CachedTask(
           id: const TaskId(11),
           accountId: const AccountId(1),
           taskListId: const TaskListId(7),
           parentTaskId: null,
           remoteId: const TaskRemoteId('synthetic-widget-task'),
           title: 'Synthetic linked task',
           notes: notes,
           status: TaskStatus.needsAction,
           due: null,
           webViewLink: webViewLink,
         ),
       ),
       viewModel = TasksViewModel(
         accountId: const AccountId(1),
         tasksRepository: _TasksRepository(
           CachedTask(
             id: const TaskId(11),
             accountId: const AccountId(1),
             taskListId: const TaskListId(7),
             parentTaskId: null,
             remoteId: const TaskRemoteId('synthetic-widget-task'),
             title: 'Synthetic linked task',
             notes: notes,
             status: TaskStatus.needsAction,
             due: null,
             webViewLink: webViewLink,
           ),
         ),
         syncHealthRepository: const _HealthRepository(),
         externalLinkLauncher: launcher,
       ) {
    viewModel.start();
  }

  final _TasksRepository repository;
  final TasksViewModel viewModel;

  Widget get widget => MaterialApp(home: AdaptiveShell(viewModel: viewModel));

  void dispose() => viewModel.dispose();
}

final class _TasksRepository implements TasksRepository {
  _TasksRepository(this.task);

  final CachedTask task;

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[
        CachedTaskList(
          id: TaskListId(7),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-widget-list'),
          title: 'Synthetic links',
        ),
      ],
      tasks: <CachedTask>[task],
      completeness: CacheCompleteness.complete,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome.success(TaskId(90));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome.success(null);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => Outcome.success(
    TaskDeleteReceipt(taskId: command.taskId, notBefore: DateTime.utc(2026)),
  );

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome.success(TaskDueChangeReceipt(undo: null));

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome.success(null);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome.success(null);
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
      counts: const SyncWorkCounts(pending: 1),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15),
    ),
  );
}
