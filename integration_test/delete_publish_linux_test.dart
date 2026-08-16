import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/delete_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
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
    'task delete Undo restores identity and expiry deletes from Google',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s17-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = await AppDatabase.openFile(
        File('${root.path}/isolated.sqlite'),
      );
      const subject = AccountSubject('synthetic-delete-publish-linux');
      final account = AccountId(await database.createAccount(subject.value));
      final clock = ManualClock(DateTime.utc(2026, 8, 15, 12));
      final remote = FakeGoogleTasksService();
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic delete list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final remoteTask = switch (await remote.createTask(
        CreateTaskOperation(
          taskListId: remoteList.id,
          title: 'Synthetic delete target',
          status: RemoteTaskStatus.needsAction,
        ),
      )) {
        CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) =>
          value,
        _ => throw StateError('Synthetic task setup failed.'),
      };
      const authorization = SyntheticAuthorization(subject);
      final tasks = DatabaseTasksRepository(database, clock: clock);
      final coordinator = SyncCoordinator(
        accountId: account,
        authorization: authorization,
        clock: clock,
        scheduler: clock,
        random: SequenceRandomSource(
          List<int>.generate(512, (index) => index % 256),
        ),
        settings: DatabaseSyncSettingsRepository(database),
        retryStore: DatabaseReadSyncStore(database),
        reauthorizationStore: DatabaseReadSyncStore(database),
        taskDeleteEligibility: _DeleteEligibility(database),
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
      final viewModel = TasksViewModel(
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
        localEditCommitted: coordinator.localEditCommitted,
        taskDeleteCommitted: coordinator.taskDeleteCommitted,
        refreshRequested: coordinator.refresh,
        retryRequested: coordinator.retry,
      );
      addTearDown(() async {
        viewModel.dispose();
        await coordinator.close();
        remote.close();
        await database.close();
      });

      await coordinator.start();
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();
      final original =
          (await tasks.watchTasks(TasksQuery(accountId: account)).first)
              .tasks
              .single;
      expect(original.remoteId?.value, remoteTask.id.value);

      await tester.tap(find.text('Synthetic delete target'));
      await tester.pump();
      await tester.tap(find.byTooltip('Delete task'));
      await tester.pumpAndSettle();
      expect(find.text('“Synthetic delete target” deleted'), findsOneWidget);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 0);

      await tester.tap(find.widgetWithText(TextButton, 'Undo'));
      await tester.pumpAndSettle();
      final restored =
          (await tasks.watchTasks(TasksQuery(accountId: account)).first)
              .tasks
              .single;
      expect(restored.id, original.id);
      expect(restored.remoteId, original.remoteId);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 0);

      clock.advance(const Duration(seconds: 5));
      await tester.pump();
      await coordinator.whenIdle;
      viewModel.selectTask(restored.id);
      await tester.pump();
      await tester.tap(find.byTooltip('Delete task'));
      await tester.pumpAndSettle();
      clock.advance(const Duration(seconds: 29, milliseconds: 999));
      await tester.pump();
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 0);

      clock.advance(const Duration(milliseconds: 1));
      await tester.pump();
      await pumpEventQueue();
      await coordinator.whenIdle;

      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 1);
      final remoteRows = switch (await remote.listTasks(remoteList.id)) {
        Success<RemotePage<RemoteTask>>(:final value) => value.items,
        _ => throw StateError('Synthetic task verification failed.'),
      };
      expect(
        remoteRows.whereType<RemoteTaskTombstone>().single.id,
        remoteTask.id,
      );
      expect(
        (await tasks.watchTasks(TasksQuery(accountId: account)).first).tasks,
        isEmpty,
      );
    },
  );
}

final class _DeleteEligibility implements TaskDeleteEligibilityStore {
  _DeleteEligibility(AppDatabase database) : _dao = DeleteStateDao(database);

  final DeleteStateDao _dao;

  @override
  Future<int> cleanupExpiredTaskDeletes({
    required AccountId accountId,
    required DateTime now,
  }) => _dao.cleanupExpiredTaskDeletes(accountId: accountId, now: now);

  @override
  Future<DateTime?> nextTaskDeleteExpiry(AccountId accountId) =>
      _dao.nextTaskDeleteExpiry(accountId);
}
