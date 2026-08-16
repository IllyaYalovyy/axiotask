import 'dart:async';

import '../core/failure.dart';
import '../core/outcome.dart';
import '../data/auth/authorization.dart';
import '../data/connectivity/connectivity.dart';
import '../data/database/app_database.dart';
import '../data/database/delete_state_dao.dart';
import '../data/database/production_database.dart';
import '../data/database/read_sync_store.dart';
import '../data/database/sync_health_dao.dart';
import '../data/database/sync_health_repository.dart';
import '../data/database/sync_settings_repository.dart';
import '../data/database/task_lists_repository.dart';
import '../data/database/tasks_repository.dart';
import '../data/preferences/device_preferences.dart';
import '../data/preferences/preferences_repository.dart';
import '../data/preferences/relational_preferences.dart';
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

abstract interface class AxiotaskRuntime {
  TasksViewModel get viewModel;

  Stream<Object> get fatalStorageFailures;

  Future<void> start();

  Future<void> close();
}

final class TasksFeatureRuntime implements AxiotaskRuntime {
  const TasksFeatureRuntime._({
    required this.viewModel,
    required this.database,
    required this.coordinator,
    required this.transport,
    required this.devicePreferences,
    required this.storageFailures,
  });

  @override
  final TasksViewModel viewModel;
  final AppDatabase database;
  final SyncCoordinator? coordinator;
  final ReadSliceTransport? transport;
  final DevicePreferencesAdapter? devicePreferences;
  final StreamController<Object> storageFailures;

  @override
  Stream<Object> get fatalStorageFailures => storageFailures.stream;

  static Future<TasksFeatureRuntime> open(
    AppComposition composition, {
    AppDatabase? injectedDatabase,
    LifecyclePort? lifecycle,
    ConnectivityPort? connectivity,
  }) async {
    final database =
        injectedDatabase ??
        await openProductionDatabase(composition.boundary.storage.databaseName);
    ReadSliceTransport? transport;
    DevicePreferencesAdapter? devicePreferences;
    final storageFailures = StreamController<Object>.broadcast();
    try {
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
          devicePreferences: null,
          storageFailures: storageFailures,
        );
      }

      final accountId = AccountId(accounts.first.id);
      final subject = AccountSubject(accounts.first.googleSubject);
      await DeleteStateDao(database).cleanupExpiredTaskDeletes(
        accountId: accountId,
        now: composition.clock.now().toUtc(),
      );
      final openedTransport = await composition.createReadTransport(subject);
      transport = openedTransport;
      final syncStore = DatabaseReadSyncStore(database);
      final coordinator = SyncCoordinator(
        accountId: accountId,
        authorization: openedTransport.authorization,
        clock: composition.clock,
        scheduler: composition.scheduler,
        random: composition.randomness,
        settings: DatabaseSyncSettingsRepository(database),
        retryStore: syncStore,
        reauthorizationStore: syncStore,
        taskDeleteEligibility: _DatabaseTaskDeleteEligibilityStore(database),
        lifecycle: lifecycle,
        connectivity: connectivity,
        run: (request) async {
          try {
            return await SyncEngine(
              store: syncStore,
              googleTasks: openedTransport.googleTasks,
              authorization: openedTransport.authorization,
              clock: composition.clock,
              scheduler: composition.scheduler,
              random: composition.randomness,
              retryObserver: request.retryObserver,
              control: request.control,
              diagnostics: composition.diagnostics,
            ).run(
              SyncRunRequest(
                accountId: accountId,
                deadline: request.deadline,
                triggers: request.triggers
                    .map((trigger) => trigger.value)
                    .toSet(),
              ),
            );
          } on Object catch (error) {
            try {
              await database.schemaFingerprint();
            } on Object {
              storageFailures.add(error);
            }
            rethrow;
          }
        },
      );
      final healthRepository = DatabaseSyncHealthRepository(
        dao: SyncHealthDao(database),
        clock: composition.clock,
        runtime: coordinator,
      );
      devicePreferences = DevicePreferencesAdapter(
        backend: SharedPreferencesAsyncBackend(),
        namespace: composition.boundary.storage.preferencesNamespace,
        diagnostics: composition.diagnostics,
      );
      final preferencesRepository = StoredPreferencesRepository(
        relational: DriftRelationalPreferences(database),
        device: devicePreferences,
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
          preferencesRepository: preferencesRepository,
          clock: composition.clock,
          localEditCommitted: coordinator.localEditCommitted,
          taskDeleteCommitted: coordinator.taskDeleteCommitted,
          refreshRequested: coordinator.refresh,
          retryRequested: coordinator.retry,
          reauthorizeRequested: coordinator.reauthorize,
          stopSyncRequested: coordinator.stop,
          resumeSyncRequested: coordinator.resume,
        ),
        database: database,
        coordinator: coordinator,
        transport: openedTransport,
        devicePreferences: devicePreferences,
        storageFailures: storageFailures,
      );
    } on Object {
      await storageFailures.close();
      await transport?.close();
      await devicePreferences?.close();
      await database.close();
      rethrow;
    }
  }

  @override
  Future<void> start() => coordinator?.start() ?? Future<void>.value();

  @override
  Future<void> close() async {
    viewModel.dispose();
    await coordinator?.close();
    await transport?.close();
    await devicePreferences?.close();
    await database.close();
    await storageFailures.close();
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
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream<List<TaskDeleteUndo>>.empty();

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) =>
      Future.value(const Outcome<TaskId>.failure(_noTaskAccountFailure));

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) =>
      Future.value(const Outcome<void>.failure(_noTaskAccountFailure));

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command) =>
      Future.value(
        const Outcome<TaskDeleteReceipt>.failure(_noTaskAccountFailure),
      );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      Future.value(const Outcome<void>.failure(_noTaskAccountFailure));
}

final class _DatabaseTaskDeleteEligibilityStore
    implements TaskDeleteEligibilityStore {
  _DatabaseTaskDeleteEligibilityStore(AppDatabase database)
    : _deletes = DeleteStateDao(database);

  final DeleteStateDao _deletes;

  @override
  Future<int> cleanupExpiredTaskDeletes({
    required AccountId accountId,
    required DateTime now,
  }) => _deletes.cleanupExpiredTaskDeletes(accountId: accountId, now: now);

  @override
  Future<DateTime?> nextTaskDeleteExpiry(AccountId accountId) =>
      _deletes.nextTaskDeleteExpiry(accountId);
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
