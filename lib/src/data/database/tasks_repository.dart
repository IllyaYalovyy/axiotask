import 'dart:async';

import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/clock.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/tasks_repository.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'desired_state_dao.dart';

final class DatabaseTasksRepository implements TasksRepository {
  DatabaseTasksRepository(
    this._database, {
    Clock? clock,
    this.transactionControl,
  }) : clock = clock ?? SystemClock(),
       _cache = CacheDao(_database),
       _desired = DesiredStateDao(_database);

  final AppDatabase _database;
  final CacheDao _cache;
  final DesiredStateDao _desired;
  final Clock clock;
  final DesiredStateTransactionControl? transactionControl;

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async {
    final validation = validateTaskCommand(command);
    if (validation != null) return Outcome<TaskId>.failure(validation);
    try {
      final id = await _database.transaction(() async {
        await _requireAccount(command.accountId);
        await _requireTaskList(command.accountId, command.taskListId);
        if (command.parentTaskId case final parentId?) {
          await _requireParent(command.accountId, command.taskListId, parentId);
        }
        final taskId = await _cache.putTask(
          accountId: command.accountId,
          taskListId: command.taskListId,
          parentTaskId: command.parentTaskId,
          remoteId: null,
          title: command.title,
          notes: command.notes,
          status: command.status,
          due: command.due,
          position: 'local-pending',
        );
        await _reach(DesiredStateTransactionBoundary.afterProjectionWrite);
        await _desired.writeTaskPresent(
          accountId: command.accountId,
          taskId: taskId,
          taskListId: command.taskListId,
          parentTaskId: command.parentTaskId,
          title: command.title,
          notes: command.notes,
          status: command.status,
          due: command.due,
          modifiedAt: clock.now(),
        );
        await _reach(DesiredStateTransactionBoundary.afterDesiredStateWrite);
        await _reach(DesiredStateTransactionBoundary.beforeLocalCommit);
        return taskId;
      });
      return Outcome<TaskId>.success(id);
    } on _TaskCommandException catch (error) {
      return Outcome<TaskId>.failure(error.failure);
    } on DesiredStatePersistenceException {
      return const Outcome<TaskId>.failure(_persistenceFailure);
    } on CacheInvariantException {
      return const Outcome<TaskId>.failure(_persistenceFailure);
    } on SqliteException {
      return const Outcome<TaskId>.failure(_persistenceFailure);
    }
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async {
    final validation = validateTaskCommand(command);
    if (validation != null) return Outcome<void>.failure(validation);
    try {
      await _database.transaction(() async {
        await _requireAccount(command.accountId);
        final row =
            await (_database.select(_database.taskCacheRows)..where(
                  (row) =>
                      row.accountId.equals(command.accountId.value) &
                      row.id.equals(command.taskId.value) &
                      row.projection.equals(CacheProjection.supported.name),
                ))
                .getSingleOrNull();
        if (row == null) {
          throw const _TaskCommandException(_taskNotFoundFailure);
        }
        if (row.remoteId == null &&
            !_isUnresolved(
              (await _desired.readTask(
                command.accountId,
                command.taskId,
              ))?.state,
            )) {
          throw const _TaskCommandException(_unsynchronizableTaskFailure);
        }
        final title = switch (command) {
          SetTaskTitleCommand(:final title) => title,
          UpdateTaskContentCommand(:final title) => title,
          _ => row.title,
        };
        final notes = switch (command) {
          SetTaskNotesCommand(:final notes) => notes,
          UpdateTaskContentCommand(:final notes) => notes,
          _ => row.notes,
        };
        final status = switch (command) {
          SetTaskCompletionCommand(:final status) => status,
          UpdateTaskContentCommand(:final status) => status,
          _ => _taskStatus(row.status),
        };
        final due = switch (command) {
          SetTaskDueCommand(:final due) => due,
          UpdateTaskContentCommand(:final due) => due,
          _ => _taskDate(row.dueEpochDay),
        };
        await (_database.update(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(command.accountId.value) &
                  row.id.equals(command.taskId.value),
            ))
            .write(
              TaskCacheRowsCompanion(
                title: Value<String>(title),
                notes: Value<String?>(notes),
                status: Value<String>(_statusValue(status)),
                dueEpochDay: Value<int?>(_epochDay(due)),
              ),
            );
        await _reach(DesiredStateTransactionBoundary.afterProjectionWrite);
        await _desired.writeTaskPresent(
          accountId: command.accountId,
          taskId: command.taskId,
          taskListId: TaskListId(row.taskListId),
          parentTaskId: row.parentTaskId == null
              ? null
              : TaskId(row.parentTaskId!),
          title: title,
          notes: notes,
          status: status,
          due: due,
          modifiedAt: clock.now(),
        );
        await _reach(DesiredStateTransactionBoundary.afterDesiredStateWrite);
        await _reach(DesiredStateTransactionBoundary.beforeLocalCommit);
      });
      return const Outcome<void>.success(null);
    } on _TaskCommandException catch (error) {
      return Outcome<void>.failure(error.failure);
    } on DesiredStatePersistenceException {
      return const Outcome<void>.failure(_persistenceFailure);
    } on SqliteException {
      return const Outcome<void>.failure(_persistenceFailure);
    }
  }

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) {
    final listId = query.taskListId?.value;
    final result = _database.customSelect(
      '''
      SELECT
        a.id AS account_id,
        l.id AS list_id,
        l.remote_id AS list_remote_id,
        l.title AS list_title,
        t.id AS task_id,
        t.remote_id AS task_remote_id,
        t.task_list_id AS task_list_id,
        t.parent_task_id AS parent_task_id,
        t.title AS task_title,
        t.notes AS task_notes,
        t.status AS task_status,
        t.due_epoch_day AS task_due_epoch_day,
        CASE
          WHEN NOT EXISTS (
            SELECT 1 FROM scope_completeness sc
            WHERE sc.account_id = a.id AND sc.scope_kind = 'task_lists'
          ) THEN 0
          WHEN EXISTS (
            SELECT 1 FROM scope_completeness sc
            WHERE sc.account_id = a.id
              AND sc.scope_kind = 'task_lists'
              AND sc.is_complete = 0
          ) THEN 1
          WHEN EXISTS (
            SELECT 1 FROM task_lists required_list
            LEFT JOIN task_list_remote_bases selected_list
              ON selected_list.account_id = required_list.account_id
             AND selected_list.task_list_id = required_list.id
            WHERE required_list.account_id = a.id
              AND required_list.projection = 'supported'
              AND required_list.remote_id IS NOT NULL
              AND (
                selected_list.task_list_id IS NULL OR (
                  selected_list.deleted = 0
                  AND selected_list.observed_publication_id = (
                    SELECT list_scope.publication_id
                    FROM scope_completeness list_scope
                    WHERE list_scope.account_id = a.id
                      AND list_scope.scope_kind = 'task_lists'
                    LIMIT 1
                  )
                )
              )
              AND (?2 = 0 OR required_list.id = ?2)
              AND NOT EXISTS (
                SELECT 1 FROM scope_completeness task_scope
                WHERE task_scope.account_id = a.id
                  AND task_scope.scope_kind = 'tasks'
                  AND task_scope.task_list_id = required_list.id
                  AND task_scope.is_complete = 1
                  AND task_scope.publication_id = (
                    SELECT list_scope.publication_id
                    FROM scope_completeness list_scope
                    WHERE list_scope.account_id = a.id
                      AND list_scope.scope_kind = 'task_lists'
                    LIMIT 1
                  )
              )
          ) THEN 1
          ELSE 2
        END AS cache_completeness
      FROM accounts a
      LEFT JOIN task_lists l
        ON l.account_id = a.id
       AND l.projection = 'supported'
       AND (
         l.remote_id IS NOT NULL OR EXISTS (
           SELECT 1 FROM desired_states local_list_intent
           WHERE local_list_intent.account_id = l.account_id
             AND local_list_intent.resource_type = 'task_list'
             AND local_list_intent.target_task_list_id = l.id
             AND local_list_intent.desired_lifecycle = 'present'
             AND local_list_intent.state IN (
               'pending', 'in_flight', 'uncertain', 'failed'
             )
         )
       )
       AND (?2 = 0 OR l.id = ?2)
      LEFT JOIN tasks t
        ON t.account_id = a.id
       AND t.task_list_id = l.id
       AND t.projection = 'supported'
       AND (
         t.remote_id IS NOT NULL OR EXISTS (
           SELECT 1 FROM desired_states local_task_intent
           WHERE local_task_intent.account_id = t.account_id
             AND local_task_intent.resource_type = 'task'
             AND local_task_intent.target_task_id = t.id
             AND local_task_intent.desired_lifecycle = 'present'
             AND local_task_intent.state IN (
               'pending', 'in_flight', 'uncertain', 'failed'
             )
         )
       )
       AND (
         t.parent_task_id IS NULL OR EXISTS (
           SELECT 1 FROM tasks supported_parent
           WHERE supported_parent.account_id = t.account_id
             AND supported_parent.task_list_id = t.task_list_id
             AND supported_parent.id = t.parent_task_id
             AND supported_parent.parent_task_id IS NULL
             AND supported_parent.projection = 'supported'
             AND (
               supported_parent.remote_id IS NOT NULL OR EXISTS (
                 SELECT 1 FROM desired_states parent_intent
                 WHERE parent_intent.account_id = supported_parent.account_id
                   AND parent_intent.resource_type = 'task'
                   AND parent_intent.target_task_id = supported_parent.id
                   AND parent_intent.desired_lifecycle = 'present'
                   AND parent_intent.state IN (
                     'pending', 'in_flight', 'uncertain', 'failed'
                   )
               )
             )
         )
       )
      WHERE a.id = ?1
      ORDER BY l.id, t.position, t.id
      ''',
      variables: <Variable<Object>>[
        Variable<int>(query.accountId.value),
        Variable<int>(listId ?? 0),
      ],
      readsFrom: <ResultSetImplementation<Table, Object?>>{
        _database.accounts,
        _database.taskListCacheRows,
        _database.taskCacheRows,
        _database.scopeCompletenessRows,
        _database.desiredStateRows,
      },
    );
    return result.watch().map((rows) => _mapSnapshot(query.accountId, rows));
  }

