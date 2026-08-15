import '../data/auth/authorization.dart';
import '../data/database/app_database.dart';
import '../data/database/production_database.dart';
import '../data/database/read_sync_store.dart';
import '../data/database/sync_health_dao.dart';
import '../data/database/sync_health_repository.dart';
import '../data/database/tasks_repository.dart';
import '../domain/model/tasks.dart';
import '../domain/repository/tasks_repository.dart';
import '../features/tasks/tasks_view_model.dart';
import '../sync/engine.dart';
import '../sync/health/sync_health.dart';
import '../sync/health/sync_health_repository.dart';
import '../sync/run.dart';
import 'composition/app_composition.dart';
import 'foreground_read_coordinator.dart';
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
  final ForegroundReadCoordinator? coordinator;
  final ReadSliceTransport? transport;

  static Future<TasksFeatureRuntime> open(
    AppComposition composition, {
    AppDatabase? injectedDatabase,
    LifecyclePort? lifecycle,
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
    final coordinator = ForegroundReadCoordinator(
      accountId: accountId,
      authorization: transport.authorization,
      lifecycle: lifecycle,
      run: (triggers) => SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: transport.googleTasks,
        authorization: transport.authorization,
        clock: composition.clock,
        random: composition.randomness,
      ).run(SyncRunRequest(accountId: accountId, triggers: triggers)),
    );
    final healthRepository = DatabaseSyncHealthRepository(
      dao: SyncHealthDao(database),
      clock: composition.clock,
      runtime: coordinator,
    );
    return TasksFeatureRuntime._(
      viewModel: TasksViewModel(
        accountId: accountId,
        tasksRepository: DatabaseTasksRepository(database),
        syncHealthRepository: healthRepository,
        refreshRequested: coordinator.refresh,
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
}

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
