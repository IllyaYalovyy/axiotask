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
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/fake_google_tasks_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'offline create resumes through the app coordinator and confirms remotely',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15a-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = await AppDatabase.openFile(
        File('${root.path}/isolated.sqlite'),
      );
      const subject = AccountSubject('synthetic-create-publish-linux');
      final account = AccountId(await database.createAccount(subject.value));
      final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
      final settings = DatabaseSyncSettingsRepository(database);
      await settings.setSyncEnabled(account, false);
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final tasks = DatabaseTasksRepository(database, clock: clock);
      final list =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Resume list',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final task =
          (await tasks.createTask(
                    CreateTaskCommand(
                      accountId: account,
                      taskListId: list,
                      title: 'Resume task',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      final remote = FakeGoogleTasksService();
      final authorization = const SyntheticAuthorization(subject);
      final coordinator = SyncCoordinator(
        accountId: account,
        authorization: authorization,
        clock: clock,
        scheduler: clock,
        settings: settings,
        run: (request) =>
            SyncEngine(
              store: DatabaseReadSyncStore(database),
              googleTasks: remote,
              authorization: authorization,
              clock: clock,
              random: SequenceRandomSource(
                List<int>.generate(256, (index) => index % 256),
              ),
              control: request.control,
            ).run(
              SyncRunRequest(
                accountId: account,
                triggers: request.triggers
                    .map((trigger) => trigger.value)
                    .toSet(),
              ),
            ),
      );
      await coordinator.start();
      final viewModel = TasksViewModel(
        accountId: account,
        tasksRepository: tasks,
        taskListsRepository: lists,
        syncHealthRepository: DatabaseSyncHealthRepository(
          dao: SyncHealthDao(database),
          clock: clock,
          runtime: coordinator,
        ),
        refreshRequested: coordinator.refresh,
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
      expect(find.text('Sync stopped'), findsWidgets);
      expect(find.text('2 unresolved'), findsOneWidget);

      await coordinator.resume();
      await coordinator.whenIdle;
      await tester.pumpAndSettle();

      expect(find.text('Synced'), findsWidgets);
      expect(find.text('Resume list'), findsWidgets);
      expect(find.text('Resume task'), findsOneWidget);
      final snapshot = await tasks
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(snapshot.taskLists.single.id, list);
      expect(snapshot.tasks.single.id, task);
      expect(snapshot.taskLists.single.remoteId, isNotNull);
      expect(snapshot.tasks.single.remoteId, isNotNull);
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
    },
  );
}
