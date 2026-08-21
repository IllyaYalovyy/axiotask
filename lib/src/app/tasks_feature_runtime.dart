import 'dart:async';

import '../core/diagnostics/diagnostics.dart';
import '../core/failure.dart';
import '../core/outcome.dart';
import '../data/auth/authorization.dart';
import '../data/connectivity/connectivity.dart';
import '../data/database/account_backup_repository.dart';
import '../data/database/account_partition_reset_store.dart';
import '../data/database/app_database.dart';
import '../data/database/delete_state_dao.dart';
import '../data/database/production_database.dart';
import '../data/database/read_sync_store.dart';
import '../data/database/sync_health_dao.dart';
import '../data/database/sync_health_repository.dart';
import '../data/database/sync_settings_repository.dart';
import '../data/database/task_lists_repository.dart';
import '../data/database/tasks_repository.dart';
import '../data/links/url_launcher_adapter.dart';
import '../data/preferences/device_preferences.dart';
import '../data/preferences/preferences_repository.dart';
import '../data/preferences/relational_preferences.dart';
import '../domain/commands/task_commands.dart';
import '../domain/model/tasks.dart';
import '../domain/recovery/local_data_recovery.dart';
import '../domain/repository/account_backup_repository.dart';
import '../domain/repository/preferences_repository.dart';
import '../domain/repository/tasks_repository.dart';
import '../features/tasks/tasks_view_model.dart';
import '../sync/coordinator/sync_coordinator.dart';
import '../sync/engine.dart';
import '../sync/health/sync_health.dart';
import '../sync/health/sync_health_repository.dart';
import '../sync/run.dart';
import 'composition/app_composition.dart';
import 'composition/local_data_reset_isolation.dart';
import 'lifecycle.dart';

abstract interface class AxiotaskRuntime {
  TasksViewModel get viewModel;

  AccountBackupRepository? get accountBackupRepository => null;

  AccountBackupRestoreRepository? get accountBackupRestoreRepository => null;

  SyncHealthRepository? get syncHealthRepository => null;

  LocalDataRecoveryService? get localDataRecoveryService => null;

  PreferencesRepository? get preferencesRepository => null;

  Stream<Object> get fatalStorageFailures;