  Future<void> _requireAccount(AccountId accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
    if (account == null) {
      throw const _TaskCommandException(_accountNotFoundFailure);
    }
  }

  Future<void> _requireTaskList(
    AccountId accountId,
    TaskListId taskListId,
  ) async {
    final row =
        await (_database.select(_database.taskListCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(taskListId.value) &
                  row.projection.equals(CacheProjection.supported.name),
            ))
            .getSingleOrNull();
    if (row == null) {
      throw const _TaskCommandException(_taskListNotFoundFailure);
    }
    if (row.remoteId == null &&
        !_isUnresolved(
          (await _desired.readTaskList(accountId, taskListId))?.state,
        )) {
      throw const _TaskCommandException(_unsynchronizableListFailure);
    }
  }

  Future<void> _requireParent(
    AccountId accountId,
    TaskListId taskListId,
    TaskId parentTaskId,
  ) async {
    final parent =
        await (_database.select(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.taskListId.equals(taskListId.value) &
                  row.id.equals(parentTaskId.value) &
                  row.projection.equals(CacheProjection.supported.name),
            ))
            .getSingleOrNull();
    if (parent == null) {
      throw const _TaskCommandException(_parentNotFoundFailure);
    }
    if (parent.parentTaskId != null) {
      throw const _TaskCommandException(_unsupportedDepthFailure);
    }
    if (parent.remoteId == null &&
        !_isUnresolved(
          (await _desired.readTask(accountId, parentTaskId))?.state,
        )) {
      throw const _TaskCommandException(_unsynchronizableParentFailure);
    }
  }

