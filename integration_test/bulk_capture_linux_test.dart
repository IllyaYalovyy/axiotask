import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
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

  testWidgets(
    'bulk acknowledgement survives restart and exposes per-create partial result',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s24b-linux-integration-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
      const subject = AccountSubject('synthetic-bulk-capture-linux');

      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final settings = DatabaseSyncSettingsRepository(database);
      await settings.setSyncEnabled(account, false);
      final lists = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
      );
      final list =
          (await lists.createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Synthetic bulk target',
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
      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bulk-add-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bulk-add-input')),
        'Publish alpha\nPublish beta\nPublish gamma',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('bulk-add-submit')));
      await tester.tap(find.byKey(const Key('bulk-add-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('3 tasks saved locally and waiting for Google.'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      viewModel.dispose();
      await database.close();

      database = await AppDatabase.openFile(file);
      tasks = DatabaseTasksRepository(database, clock: clock);
      final restarted = await tasks
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(restarted.tasks.map((task) => task.title), [
        'Publish alpha',
        'Publish beta',
        'Publish gamma',
      ]);
      expect(restarted.tasks.every((task) => task.remoteId == null), isTrue);
      expect(restarted.tasks.every((task) => task.taskListId == list), isTrue);

      final remote = FakeGoogleTasksService();
      final partial = _RejectSecondTaskService(remote);
      const authorization = SyntheticAuthorization(subject);
      await DatabaseSyncSettingsRepository(
        database,
      ).setSyncEnabled(account, true);
      final report =
          await SyncEngine(
            store: DatabaseReadSyncStore(database),
            googleTasks: partial,
            authorization: authorization,
            clock: clock,
            scheduler: clock,
            random: SequenceRandomSource(
              List<int>.generate(256, (index) => index % 256),
            ),
          ).run(
            SyncRunRequest(
              accountId: account,
              deadline: const Duration(minutes: 2),
              triggers: const <String>{'bulk-capture-test'},
            ),
          );
      addTearDown(() async {
        partial.close();
        await database.close();
      });

      expect(report.outcome, SyncRunOutcome.failed);
      expect(partial.taskCreateTitles, ['Publish alpha', 'Publish beta']);
      final afterPartial = await tasks
          .watchTasks(TasksQuery(accountId: account))
          .first;
      expect(afterPartial.tasks[0].remoteId, isNotNull);
      expect(afterPartial.tasks[1].remoteId, isNull);
      expect(afterPartial.tasks[2].remoteId, isNull);
      expect(remote.taskCount, 1);
    },
  );
}

final class _RejectSecondTaskService
    implements GoogleTasksService, GoogleTasksRecoveryService {
  _RejectSecondTaskService(this.delegate);

  final FakeGoogleTasksService delegate;
  final List<String> taskCreateTitles = <String>[];

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) =>
      delegate.listTaskLists(pageToken: pageToken, cancellation: cancellation);

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) => delegate.listTasks(
    taskListId,
    pageToken: pageToken,
    cancellation: cancellation,
  );

  @override
  Future<Outcome<RemoteTaskList?>> getTaskList(
    RemoteTaskListId taskListId, {
    GoogleTasksReadCancellation? cancellation,
  }) => delegate.getTaskList(taskListId, cancellation: cancellation);

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => delegate.createTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async {
    taskCreateTitles.add(operation.title);
    if (taskCreateTitles.length == 2) {
      return const RejectedMutation<RemoteTask>(_rejectedCreateError);
    }
    return delegate.createTask(operation);
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => delegate.renameTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => delegate.deleteTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => delegate.patchTask(operation);

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => delegate.deleteTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => delegate.moveTask(operation);

  @override
  void close() => delegate.close();
}

const _rejectedCreateError = GoogleTasksMutationError(
  failure: Failure(
    code: 'synthetic.bulk_create_rejected',
    category: FailureCategory.remote,
    operation: FailureOperation.write,
    retry: RetryClassification.permanent,
    impact: 'One synthetic task was not created.',
    safeSummary: 'Synthetic bulk create rejection.',
  ),
  kind: GoogleTasksErrorKind.permanent,
  commitState: MutationCommitState.notCommitted,
);

final class _StoppedHealthRepository implements SyncHealthRepository {
  const _StoppedHealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      counts: const SyncWorkCounts(pending: 1),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 16, 12),
    ),
  );
}
