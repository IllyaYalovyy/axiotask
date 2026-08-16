import 'package:drift/drift.dart';

import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/delete_policy.dart';
import '../../sync/delete_operations.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'desired_state_dao.dart';

final class TaskDeleteTombstoneRecord {
  TaskDeleteTombstoneRecord({
    required this.id,
    required this.accountId,
    required this.rootTaskId,
    required this.desiredStateId,
    required this.deleteGeneration,
    required this.notBefore,
    required this.snapshotAvailable,
    required List<TaskId> snapshotTaskIds,
  }) : snapshotTaskIds = List<TaskId>.unmodifiable(snapshotTaskIds);

  final int id;
  final AccountId accountId;
  final TaskId rootTaskId;
  final int desiredStateId;
  final int deleteGeneration;
  final DateTime notBefore;
  final bool snapshotAvailable;
  final List<TaskId> snapshotTaskIds;
}

enum DeleteResourceType { taskList, task }

final class DeleteCandidate {
  const DeleteCandidate({
    required this.resourceType,
    required this.desiredStateId,
    required this.generation,
    required this.taskListId,
    required this.taskListRemoteId,
    required this.taskId,
    required this.taskRemoteId,
    required this.etag,
    required this.state,
  });

  final DeleteResourceType resourceType;
  final int desiredStateId;
  final int generation;
  final TaskListId taskListId;
  final TaskListRemoteId taskListRemoteId;
  final TaskId? taskId;
  final TaskRemoteId? taskRemoteId;
  final String? etag;
  final DesiredStateLifecycle state;
}

final class DeleteStateDao {
  const DeleteStateDao(this._database);

  final AppDatabase _database;