  /// Requests a complete composition reopen after a durable boundary changes.
  ///
  /// First-account authorization uses this after the verified Google subject
  /// is committed to SQLite. Existing runtimes normally emit nothing.
  Future<void>? get reloadRequested => null;

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
    required this.reloadRequest,
    required this._closeFirstAccountHealth,
    required this.accountBackupRepository,
    required this.accountBackupRestoreRepository,
    required this.syncHealthRepository,
    required this.localDataRecoveryService,
    required this.preferencesRepository,
  });

  @override
  final TasksViewModel viewModel;
  final AppDatabase database;
  final SyncCoordinator? coordinator;
  final ReadSliceTransport? transport;
  final DevicePreferencesAdapter? devicePreferences;
  final StreamController<Object> storageFailures;
  final Completer<void>? reloadRequest;
  final Future<void> Function()? _closeFirstAccountHealth;

  @override
  final AccountBackupRepository? accountBackupRepository;

  @override
  final AccountBackupRestoreRepository? accountBackupRestoreRepository;

  @override
  final SyncHealthRepository? syncHealthRepository;

  @override
  final LocalDataRecoveryService? localDataRecoveryService;

  @override
  final PreferencesRepository? preferencesRepository;

  @override
  Stream<Object> get fatalStorageFailures => storageFailures.stream;

  @override
  Future<void>? get reloadRequested => reloadRequest?.future;

  static Future<TasksFeatureRuntime> open(
    AppComposition composition, {
    AppDatabase? injectedDatabase,
    DevicePreferencesBackend? injectedDevicePreferencesBackend,
    LifecyclePort? lifecycle,
    ConnectivityPort? connectivity,
  }) async {
    final database =
        injectedDatabase ??
        await openProductionDatabase(composition.boundary.storage.databaseName);
    ReadSliceTransport? transport;
    DevicePreferencesAdapter? devicePreferences;
    final storageFailures = StreamController<Object>.broadcast();
    Completer<void>? reloadRequest;
    try {
      devicePreferences = DevicePreferencesAdapter(
        backend:
            injectedDevicePreferencesBackend ?? SharedPreferencesAsyncBackend(),
        namespace: composition.boundary.storage.preferencesNamespace,
        diagnostics: composition.diagnostics,
      );
      final preferencesRepository = StoredPreferencesRepository(
        relational: DriftRelationalPreferences(database),
        device: devicePreferences,
      );
      var accounts = await database.allAccounts();
      final configuredSubject = composition.configuredAccountSubject;
      if (accounts.isEmpty && configuredSubject != null) {
        await database.createAccount(configuredSubject.value);
        accounts = await database.allAccounts();
      }
      if (accounts.isEmpty) {
        reloadRequest = Completer<void>();
        final openedTransport = await composition.createReadTransport(null);
        transport = openedTransport;
        final healthRepository = _FirstAccountHealthRepository(
          composition.clock.now(),
        );
        return TasksFeatureRuntime._(
          viewModel: TasksViewModel(
            accountId: const AccountId(1),
            tasksRepository: const _EmptyTasksRepository(),
            syncHealthRepository: healthRepository,
            connectRequested: () => _connectFirstAccount(
              composition: composition,
              database: database,
              transport: openedTransport,
              health: healthRepository,
              reloadRequest: reloadRequest!,
              storageFailures: storageFailures,
            ),
            diagnostics: composition.diagnostics,
          ),
          database: database,
          coordinator: null,
          transport: openedTransport,
          devicePreferences: devicePreferences,
          storageFailures: storageFailures,
          reloadRequest: reloadRequest,
          closeFirstAccountHealth: healthRepository.close,
          accountBackupRepository: null,
          accountBackupRestoreRepository: null,
          syncHealthRepository: healthRepository,
          localDataRecoveryService: null,
          preferencesRepository: preferencesRepository,
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
        diagnostics: composition.diagnostics,
      );
      final healthRepository = DatabaseSyncHealthRepository(
        dao: SyncHealthDao(database),
        clock: composition.clock,
        runtime: coordinator,
      );
      final backupRepository = DatabaseAccountBackupRepository(
        database,
        clock: composition.clock,
      );
      final partitionResetStore = DatabaseAccountPartitionResetStore(database);
      final resetStore =
          composition.boundary.profile == CompositionProfile.release
          ? partitionResetStore
          : DevelopmentIsolatedLocalDataResetStore(
              delegate: partitionResetStore,
              boundary: composition.boundary,
              explicitDatabaseName: composition.boundary.storage.databaseName,
              accountGuard: composition.accountGuard,
              subject: subject,
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
          diagnostics: composition.diagnostics,
          externalLinkLauncher: const UrlLauncherAdapter(),
        ),
        database: database,
        coordinator: coordinator,
        transport: openedTransport,
        devicePreferences: devicePreferences,
        storageFailures: storageFailures,
        reloadRequest: null,
        closeFirstAccountHealth: null,
        accountBackupRepository: backupRepository,
        accountBackupRestoreRepository: backupRepository,
        syncHealthRepository: healthRepository,
        localDataRecoveryService: LocalDataRecoveryService(
          store: resetStore,
          synchronization: coordinator,
        ),
        preferencesRepository: preferencesRepository,
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
    await _closeFirstAccountHealth?.call();
    await database.close();
    await storageFailures.close();
  }
}

Future<Outcome<void>> _connectFirstAccount({
  required AppComposition composition,
  required AppDatabase database,
  required ReadSliceTransport transport,
  required _FirstAccountHealthRepository health,
  required Completer<void> reloadRequest,
  required StreamController<Object> storageFailures,
}) async {
  health.checkingAuthorization(composition.clock.now());
  final Outcome<AccountSubject> authorization;
  try {
    authorization = await transport.authorization.requestTasksAuthorization();
  } on Object {
    composition.diagnostics.record(
      const DiagnosticEvent(
        subsystem: DiagnosticSubsystem.authorization,
        kind: DiagnosticEventKind.failure,
        code: 'auth.first_connection_failed_unexpectedly',
        operation: 'authorize_first_account',
      ),
    );
    health.failed(_unexpectedAuthorizationFailure, composition.clock.now());
    return const Outcome<void>.failure(_unexpectedAuthorizationFailure);
  }
  final AccountSubject subject;
  switch (authorization) {
    case Failed<AccountSubject>(:final failure):
      health.failed(failure, composition.clock.now());
      return Outcome<void>.failure(failure);
    case Success<AccountSubject>(:final value):
      subject = value;
  }

  final guarded = composition.accountGuard.verify(subject);
  if (guarded case Failed<void>(:final failure)) {
    health.failed(failure, composition.clock.now());
    return Outcome<void>.failure(failure);
  }

  try {
    final provisioned = await database.transaction<Outcome<void>>(() async {
      var accounts = await database.allAccounts();
      if (accounts.isEmpty) {
        await database.createAccount(subject.value);
        accounts = await database.allAccounts();
      }
      if (accounts.length != 1 ||
          accounts.single.googleSubject != subject.value) {
        return const Outcome<void>.failure(_accountSelectionChangedFailure);
      }
      return const Outcome<void>.success(null);
    });
    if (provisioned case Failed<void>(:final failure)) {
      health.failed(failure, composition.clock.now());
      return provisioned;
    }
  } on Object catch (error) {
    try {
      await database.schemaFingerprint();
    } on Object {
      if (!storageFailures.isClosed) storageFailures.add(error);
    }
    composition.diagnostics.record(
      const DiagnosticEvent(
        subsystem: DiagnosticSubsystem.storage,
        kind: DiagnosticEventKind.failure,
        code: 'account.first_partition_create_failed',
        operation: 'create_account_partition',
      ),
    );
    health.failed(_accountCreationFailure, composition.clock.now());
    return const Outcome<void>.failure(_accountCreationFailure);
  }

  health.verificationPending(composition.clock.now());
  if (!reloadRequest.isCompleted) reloadRequest.complete();
  return const Outcome<void>.success(null);
}

final class _FirstAccountHealthRepository implements SyncHealthRepository {
  _FirstAccountHealthRepository(DateTime now) : _current = _inactive(now);

  final StreamController<SyncHealth> _changes =
      StreamController<SyncHealth>.broadcast(sync: true);
  SyncHealth _current;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) async* {
    yield _current;
    yield* _changes.stream;
  }

  void checkingAuthorization(DateTime now) {
    _publish(
      SyncHealth(
        outcome: SyncHealthOutcome.pending,
        pendingReason: SyncPendingReason.checkingAuthorization,
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: null,
        evaluatedAt: now,
      ),
    );
  }

  void verificationPending(DateTime now) {
    _publish(
      SyncHealth(
        outcome: SyncHealthOutcome.pending,
        pendingReason: SyncPendingReason.verifying,
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: null,
        evaluatedAt: now,
      ),
    );
  }

  void failed(Failure failure, DateTime now) {
    final isAuthorizationFailure =
        failure.category == FailureCategory.authorization;
    if (isAuthorizationFailure) {
      _publish(
        SyncHealth(
          outcome: SyncHealthOutcome.inactive,
          inactiveReason: SyncInactiveReason.noAuthorization,
          action: SyncHealthAction.connect,
          counts: const SyncWorkCounts(),
          lastSuccessfulSyncAt: null,
          evaluatedAt: now,
          diagnosticCode: failure.code,
        ),
      );
      return;
    }
    final reason = switch (failure.category) {
      FailureCategory.network => SyncFailureReason.noConnection,
      FailureCategory.remote ||
      FailureCategory.rateLimit => SyncFailureReason.remoteFailure,
      _ => SyncFailureReason.applicationFailure,
    };
    _publish(
      SyncHealth(
        outcome: SyncHealthOutcome.failed,
        failureReason: reason,
        action: SyncHealthAction.connect,
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: null,
        evaluatedAt: now,
        diagnosticCode: failure.code,
      ),
    );
  }

  void _publish(SyncHealth value) {
    _current = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  Future<void> close() => _changes.close();

  static SyncHealth _inactive(DateTime now) => SyncHealth(
    outcome: SyncHealthOutcome.inactive,
    inactiveReason: SyncInactiveReason.noAuthorization,
    action: SyncHealthAction.connect,
    counts: const SyncWorkCounts(),
    lastSuccessfulSyncAt: null,
    evaluatedAt: now,
  );
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
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream<List<TaskDueChangeUndo>>.empty();

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
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command) =>
      Future.value(
        const Outcome<TaskDueChangeReceipt>.failure(_noTaskAccountFailure),
      );

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) =>
      Future.value(const Outcome<void>.failure(_noTaskAccountFailure));

  @override
  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command) =>
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

const Failure _accountSelectionChangedFailure = Failure(
  code: 'account.first_partition_conflict',
  category: FailureCategory.authorization,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks data was not opened for a different account.',
  action: FailureAction.reviewConfiguration,
  safeSummary: 'The configured account changed while connection was opening.',
);

const Failure _accountCreationFailure = Failure(
  code: 'account.first_partition_create_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The verified Google account was not saved locally.',
  action: FailureAction.retry,
  safeSummary: 'The local account partition could not be created safely.',
);

const Failure _unexpectedAuthorizationFailure = Failure(
  code: 'auth.first_connection_failed_unexpectedly',
  category: FailureCategory.internal,
  operation: FailureOperation.authorize,
  retry: RetryClassification.unknown,
  impact: 'Google Tasks was not connected.',
  action: FailureAction.retry,
  safeSummary:
      'Google authorization failed unexpectedly. Open diagnostics '
      'for details and retry.',
);
