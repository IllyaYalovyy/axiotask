import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_google_tasks_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quick capture survives restart and publishes ordinary create', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s24a-linux-integration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
    const subject = AccountSubject('synthetic-quick-capture-linux');

    var database = await AppDatabase.openFile(file);
    final account = AccountId(await database.createAccount(subject.value));
    final settings = DatabaseSyncSettingsRepository(database);
    await settings.setSyncEnabled(account, false);
    final lists = DatabaseTaskListsRepository(database: database, clock: clock);
    final list =
        (await lists.createTaskList(
                  CreateTaskListCommand(
                    accountId: account,
                    title: 'Synthetic capture list',
                  ),
                )
                as Success<TaskListId>)
            .value;
    var tasks = DatabaseTasksRepository(database, clock: clock);
    var viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: tasks,
      taskListsRepository: lists,
      syncHealthRepository: const _StoppedHealthRepository(),
      clock: clock,
    );
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('quick-add-input')),
      'Publish synthetic capture tomorrow',
    );
    await tester.pump();
    expect(find.text('Synthetic capture list'), findsWidgets);
    expect(find.text('Due 2026-08-16'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    viewModel.dispose();
    await database.close();

    database = await AppDatabase.openFile(file);
    tasks = DatabaseTasksRepository(database, clock: clock);
    final restarted = await tasks
        .watchTasks(TasksQuery(accountId: account))
        .first;
    expect(restarted.tasks.single.title, 'Publish synthetic capture');
    expect(restarted.tasks.single.due, TaskDate(2026, 8, 16));
    expect(restarted.tasks.single.remoteId, isNull);
    expect(restarted.tasks.single.taskListId, list);

    final remote = FakeGoogleTasksService();
    const authorization = SyntheticAuthorization(subject);
    final restartedSettings = DatabaseSyncSettingsRepository(database);
    final coordinator = SyncCoordinator(
      accountId: account,
      authorization: authorization,
      clock: clock,
      scheduler: clock,
      random: SequenceRandomSource(
        List<int>.generate(512, (index) => index % 256),
      ),
      settings: restartedSettings,
      retryStore: DatabaseReadSyncStore(database),
      reauthorizationStore: DatabaseReadSyncStore(database),
      run: (request) =>
          SyncEngine(
            store: DatabaseReadSyncStore(database),
            googleTasks: remote,
            authorization: authorization,
            clock: clock,
            scheduler: clock,
            random: SequenceRandomSource(
              List<int>.generate(256, (index) => index % 256),
            ),
            retryObserver: request.retryObserver,
            control: request.control,
          ).run(
            SyncRunRequest(
              accountId: account,
              deadline: request.deadline,
              triggers: request.triggers
                  .map((trigger) => trigger.value)
                  .toSet(),
            ),
          ),
    );
    await coordinator.start();
    viewModel = TasksViewModel(
      accountId: account,
      tasksRepository: tasks,
      taskListsRepository: DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      ),
      syncHealthRepository: DatabaseSyncHealthRepository(
        dao: SyncHealthDao(database),
        clock: clock,
        runtime: coordinator,
      ),
      clock: clock,
      refreshRequested: coordinator.refresh,
      retryRequested: coordinator.retry,
      stopSyncRequested: coordinator.stop,
      resumeSyncRequested: coordinator.resume,
    );
    addTearDown(() async {
      viewModel.dispose();
      await coordinator.close();
      remote.close();
      await database.close();
    });
    await tester.pumpWidget(
      MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
    );
    await tester.pumpAndSettle();

    await coordinator.resume();
    await coordinator.whenIdle;
    await tester.pumpAndSettle();

    final confirmed = await tasks
        .watchTasks(TasksQuery(accountId: account))
        .first;
    expect(confirmed.tasks.single.remoteId, isNotNull);
    expect(confirmed.tasks.single.title, 'Publish synthetic capture');
    expect(confirmed.tasks.single.due, TaskDate(2026, 8, 16));
    expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
    expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
    expect(find.text('Synced'), findsWidgets);
  });
}

final class _StoppedHealthRepository implements SyncHealthRepository {
  const _StoppedHealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      counts: const SyncWorkCounts(pending: 1),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15, 12),
    ),
  );
}
