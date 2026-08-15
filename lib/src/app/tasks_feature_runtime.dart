import '../core/failure.dart';
import '../core/outcome.dart';
import '../data/auth/authorization.dart';
import '../data/connectivity/connectivity.dart';
import '../data/database/app_database.dart';
import '../data/database/production_database.dart';
import '../data/database/read_sync_store.dart';
import '../data/database/sync_health_dao.dart';
import '../data/database/sync_health_repository.dart';
import '../data/database/sync_settings_repository.dart';
import '../data/database/task_lists_repository.dart';
import '../data/database/tasks_repository.dart';
import '../domain/commands/task_commands.dart';
import '../domain/model/tasks.dart';
import '../domain/repository/tasks_repository.dart';
import '../features/tasks/tasks_view_model.dart';
import '../sync/coordinator/sync_coordinator.dart';
import '../sync/engine.dart';
import '../sync/health/sync_health.dart';
import '../sync/health/sync_health_repository.dart';
import '../sync/run.dart';
import 'composition/app_composition.dart';
import 'lifecycle.dart';

final class TasksFeatureRuntime {
  const TasksFeatureRuntime._({
    required this.viewModel,
    required this.database,
    required this.coordinator,
    required this.transport,
  });

  final TasksViewModel viewModel;
  final AppDatabase database;
  final SyncCoordinator? coordinator;
  final ReadSliceTransport? transport;

  static Future<TasksFeatureRuntime> open(
    AppComposition composition, {
    AppDatabase? injectedDatabase,
    LifecyclePort? lifecycle,
    ConnectivityPort? connectivity,
  }) async {
    final database =
        injectedDatabase ??
        await openProductionDatabase(composition.boundary.storage.databaseName);
    var accounts = await database.allAccounts();
    final configuredSubject = composition.configuredAccountSubject;
    if (accounts.isEmpty && configuredSubject != null) {
      await database.createAccount(configuredSubject.value);
      accounts = await database.allAccounts();
    }
    if (accounts.isEmpty) {
      return TasksFeatureRuntime._(
        viewModel: TasksViewModel(
          accountId: const AccountId(1),
          tasksRepository: const _EmptyTasksRepository(),
          syncHealthRepository: _NoAuthorizationHealthRepository(
            composition.clock.now(),
          ),
        ),
        database: database,
        coordinator: null,
        transport: null,
      );
    }

    final accountId = AccountId(accounts.first.id);
    final subject = AccountSubject(accounts.first.googleSubject);
    final transport = await composition.createReadTransport(subject);
    final coordinator = SyncCoordinator(
      accountId: accountId,
      authorization: transport.authorization,
      clock: composition.clock,
      scheduler: composition.scheduler,
      settings: DatabaseSyncSettingsRepository(database),
      lifecycle: lifecycle,
      connectivity: connectivity,
      run: (request) =>
          SyncEngine(
            store: DatabaseReadSyncStore(database),
            googleTasks: transport.googleTasks,
            authorization: transport.authorization,
            clock: composition.clock,
            random: composition.randomness,
            control: request.control,
          ).run(
            SyncRunRequest(
              accountId: accountId,
              triggers: request.triggers
                  .map((trigger) => trigger.value)
                  .toSet(),
            ),
          ),
    );
    final healthRepository = DatabaseSyncHealthRepository(
      dao: SyncHealthDao(database),
      clock: composition.clock,
      runtime: coordinator,
    );
    return TasksFeatureRuntime._(
      viewModel: TasksViewModel(
        accountId: accountId,
        tasksRepository: DatabaseTasksRepository(
          database,
          clock: composition.clock,
        ),
        taskListsRepository: DatabaseTaskListsRepository(
          database: database,
          clock: composition.clock,
        ),
        syncHealthRepository: healthRepository,
        localEditCommitted: coordinator.localEditCommitted,
        refreshRequested: coordinator.refresh,
        stopSyncRequested: coordinator.stop,
        resumeSyncRequested: coordinator.resume,
      ),
      database: database,
      coordinator: coordinator,
      transport: transport,
    );
  }

  Future<void> start() => coordinator?.start() ?? Future<void>.value();

  Future<void> close() async {
    viewModel.dispose();
    await coordinator?.close();
    await transport?.close();
    await database.close();
  }
}

final class _EmptyTasksRepository implements TasksRepository {
  const _EmptyTasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: <CachedTaskList>[],
      tasks: <CachedTask>[],
      completeness: CacheCompleteness.unobserved,
    ),
  );

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.failure(_noTaskAccountFailure));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome<void>.failure(_noTaskAccountFailure));
}

const Failure _noTaskAccountFailure = Failure(
  code: 'task.account_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'No configured account partition is available.',
);

final class _NoAuthorizationHealthRepository implements SyncHealthRepository {
  const _NoAuthorizationHealthRepository(this._now);

  final DateTime _now;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.noAuthorization,
      action: SyncHealthAction.connect,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: _now,
    ),
  );
}