  Future<void> _reach(DesiredStateTransactionBoundary boundary) async {
    await transactionControl?.call(boundary);
  }
}

CachedTasksSnapshot _mapSnapshot(AccountId accountId, List<QueryRow> rows) {
  final taskLists = <TaskListId, CachedTaskList>{};
  final tasks = <CachedTask>[];
  CacheCompleteness completeness = CacheCompleteness.unobserved;
  for (final row in rows) {
    final rowAccountId = row.read<int>('account_id');
    if (rowAccountId != accountId.value) {
      throw const CacheMappingException('account_partition_mismatch');
    }
    completeness = switch (row.read<int>('cache_completeness')) {
      0 => CacheCompleteness.unobserved,
      1 => CacheCompleteness.incomplete,
      2 => CacheCompleteness.complete,
      _ => throw const CacheMappingException('unknown_completeness'),
    };
    final listIdValue = row.readNullable<int>('list_id');
    if (listIdValue == null) continue;
    final listRemoteId = row.readNullable<String>('list_remote_id');
    final listId = TaskListId(listIdValue);
    taskLists.putIfAbsent(
      listId,
      () => CachedTaskList(
        id: listId,
        accountId: accountId,
        remoteId: listRemoteId == null ? null : TaskListRemoteId(listRemoteId),
        title: row.read<String>('list_title'),
      ),
    );
    final taskIdValue = row.readNullable<int>('task_id');
    if (taskIdValue == null) continue;
    final taskRemoteId = row.readNullable<String>('task_remote_id');
    final taskListId = row.read<int>('task_list_id');
    if (taskListId != listId.value) {
      throw const CacheMappingException('task_list_partition_mismatch');
    }
    tasks.add(
      CachedTask(
        id: TaskId(taskIdValue),
        accountId: accountId,
        taskListId: listId,
        parentTaskId: switch (row.readNullable<int>('parent_task_id')) {
          final value? => TaskId(value),
          null => null,
        },
        remoteId: taskRemoteId == null ? null : TaskRemoteId(taskRemoteId),
        title: row.read<String>('task_title'),
        notes: row.readNullable<String>('task_notes'),
        status: switch (row.read<String>('task_status')) {
          'needs_action' => TaskStatus.needsAction,
          'completed' => TaskStatus.completed,
          _ => throw const CacheMappingException('unknown_task_status'),
        },
        due: _mapEpochDay(row.readNullable<int>('task_due_epoch_day')),
      ),
    );
  }
  return CachedTasksSnapshot(
    accountId: accountId,
    taskLists: taskLists.values.toList(growable: false),
    tasks: tasks,
    completeness: completeness,
  );
}