  Future<TaskDeleteTombstoneRecord> createTaskDelete({
    required AccountId accountId,
    required TaskId rootTaskId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
      final root =
          await (_database.select(_database.taskCacheRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(rootTaskId.value) &
                    row.projection.equals('supported'),
              ))
              .getSingleOrNull();
      if (root == null) {
        throw const DeleteStateException('task_not_found');
      }
      final existingTombstone =
          await (_database.select(_database.taskDeleteTombstoneRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.rootTaskId.equals(rootTaskId.value),
              ))
              .getSingleOrNull();
      if (existingTombstone != null) {
        throw const DeleteStateException('task_already_deleted');
      }

      final subtree =
          await (_database.select(_database.taskCacheRows)
                ..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.projection.equals('supported') &
                      (row.id.equals(rootTaskId.value) |
                          row.parentTaskId.equals(rootTaskId.value)),
                )
                ..orderBy([
                  (row) => OrderingTerm.asc(row.parentTaskId),
                  (row) => OrderingTerm.asc(row.id),
                ]))
              .get();
      if (subtree.isEmpty) {
        throw const DeleteStateException('task_subtree_missing');
      }
      final base =
          await (_database.select(_database.taskRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskId.equals(rootTaskId.value),
              ))
              .getSingleOrNull();
      final existingDesired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.resourceType.equals('task') &
                    row.targetTaskId.equals(rootTaskId.value),
              ))
              .getSingleOrNull();
      final now = acknowledgedAt.toUtc();
      final notBefore = const TaskDeletePolicy().notBefore(now);
      final sequence = await _nextCausalSequence(accountId);
      final int desiredStateId;
      final int generation;
      if (existingDesired == null) {
        generation = 1;
        desiredStateId = await _database
            .into(_database.desiredStateRows)
            .insert(
              DesiredStateRowsCompanion.insert(
                accountId: accountId.value,
                targetKey: 'task:${rootTaskId.value}',
                resourceType: 'task',
                targetTaskId: Value<int>(rootTaskId.value),
                desiredLifecycle: 'deleted',
                desiredTaskListId: Value<int>(root.taskListId),
                lifecycleDirty: const Value<bool>(true),
                generation: generation,
                localCausalSequence: sequence,
                state: 'pending',
                baseRemoteId: Value<String?>(base?.remoteId ?? root.remoteId),
                baseEtag: Value<String?>(base?.etag),
                baseRemoteUpdatedAt: Value<DateTime?>(base?.remoteUpdatedAt),
                baseObservedPublicationId: Value<String?>(
                  base?.observedPublicationId,
                ),
                notBefore: Value<DateTime>(notBefore),
                createdAt: now,
                lastTransitionAt: now,
              ),
            );
      } else {
        generation = existingDesired.generation + 1;
        desiredStateId = existingDesired.id;
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(existingDesired.id))).write(
          DesiredStateRowsCompanion(
            desiredLifecycle: const Value<String>('deleted'),
            title: const Value<String?>(null),
            notes: const Value<String?>(null),
            status: const Value<String?>(null),
            dueEpochDay: const Value<int?>(null),
            desiredTaskListId: Value<int>(root.taskListId),
            desiredParentTaskId: const Value<int?>(null),
            desiredPreviousTaskId: const Value<int?>(null),
            contentDirty: const Value<bool>(false),
            structureDirty: const Value<bool>(false),
            lifecycleDirty: const Value<bool>(true),
            generation: Value<int>(generation),
            localCausalSequence: Value<int>(sequence),
            state: const Value<String>('pending'),
            failureCode: const Value<String?>(null),
            localModifiedAt: const Value<DateTime?>(null),
            notBefore: Value<DateTime>(notBefore),
            lastTransitionAt: Value<DateTime>(now),
          ),
        );
      }

      final descendantIds = subtree
          .where((row) => row.id != rootTaskId.value)
          .map((row) => row.id)
          .toList(growable: false);
      if (descendantIds.isNotEmpty) {
        await (_database.update(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.resourceType.equals('task') &
                  row.targetTaskId.isIn(descendantIds) &
                  row.state.isIn(<String>[
                    'pending',
                    'in_flight',
                    'uncertain',
                    'failed',
                  ]),
            ))
            .write(
              DesiredStateRowsCompanion(
                state: const Value<String>('superseded'),
                failureCode: const Value<String?>(null),
                lastTransitionAt: Value<DateTime>(now),
              ),
            );
      }

      final tombstoneId = await _database
          .into(_database.taskDeleteTombstoneRows)
          .insert(
            TaskDeleteTombstoneRowsCompanion.insert(
              accountId: accountId.value,
              rootTaskId: rootTaskId.value,
              desiredStateId: desiredStateId,
              deleteGeneration: generation,
              notBefore: notBefore,
              snapshotAvailable: true,
              createdAt: now,
            ),
          );
      for (final task in subtree) {
        await _database
            .into(_database.taskDeleteSnapshotRows)
            .insert(
              TaskDeleteSnapshotRowsCompanion.insert(
                accountId: accountId.value,
                tombstoneId: tombstoneId,
                taskId: task.id,
                taskListId: task.taskListId,
                parentTaskId: Value<int?>(task.parentTaskId),
                remoteId: Value<String?>(task.remoteId),
                title: task.title,
                notes: Value<String?>(task.notes),
                status: task.status,
                dueEpochDay: Value<int?>(task.dueEpochDay),
                position: task.position,
              ),
            );
      }
      await (_database.update(_database.taskCacheRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.isIn(subtree.map((task) => task.id)),
          ))
          .write(
            const TaskCacheRowsCompanion(projection: Value<String>('deleted')),
          );
      await DesiredStateDao(_database).recomputeCounts(accountId);
      return (await readTaskDelete(accountId, rootTaskId))!;
    });
  }

  Future<void> undoTaskDelete({
    required AccountId accountId,
    required TaskId rootTaskId,
    required DateTime now,
  }) {
    return _database.transaction(() async {
      final tombstone =
          await (_database.select(_database.taskDeleteTombstoneRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.rootTaskId.equals(rootTaskId.value),
              ))
              .getSingleOrNull();
      if (tombstone == null) {
        throw const DeleteStateException('delete_undo_unavailable');
      }
      if (!tombstone.snapshotAvailable ||
          !const TaskDeletePolicy().isUndoAvailable(
            now: now,
            notBefore: tombstone.notBefore,
          )) {
        throw const DeleteStateException('delete_undo_expired');
      }
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(tombstone.desiredStateId) &
                    row.generation.equals(tombstone.deleteGeneration) &
                    row.desiredLifecycle.equals('deleted') &
                    row.state.equals('pending'),
              ))
              .getSingleOrNull();
      if (desired == null) {
        throw const DeleteStateException('delete_already_dispatched');
      }
      final snapshots =
          await (_database.select(_database.taskDeleteSnapshotRows)
                ..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.tombstoneId.equals(tombstone.id),
                )
                ..orderBy([
                  (row) => OrderingTerm.asc(row.parentTaskId),
                  (row) => OrderingTerm.asc(row.id),
                ]))
              .get();
      if (snapshots.isEmpty) {
        throw const DeleteStateException('delete_snapshot_missing');
      }
      final desiredDao = DesiredStateDao(_database);
      for (final snapshot in snapshots) {
        await (_database.update(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(snapshot.taskId),
            ))
            .write(
              TaskCacheRowsCompanion(
                taskListId: Value<int>(snapshot.taskListId),
                parentTaskId: Value<int?>(snapshot.parentTaskId),
                remoteId: Value<String?>(snapshot.remoteId),
                title: Value<String>(snapshot.title),
                notes: Value<String?>(snapshot.notes),
                status: Value<String>(snapshot.status),
                dueEpochDay: Value<int?>(snapshot.dueEpochDay),
                position: Value<String>(snapshot.position),
                projection: const Value<String>('supported'),
              ),
            );
        await desiredDao.writeTaskPresent(
          accountId: accountId,
          taskId: TaskId(snapshot.taskId),
          taskListId: TaskListId(snapshot.taskListId),
          parentTaskId: snapshot.parentTaskId == null
              ? null
              : TaskId(snapshot.parentTaskId!),
          title: snapshot.title,
          notes: snapshot.notes,
          status: _status(snapshot.status),
          due: _taskDate(snapshot.dueEpochDay),
          modifiedAt: now,
        );
      }
      await (_database.delete(
        _database.taskDeleteTombstoneRows,
      )..where((row) => row.id.equals(tombstone.id))).go();
      await desiredDao.recomputeCounts(accountId);
    });
  }

  Future<void> createTaskListDelete({
    required AccountId accountId,
    required TaskListId taskListId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
      final taskList =
          await (_database.select(_database.taskListCacheRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(taskListId.value) &
                    row.projection.equals('supported'),
              ))
              .getSingleOrNull();
      if (taskList == null) {
        throw const DeleteStateException('task_list_not_found');
      }
      final base =
          await (_database.select(_database.taskListRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskListId.equals(taskListId.value),
              ))
              .getSingleOrNull();
      final existing =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.resourceType.equals('task_list') &
                    row.targetTaskListId.equals(taskListId.value),
              ))
              .getSingleOrNull();
      final now = acknowledgedAt.toUtc();
      final sequence = await _nextCausalSequence(accountId);
      final int desiredStateId;
      if (existing == null) {
        desiredStateId = await _database
            .into(_database.desiredStateRows)
            .insert(
              DesiredStateRowsCompanion.insert(
                accountId: accountId.value,
                targetKey: 'task_list:${taskListId.value}',
                resourceType: 'task_list',
                targetTaskListId: Value<int>(taskListId.value),
                desiredLifecycle: 'deleted',
                title: Value<String>(taskList.title),
                lifecycleDirty: const Value<bool>(true),
                generation: 1,
                localCausalSequence: sequence,
                state: 'pending',
                baseRemoteId: Value<String?>(
                  base?.remoteId ?? taskList.remoteId,
                ),
                baseEtag: Value<String?>(base?.etag),
                baseRemoteUpdatedAt: Value<DateTime?>(base?.remoteUpdatedAt),
                baseObservedPublicationId: Value<String?>(
                  base?.observedPublicationId,
                ),
                baseTitle: Value<String?>(base?.title),
                createdAt: now,
                lastTransitionAt: now,
              ),
            );
      } else {
        desiredStateId = existing.id;
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(existing.id))).write(
          DesiredStateRowsCompanion(
            desiredLifecycle: const Value<String>('deleted'),
            contentDirty: const Value<bool>(false),
            structureDirty: const Value<bool>(false),
            lifecycleDirty: const Value<bool>(true),
            generation: Value<int>(existing.generation + 1),
            localCausalSequence: Value<int>(sequence),
            state: const Value<String>('pending'),
            failureCode: const Value<String?>(null),
            notBefore: const Value<DateTime?>(null),
            lastTransitionAt: Value<DateTime>(now),
          ),
        );
      }
      await (_database.update(_database.taskListCacheRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(taskListId.value),
          ))
          .write(
            const TaskListCacheRowsCompanion(
              projection: Value<String>('deleted'),
            ),
          );
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.resourceType.equals('task') &
                row.desiredTaskListId.equals(taskListId.value) &
                row.state.isIn(<String>[
                  'pending',
                  'in_flight',
                  'uncertain',
                  'failed',
                ]),
          ))
          .write(
            DesiredStateRowsCompanion(
              state: const Value<String>('superseded'),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(now),
            ),
          );
      if (taskList.remoteId == null &&
          base == null &&
          !await _hasDesiredStateAttempts(accountId, desiredStateId)) {
        await (_database.update(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(desiredStateId),
            ))
            .write(
              DesiredStateRowsCompanion(
                state: const Value<String>('confirmed'),
                lastTransitionAt: Value<DateTime>(now),
              ),
            );
      }
      await DesiredStateDao(_database).recomputeCounts(accountId);
    });
  }

  Future<int> cleanupExpiredTaskDeletes({
    required AccountId accountId,
    required DateTime now,
  }) {
    return _database.transaction(() async {
      final expired =
          await (_database.select(_database.taskDeleteTombstoneRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.snapshotAvailable.equals(true) &
                    row.notBefore.isSmallerOrEqualValue(now.toUtc()),
              ))
              .get();
      for (final tombstone in expired) {
        await (_database.update(_database.taskDeleteSnapshotRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.tombstoneId.equals(tombstone.id),
            ))
            .write(
              const TaskDeleteSnapshotRowsCompanion(
                title: Value<String>(''),
                notes: Value<String?>(null),
                status: Value<String>('needs_action'),
                dueEpochDay: Value<int?>(null),
                position: Value<String>('expired-delete'),
              ),
            );
        await (_database.update(
          _database.taskDeleteTombstoneRows,
        )..where((row) => row.id.equals(tombstone.id))).write(
          const TaskDeleteTombstoneRowsCompanion(
            snapshotAvailable: Value<bool>(false),
          ),
        );
        final desired =
            await (_database.select(_database.desiredStateRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.id.equals(tombstone.desiredStateId) &
                      row.generation.equals(tombstone.deleteGeneration) &
                      row.desiredLifecycle.equals('deleted') &
                      row.baseRemoteId.isNull(),
                ))
                .getSingleOrNull();
        if (desired != null &&
            !await _hasDesiredStateAttempts(accountId, desired.id)) {
          await (_database.update(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(desired.id),
              ))
              .write(
                DesiredStateRowsCompanion(
                  state: const Value<String>('confirmed'),
                  lastTransitionAt: Value<DateTime>(now.toUtc()),
                ),
              );
          await (_database.delete(_database.taskDeleteTombstoneRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(tombstone.id),
              ))
              .go();
        }
      }
      if (expired.isNotEmpty) {
        await DesiredStateDao(_database).recomputeCounts(accountId);
      }
      return expired.length;
    });
  }

  Future<TaskDeleteTombstoneRecord?> readTaskDelete(
    AccountId accountId,
    TaskId rootTaskId,
  ) async {
    final row =
        await (_database.select(_database.taskDeleteTombstoneRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.rootTaskId.equals(rootTaskId.value),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    final snapshots =
        await (_database.select(_database.taskDeleteSnapshotRows)
              ..where(
                (candidate) =>
                    candidate.accountId.equals(accountId.value) &
                    candidate.tombstoneId.equals(row.id),
              )
              ..orderBy([(candidate) => OrderingTerm.asc(candidate.id)]))
            .get();
    return TaskDeleteTombstoneRecord(
      id: row.id,
      accountId: accountId,
      rootTaskId: rootTaskId,
      desiredStateId: row.desiredStateId,
      deleteGeneration: row.deleteGeneration,
      notBefore: row.notBefore.toUtc(),
      snapshotAvailable: row.snapshotAvailable,
      snapshotTaskIds: row.snapshotAvailable
          ? snapshots.map((snapshot) => TaskId(snapshot.taskId)).toList()
          : const <TaskId>[],
    );
  }

  Stream<List<TaskDeleteUndo>> watchAvailableTaskUndos(AccountId accountId) {
    final query = _database.customSelect(
      '''
      SELECT t.root_task_id, t.not_before, s.title
      FROM task_delete_tombstones t
      JOIN task_delete_snapshots s
        ON s.account_id = t.account_id
       AND s.tombstone_id = t.id
       AND s.task_id = t.root_task_id
      WHERE t.account_id = ?1 AND t.snapshot_available = 1
      ORDER BY t.created_at DESC, t.id DESC
      ''',
      variables: <Variable<Object>>[Variable<int>(accountId.value)],
      readsFrom: <ResultSetImplementation<Table, Object?>>{
        _database.taskDeleteTombstoneRows,
        _database.taskDeleteSnapshotRows,
      },
    );
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => TaskDeleteUndo(
              taskId: TaskId(row.read<int>('root_task_id')),
              title: row.read<String>('title'),
              notBefore: row.read<DateTime>('not_before').toUtc(),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<DeleteCandidate?> readNextEligibleDelete({
    required AccountId accountId,
    required DateTime now,
    String? runId,
  }) async {
    final row = await _database
        .customSelect(
          '''
      SELECT d.id, d.resource_type, d.generation, d.state,
             COALESCE(d.target_task_list_id, task.task_list_id) AS task_list_id,
             list.remote_id AS task_list_remote_id,
             d.target_task_id, task.remote_id AS task_remote_id,
             task_base.etag AS task_etag
      FROM desired_states d
      LEFT JOIN tasks task
        ON task.account_id = d.account_id AND task.id = d.target_task_id
      JOIN task_lists list
        ON list.account_id = d.account_id
       AND list.id = COALESCE(d.target_task_list_id, task.task_list_id)
      LEFT JOIN task_remote_bases task_base
        ON task_base.account_id = d.account_id
       AND task_base.task_id = d.target_task_id
      WHERE d.account_id = ?1
        AND d.desired_lifecycle = 'deleted'
        AND d.lifecycle_dirty = 1
        AND d.state = 'pending'
        AND (d.not_before IS NULL OR d.not_before <= ?2)
        AND d.base_remote_id IS NOT NULL
        AND list.remote_id IS NOT NULL
        AND (d.resource_type = 'task_list' OR task_base.etag IS NOT NULL)
        AND (?3 = '' OR (
          EXISTS (
            SELECT 1 FROM scope_completeness list_scope
            WHERE list_scope.account_id = d.account_id
              AND list_scope.scope_kind = 'task_lists'
              AND list_scope.publication_id = ?3
              AND list_scope.is_complete = 1
          )
          AND (d.resource_type = 'task_list' OR EXISTS (
            SELECT 1 FROM scope_completeness task_scope
            WHERE task_scope.account_id = d.account_id
              AND task_scope.scope_kind = 'tasks'
              AND task_scope.task_list_id = task.task_list_id
              AND task_scope.publication_id = ?3
              AND task_scope.is_complete = 1
          ))
        ))
      ORDER BY CASE WHEN d.resource_type = 'task_list' THEN 0 ELSE 1 END,
               d.local_causal_sequence, d.id
      LIMIT 1
      ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<DateTime>(now.toUtc()),
            Variable<String>(runId ?? ''),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.desiredStateRows,
            _database.taskListCacheRows,
            _database.taskCacheRows,
            _database.taskRemoteBases,
            _database.scopeCompletenessRows,
          },
        )
        .getSingleOrNull();
    if (row == null) return null;
    final resourceType = row.read<String>('resource_type') == 'task_list'
        ? DeleteResourceType.taskList
        : DeleteResourceType.task;
    final taskId = row.readNullable<int>('target_task_id');
    final taskRemoteId = row.readNullable<String>('task_remote_id');
    return DeleteCandidate(
      resourceType: resourceType,
      desiredStateId: row.read<int>('id'),
      generation: row.read<int>('generation'),
      taskListId: TaskListId(row.read<int>('task_list_id')),
      taskListRemoteId: TaskListRemoteId(
        row.read<String>('task_list_remote_id'),
      ),
      taskId: taskId == null ? null : TaskId(taskId),
      taskRemoteId: taskRemoteId == null ? null : TaskRemoteId(taskRemoteId),
      etag: row.readNullable<String>('task_etag'),
      state: _lifecycle(row.read<String>('state')),
    );
  }

  Future<DateTime?> nextTaskDeleteExpiry(AccountId accountId) async {
    final minimum = _database.taskDeleteTombstoneRows.notBefore.min();
    final query = _database.selectOnly(_database.taskDeleteTombstoneRows)
      ..addColumns(<Expression<Object>>[minimum])
      ..where(
        _database.taskDeleteTombstoneRows.accountId.equals(accountId.value) &
            _database.taskDeleteTombstoneRows.snapshotAvailable.equals(true),
      );
    return (await query.getSingle()).read(minimum)?.toUtc();
  }

  Future<DesiredStateLifecycle?> readTaskDeleteState(
    AccountId accountId,
    TaskId taskId,
  ) async {
    final row =
        await (_database.select(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.resourceType.equals('task') &
                  row.targetTaskId.equals(taskId.value),
            ))
            .getSingleOrNull();
    return row == null ? null : _lifecycle(row.state);
  }

  Future<void> reconcileDeletes({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  }) {
    return _database.transaction(() async {
      final now = reconciledAt.toUtc();
      final remoteDeleted = await _database
          .customSelect(
            '''
        SELECT d.id, d.generation, d.desired_lifecycle, d.target_task_id
        FROM desired_states d
        JOIN task_remote_bases b
          ON b.account_id = d.account_id AND b.task_id = d.target_task_id
        WHERE d.account_id = ?1
          AND d.resource_type = 'task'
          AND d.state IN ('pending', 'in_flight', 'uncertain', 'failed')
          AND b.deleted = 1
          AND b.observed_publication_id = ?2
        ''',
            variables: <Variable<Object>>[
              Variable<int>(accountId.value),
              Variable<String>(runId),
            ],
            readsFrom: <ResultSetImplementation<Table, Object?>>{
              _database.desiredStateRows,
              _database.taskRemoteBases,
            },
          )
          .get();
      for (final row in remoteDeleted) {
        final desiredStateId = row.read<int>('id');
        final generation = row.read<int>('generation');
        final resolution = row.read<String>('desired_lifecycle') == 'deleted'
            ? 'confirmed'
            : 'superseded';
        await (_database.update(_database.taskCacheRows)..where(
              (task) =>
                  task.accountId.equals(accountId.value) &
                  task.id.equals(row.read<int>('target_task_id')),
            ))
            .write(
              const TaskCacheRowsCompanion(
                projection: Value<String>('deleted'),
              ),
            );
        await (_database.update(_database.desiredStateAttemptRows)..where(
              (attempt) =>
                  attempt.accountId.equals(accountId.value) &
                  attempt.desiredStateId.equals(desiredStateId) &
                  attempt.generation.equals(generation) &
                  attempt.state.isIn(<String>[
                    'in_flight',
                    'uncertain',
                    'failed',
                  ]),
            ))
            .write(
              DesiredStateAttemptRowsCompanion(
                state: Value<String>(resolution),
                failureCode: const Value<String?>(null),
                lastTransitionAt: Value<DateTime>(now),
              ),
            );
        await (_database.update(
          _database.desiredStateRows,
        )..where((desired) => desired.id.equals(desiredStateId))).write(
          DesiredStateRowsCompanion(
            state: Value<String>(resolution),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(now),
          ),
        );
        if (resolution == 'confirmed') {
          await (_database.delete(_database.taskDeleteTombstoneRows)..where(
                (tombstone) =>
                    tombstone.accountId.equals(accountId.value) &
                    tombstone.desiredStateId.equals(desiredStateId),
              ))
              .go();
        }
      }

      final liveDeleteTargets = await _database
          .customSelect(
            '''
        SELECT d.id, b.remote_id, b.etag, b.remote_updated_at,
               b.observed_publication_id, b.task_list_id, b.parent_task_id
        FROM desired_states d
        JOIN task_remote_bases b
          ON b.account_id = d.account_id AND b.task_id = d.target_task_id
        WHERE d.account_id = ?1
          AND d.resource_type = 'task'
          AND d.desired_lifecycle = 'deleted'
          AND d.state IN ('pending', 'uncertain', 'failed')
          AND b.deleted = 0
          AND b.observed_publication_id = ?2
        ''',
            variables: <Variable<Object>>[
              Variable<int>(accountId.value),
              Variable<String>(runId),
            ],
            readsFrom: <ResultSetImplementation<Table, Object?>>{
              _database.desiredStateRows,
              _database.taskRemoteBases,
            },
          )
          .get();
      for (final row in liveDeleteTargets) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((desired) => desired.id.equals(row.read<int>('id')))).write(
          DesiredStateRowsCompanion(
            desiredTaskListId: Value<int>(row.read<int>('task_list_id')),
            desiredParentTaskId: Value<int?>(
              row.readNullable<int>('parent_task_id'),
            ),
            baseRemoteId: Value<String>(row.read<String>('remote_id')),
            baseEtag: Value<String?>(row.readNullable<String>('etag')),
            baseRemoteUpdatedAt: Value<DateTime?>(
              row.readNullable<DateTime>('remote_updated_at')?.toUtc(),
            ),
            baseObservedPublicationId: Value<String>(
              row.read<String>('observed_publication_id'),
            ),
            state: const Value<String>('pending'),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(now),
          ),
        );
      }
      await DesiredStateDao(_database).recomputeCounts(accountId);
    });
  }

  Future<bool> preserveMovedDeleteSurvivor({
    required AccountId accountId,
    required TaskId taskId,
    required TaskListId currentTaskListId,
    required TaskId? currentParentTaskId,
  }) {
    return _database.transaction(() async {
      final snapshot = await _database
          .customSelect(
            '''
        SELECT s.id, s.task_list_id, s.parent_task_id
        FROM task_delete_snapshots s
        JOIN task_delete_tombstones t
          ON t.account_id = s.account_id AND t.id = s.tombstone_id
        WHERE s.account_id = ?1
          AND s.task_id = ?2
          AND t.root_task_id <> s.task_id
        LIMIT 1
        ''',
            variables: <Variable<Object>>[
              Variable<int>(accountId.value),
              Variable<int>(taskId.value),
            ],
            readsFrom: <ResultSetImplementation<Table, Object?>>{
              _database.taskDeleteSnapshotRows,
              _database.taskDeleteTombstoneRows,
            },
          )
          .getSingleOrNull();
      if (snapshot == null ||
          (snapshot.read<int>('task_list_id') == currentTaskListId.value &&
              snapshot.readNullable<int>('parent_task_id') ==
                  currentParentTaskId?.value)) {
        return false;
      }
      await (_database.delete(
        _database.taskDeleteSnapshotRows,
      )..where((row) => row.id.equals(snapshot.read<int>('id')))).go();
      return true;
    });
  }

  Future<bool> isTaskProtectedByDeleteSnapshot({
    required AccountId accountId,
    required TaskId taskId,
  }) async =>
      await (_database.select(_database.taskDeleteSnapshotRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.taskId.equals(taskId.value),
          ))
          .getSingleOrNull() !=
      null;

  Future<void> acknowledgeTaskListDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
      await DesiredStateDao(_database).transitionAttempt(
        accountId: accountId,
        attemptId: claim.attemptId,
        state: DesiredStateLifecycle.confirmed,
        transitionedAt: acknowledgedAt,
      );
      final list =
          await (_database.select(_database.taskListCacheRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(claim.taskListId.value),
              ))
              .getSingle();
      await CacheDao(_database).putTaskListRemoteBase(
        accountId: accountId,
        taskListId: claim.taskListId,
        remoteId: claim.taskListRemoteId,
        title: list.title,
        observedPublicationId: observationId,
        deleted: true,
      );
    });
  }

  Future<void> acknowledgeTaskDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
      await DesiredStateDao(_database).transitionAttempt(
        accountId: accountId,
        attemptId: claim.attemptId,
        state: DesiredStateLifecycle.confirmed,
        transitionedAt: acknowledgedAt,
      );
      await CacheDao(_database).putTaskRemoteBase(
        accountId: accountId,
        taskId: claim.taskId!,
        taskListId: claim.taskListId,
        remoteId: claim.taskRemoteId!,
        observedPublicationId: observationId,
        deleted: true,
      );
      await (_database.delete(_database.taskDeleteTombstoneRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.rootTaskId.equals(claim.taskId!.value),
          ))
          .go();
    });
  }

  Future<int> _nextCausalSequence(AccountId accountId) async {
    await _database
        .into(_database.accountPreferenceRows)
        .insert(
          AccountPreferenceRowsCompanion.insert(
            accountId: Value<int>(accountId.value),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final preference = await (_database.select(
      _database.accountPreferenceRows,
    )..where((row) => row.accountId.equals(accountId.value))).getSingle();
    await (_database.update(
      _database.accountPreferenceRows,
    )..where((row) => row.accountId.equals(accountId.value))).write(
      AccountPreferenceRowsCompanion(
        nextLocalCausalSequence: Value<int>(
          preference.nextLocalCausalSequence + 1,
        ),
      ),
    );
    return preference.nextLocalCausalSequence;
  }

  Future<bool> _hasDesiredStateAttempts(
    AccountId accountId,
    int desiredStateId,
  ) async =>
      await (_database.select(_database.desiredStateAttemptRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.desiredStateId.equals(desiredStateId),
          ))
          .getSingleOrNull() !=
      null;
}

final class DeleteStateException implements Exception {
  const DeleteStateException(this.code);

  final String code;
}

TaskStatus _status(String value) => switch (value) {
  'needs_action' => TaskStatus.needsAction,
  'completed' => TaskStatus.completed,
  _ => throw const DeleteStateException('unknown_task_status'),
};

TaskDate? _taskDate(int? epochDay) {
  if (epochDay == null) return null;
  final date = DateTime.utc(1970).add(Duration(days: epochDay));
  return TaskDate(date.year, date.month, date.day);
}

DesiredStateLifecycle _lifecycle(String value) => switch (value) {
  'pending' => DesiredStateLifecycle.pending,
  'in_flight' => DesiredStateLifecycle.inFlight,
  'uncertain' => DesiredStateLifecycle.uncertain,
  'failed' => DesiredStateLifecycle.failed,
  'confirmed' => DesiredStateLifecycle.confirmed,
  'superseded' => DesiredStateLifecycle.superseded,
  _ => throw const DeleteStateException('unknown_desired_state'),
};
