import '../data/database/app_database.dart';
import '../data/database/sync_health_dao.dart';
import '../data/database/sync_health_repository.dart';
import '../data/database/tasks_repository.dart';
import '../domain/model/tasks.dart';
import '../domain/repository/tasks_repository.dart';
import '../features/tasks/tasks_view_model.dart';
import '../sync/health/sync_health.dart';
import '../sync/health/sync_health_repository.dart';
import 'composition/app_composition.dart';

final class TasksFeatureRuntime {
  const TasksFeatureRuntime({required this.viewModel, required this.database});

  final TasksViewModel viewModel;
  final AppDatabase database;

  static Future<TasksFeatureRuntime> open(AppComposition composition) async {
    final database = await AppDatabase.openProduction(
      composition.boundary.storage.databaseName,
    );
    final accounts = await database.allAccounts();
    if (accounts.isEmpty) {
      return TasksFeatureRuntime(
        viewModel: TasksViewModel(
          accountId: const AccountId(1),
          tasksRepository: const _EmptyTasksRepository(),
          syncHealthRepository: _NoAuthorizationHealthRepository(
            composition.clock.now(),
          ),
        ),
        database: database,
      );
    }

    final accountId = AccountId(accounts.first.id);
    return TasksFeatureRuntime(
      viewModel: TasksViewModel(
        accountId: accountId,
        tasksRepository: DatabaseTasksRepository(database),
        syncHealthRepository: DatabaseSyncHealthRepository(
          dao: SyncHealthDao(database),
          clock: composition.clock,
          runtime: AuthorizationRuntimeFactsSource(composition.authorization),
        ),
      ),
      database: database,
    );
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