final class CacheMappingException implements Exception {
  const CacheMappingException(this.code);

  final String code;

  @override
  String toString() => 'CacheMappingException($code)';
}

TaskDate? _mapEpochDay(int? epochDay) {
  if (epochDay == null) return null;
  final date = DateTime.utc(1970).add(Duration(days: epochDay));
  return TaskDate(date.year, date.month, date.day);
}

final class _TaskCommandException implements Exception {
  const _TaskCommandException(this.failure);

  final Failure failure;
}

bool _isUnresolved(DesiredStateLifecycle? state) => switch (state) {
  DesiredStateLifecycle.pending ||
  DesiredStateLifecycle.inFlight ||
  DesiredStateLifecycle.uncertain ||
  DesiredStateLifecycle.failed => true,
  _ => false,
};

TaskStatus _taskStatus(String value) => switch (value) {
  'needs_action' => TaskStatus.needsAction,
  'completed' => TaskStatus.completed,
  _ => throw const DesiredStateInvariantException('unknown_task_status'),
};

String _statusValue(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'needs_action',
  TaskStatus.completed => 'completed',
};

int? _epochDay(TaskDate? value) => value == null
    ? null
    : DateTime.utc(
        value.year,
        value.month,
        value.day,
      ).difference(DateTime.utc(1970)).inDays;

TaskDate? _taskDate(int? epochDay) {
  if (epochDay == null) return null;
  final date = DateTime.utc(1970).add(Duration(days: epochDay));
  return TaskDate(date.year, date.month, date.day);
}

const Failure _accountNotFoundFailure = Failure(
  code: 'task.account_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The selected account partition does not exist.',
);

const Failure _taskListNotFoundFailure = Failure(
  code: 'task.task_list_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The selected task list is not in the account partition.',
);

const Failure _parentNotFoundFailure = Failure(
  code: 'task.parent_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The selected parent is not in the task list.',
);

const Failure _unsupportedDepthFailure = Failure(
  code: 'task.unsupported_depth',
  category: FailureCategory.unsupportedRemoteState,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'Axiotask supports one subtask level.',
);

const Failure _taskNotFoundFailure = Failure(
  code: 'task.not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The selected task is not in the account partition.',
);

const Failure _unsynchronizableListFailure = Failure(
  code: 'task.unsynchronizable_list',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The provisional list has no durable create intent.',
);

const Failure _unsynchronizableParentFailure = Failure(
  code: 'task.unsynchronizable_parent',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The provisional parent has no durable create intent.',
);

const Failure _unsynchronizableTaskFailure = Failure(
  code: 'task.unsynchronizable_projection',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task was not saved.',
  safeSummary: 'The provisional task has no durable create intent.',
);

const Failure _persistenceFailure = Failure(
  code: 'task.persistence_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task was not saved.',
  safeSummary: 'The task transaction did not commit.',
);
