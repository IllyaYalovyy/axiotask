import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
import '../../domain/repository/tasks_repository.dart';
import 'app_database.dart';

final class DatabaseTasksRepository implements TasksRepository {
  const DatabaseTasksRepository(this._database);

  final AppDatabase _database;

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
       AND l.remote_id IS NOT NULL
       AND (?2 = 0 OR l.id = ?2)
      LEFT JOIN tasks t
        ON t.account_id = a.id
       AND t.task_list_id = l.id
       AND t.projection = 'supported'
       AND t.remote_id IS NOT NULL
       AND (
         t.parent_task_id IS NULL OR EXISTS (
           SELECT 1 FROM tasks supported_parent
           WHERE supported_parent.account_id = t.account_id
             AND supported_parent.task_list_id = t.task_list_id
             AND supported_parent.id = t.parent_task_id
             AND supported_parent.parent_task_id IS NULL
             AND supported_parent.projection = 'supported'
             AND supported_parent.remote_id IS NOT NULL
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
      },
    );
    return result.watch().map((rows) => _mapSnapshot(query.accountId, rows));
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
    final listRemoteId = _requiredRemoteId(
      row.readNullable<String>('list_remote_id'),
      'task_list_remote_id',
    );
    final listId = TaskListId(listIdValue);
    taskLists.putIfAbsent(
      listId,
      () => CachedTaskList(
        id: listId,
        accountId: accountId,
        remoteId: TaskListRemoteId(listRemoteId),
        title: row.read<String>('list_title'),
      ),
    );
    final taskIdValue = row.readNullable<int>('task_id');
    if (taskIdValue == null) continue;
    final taskRemoteId = _requiredRemoteId(
      row.readNullable<String>('task_remote_id'),
      'task_remote_id',
    );
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
        remoteId: TaskRemoteId(taskRemoteId),
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

String _requiredRemoteId(String? value, String field) {
  if (value == null || value.isEmpty) {
    throw CacheMappingException('invalid_$field');
  }
  return value;
}

TaskDate? _mapEpochDay(int? epochDay) {
  if (epochDay == null) return null;
  final date = DateTime.utc(1970).add(Duration(days: epochDay));
  return TaskDate(date.year, date.month, date.day);
}
