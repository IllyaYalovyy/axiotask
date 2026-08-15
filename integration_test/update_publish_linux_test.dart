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
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
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
    'offline list and task updates survive restart and confirm on Resume',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15b-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      var database = await AppDatabase.openFile(file);
      const subject = AccountSubject('synthetic-update-publish-linux');
      final account = AccountId(await database.createAccount(subject.value));
      final clock = ManualClock(DateTime.utc(2026, 8, 15, 15));
      final remote = FakeGoogleTasksService();
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Original remote list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final remoteTask = switch (await remote.createTask(
        CreateTaskOperation(
          taskListId: remoteList.id,
          title: 'Original remote task',
          notes: 'Original notes',
          status: RemoteTaskStatus.needsAction,
          due: const RemoteDate(2026, 8, 20),
        ),
      )) {
        CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) =>
          value,
        _ => throw StateError('Synthetic task setup failed.'),
      };
      const authorization = SyntheticAuthorization(subject);
      SyncEngine engine(AppDatabase current) => SyncEngine(
        store: DatabaseReadSyncStore(current),
        googleTasks: remote,
        authorization: authorization,
        clock: clock,
        random: SequenceRandomSource(
          List<int>.generate(256, (index) => index % 256),
        ),
      );
      expect(
        (await engine(
          database,
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.succeeded,
      );
      final initial = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      final listId = initial.taskLists
          .singleWhere((list) => list.remoteId?.value == remoteList.id.value)
          .id;
      final taskId = initial.tasks
          .singleWhere((task) => task.remoteId?.value == remoteTask.id.value)
          .id;
      await DatabaseSyncSettingsRepository(
        database,
      ).setSyncEnabled(account, false);
      await database.close();

      database = await AppDatabase.openFile(file);
      final settings = DatabaseSyncSettingsRepository(database);
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final tasks = DatabaseTasksRepository(database, clock: clock);
      expect(
        await lists.renameTaskList(
          RenameTaskListCommand(
            accountId: account,
            taskListId: listId,
            title: 'Offline renamed list',
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await tasks.apply(
          UpdateTaskContentCommand(
            accountId: account,
            taskId: taskId,
            title: 'Updated offline task',
            notes: null,
            status: TaskStatus.completed,
            due: null,
          ),
        ),
        isA<Success<void>>(),
      );

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
      expect(find.text('Offline renamed list'), findsWidgets);
      expect(find.text('Updated offline task'), findsOneWidget);

      await coordinator.resume();
      await coordinator.whenIdle;
      await tester.pumpAndSettle();

      expect(find.text('Synced'), findsWidgets);
      final updateCalls = remote.calls
          .where(
            (call) =>
                call.operation == FakeGoogleTasksMethod.patchTask ||
                call.operation == FakeGoogleTasksMethod.renameTaskList,
          )
          .toList(growable: false);
      expect(updateCalls.map((call) => call.operation), <FakeGoogleTasksMethod>[
        FakeGoogleTasksMethod.patchTask,
        FakeGoogleTasksMethod.renameTaskList,
      ]);
      expect(updateCalls.first.body, <String, Object?>{
        'title': 'Updated offline task',
        'notes': null,
        'status': 'completed',
        'due': null,
      });
      expect(updateCalls.last.body, <String, Object?>{
        'title': 'Offline renamed list',
      });
    },
  );
}
