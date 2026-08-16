import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/clock.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../domain/commands/task_list_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/task_lists_repository.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'delete_state_dao.dart';
import 'desired_state_dao.dart';

final class DatabaseTaskListsRepository implements TaskListsRepository {
  DatabaseTaskListsRepository({
    required AppDatabase database,
    required this.clock,
    this.transactionControl,
  }) : _database = database,
       _cache = CacheDao(database),
       _desired = DesiredStateDao(database),
       _deletes = DeleteStateDao(database);

  final AppDatabase _database;
  final CacheDao _cache;
  final DesiredStateDao _desired;
  final DeleteStateDao _deletes;
  final Clock clock;
  final DesiredStateTransactionControl? transactionControl;

  @override
  Future<Outcome<TaskListId>> createTaskList(
    CreateTaskListCommand command,
  ) async {
    final validation = validateTaskListCommand(command);
    if (validation != null) return Outcome<TaskListId>.failure(validation);
    try {
      final id = await _database.transaction(() async {
        await _requireAccount(command.accountId);
        final taskListId = await _cache.putTaskList(
          accountId: command.accountId,
          remoteId: null,
          title: command.title,
        );
        await _reach(DesiredStateTransactionBoundary.afterProjectionWrite);
        await _desired.writeTaskListPresent(
          accountId: command.accountId,
          taskListId: taskListId,
          title: command.title,
          modifiedAt: clock.now(),
        );
        await _reach(DesiredStateTransactionBoundary.afterDesiredStateWrite);
        await _reach(DesiredStateTransactionBoundary.beforeLocalCommit);
        return taskListId;
      });
      return Outcome<TaskListId>.success(id);
    } on _TaskListCommandException catch (error) {
      return Outcome<TaskListId>.failure(error.failure);
    } on DesiredStatePersistenceException {
      return const Outcome<TaskListId>.failure(_persistenceFailure);
    } on SqliteException {
      return const Outcome<TaskListId>.failure(_persistenceFailure);
    }
  }

  @override
  Future<Outcome<void>> renameTaskList(RenameTaskListCommand command) async {
    final validation = validateTaskListCommand(command);
    if (validation != null) return Outcome<void>.failure(validation);
    try {
      await _database.transaction(() async {
        await _requireAccount(command.accountId);
        final row =
            await (_database.select(_database.taskListCacheRows)..where(
                  (row) =>
                      row.accountId.equals(command.accountId.value) &
                      row.id.equals(command.taskListId.value) &
                      row.projection.equals(CacheProjection.supported.name),
                ))
                .getSingleOrNull();
        if (row == null) {
          throw const _TaskListCommandException(_taskListNotFoundFailure);
        }
        if (row.remoteId == null &&
            await _desired.readTaskList(
                  command.accountId,
                  command.taskListId,
                ) ==
                null) {
          throw const _TaskListCommandException(_unsynchronizableListFailure);
        }
        await (_database.update(_database.taskListCacheRows)..where(
              (row) =>
                  row.accountId.equals(command.accountId.value) &
                  row.id.equals(command.taskListId.value),
            ))
            .write(TaskListCacheRowsCompanion(title: Value(command.title)));
        await _reach(DesiredStateTransactionBoundary.afterProjectionWrite);
        await _desired.writeTaskListPresent(
          accountId: command.accountId,
          taskListId: command.taskListId,
          title: command.title,
          modifiedAt: clock.now(),
        );
        await _reach(DesiredStateTransactionBoundary.afterDesiredStateWrite);
        await _reach(DesiredStateTransactionBoundary.beforeLocalCommit);
      });
      return const Outcome<void>.success(null);
    } on _TaskListCommandException catch (error) {
      return Outcome<void>.failure(error.failure);
    } on DesiredStatePersistenceException {
      return const Outcome<void>.failure(_persistenceFailure);
    } on SqliteException {
      return const Outcome<void>.failure(_persistenceFailure);
    }
  }

  @override
  Future<Outcome<void>> deleteTaskList(DeleteTaskListCommand command) async {
    try {
      await _deletes.createTaskListDelete(
        accountId: command.accountId,
        taskListId: command.taskListId,
        acknowledgedAt: clock.now(),
      );
      return const Outcome<void>.success(null);
    } on DeleteStateException catch (error) {
      return Outcome<void>.failure(
        error.code == 'task_list_not_found'
            ? _taskListNotFoundFailure
            : _persistenceFailure,
      );
    } on SqliteException {
      return const Outcome<void>.failure(_persistenceFailure);
    }
  }

  Future<void> _requireAccount(AccountId accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
    if (account == null) {
      throw const _TaskListCommandException(_accountNotFoundFailure);
    }
  }

  Future<void> _reach(DesiredStateTransactionBoundary boundary) async {
    await transactionControl?.call(boundary);
  }
}

final class _TaskListCommandException implements Exception {
  const _TaskListCommandException(this.failure);

  final Failure failure;
}

const Failure _accountNotFoundFailure = Failure(
  code: 'task_list.account_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task list was not saved.',
  safeSummary: 'The selected account partition does not exist.',
);

const Failure _taskListNotFoundFailure = Failure(
  code: 'task_list.not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task list was not renamed.',
  safeSummary: 'The selected task list is not in the account partition.',
);

const Failure _unsynchronizableListFailure = Failure(
  code: 'task_list.unsynchronizable_projection',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task list was not renamed.',
  safeSummary: 'The provisional task list has no durable create intent.',
);

const Failure _persistenceFailure = Failure(
  code: 'list.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task list was not saved.',
  safeSummary: 'The list transaction did not commit.',
);
