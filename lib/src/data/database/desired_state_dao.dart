import 'dart:async';

import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/model/tasks.dart';
import '../../sync/reconciliation/content_policy.dart';
import '../../sync/update_operations.dart';
import 'app_database.dart';
import 'cache_dao.dart';

enum DesiredStateLifecycle {
  pending,
  inFlight,
  uncertain,
  failed,
  confirmed,
  superseded,
}

enum DesiredLifecycle { present, deleted }

enum DesiredStateTransactionBoundary {
  afterProjectionWrite,
  afterDesiredStateWrite,
  beforeLocalCommit,
  afterRemoteIdentityWrite,
  afterRemoteBaseWrite,
  beforeRemoteCommit,
}

typedef DesiredStateTransactionControl =
    FutureOr<void> Function(DesiredStateTransactionBoundary boundary);

final class DesiredStatePersistenceException implements Exception {
  const DesiredStatePersistenceException(this.code);

  final String code;
}

final class DesiredStateInvariantException implements Exception {
  const DesiredStateInvariantException(this.code);

  final String code;

  @override
  String toString() => 'DesiredStateInvariantException($code)';
}

final class TaskListDesiredStateRecord {
  const TaskListDesiredStateRecord({
    required this.id,
    required this.accountId,
    required this.taskListId,
    required this.title,
    required this.generation,
    required this.localCausalSequence,
    required this.state,
    required this.desiredLifecycle,
    required this.baseRemoteId,
    required this.baseEtag,
    required this.baseRemoteUpdatedAt,
    required this.baseObservedPublicationId,
    required this.baseTitle,
    required this.localModifiedAt,
    required this.createdAt,
    required this.lastTransitionAt,
  });

  final int id;
  final AccountId accountId;
  final TaskListId taskListId;
  final String title;
  final int generation;
  final int localCausalSequence;
  final DesiredStateLifecycle state;
  final DesiredLifecycle desiredLifecycle;
  final TaskListRemoteId? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
  final DateTime? localModifiedAt;
  final DateTime createdAt;
  final DateTime lastTransitionAt;
}

final class TaskDesiredStateRecord {
  const TaskDesiredStateRecord({
    required this.id,
    required this.accountId,
    required this.taskId,
    required this.taskListId,
    required this.parentTaskId,
    required this.previousTaskId,
    required this.contentDirty,
    required this.structureDirty,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.generation,
    required this.localCausalSequence,
    required this.state,
    required this.desiredLifecycle,
    required this.baseRemoteId,
    required this.baseEtag,
    required this.baseRemoteUpdatedAt,
    required this.baseObservedPublicationId,
    required this.baseTitle,
    required this.baseNotes,
    required this.baseStatus,
    required this.baseDue,
    required this.baseTaskListId,
    required this.baseParentTaskId,
    required this.basePreviousTaskId,
    required this.basePosition,
    required this.baseSiblingOrder,
    required this.localModifiedAt,
    required this.createdAt,
    required this.lastTransitionAt,
  });

  final int id;
  final AccountId accountId;
  final TaskId taskId;
  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final TaskId? previousTaskId;
  final bool contentDirty;
  final bool structureDirty;
  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;
  final int generation;
  final int localCausalSequence;
  final DesiredStateLifecycle state;
  final DesiredLifecycle desiredLifecycle;
  final TaskRemoteId? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
  final String? baseNotes;
  final TaskStatus? baseStatus;
  final TaskDate? baseDue;
  final TaskListId? baseTaskListId;
  final TaskId? baseParentTaskId;
  final TaskId? basePreviousTaskId;
  final String? basePosition;
  final String? baseSiblingOrder;
  final DateTime? localModifiedAt;
  final DateTime createdAt;
  final DateTime lastTransitionAt;
}

final class DesiredStateAttemptRecord {
  const DesiredStateAttemptRecord({
    required this.id,
    required this.accountId,
    required this.desiredStateId,
    required this.generation,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.state,
    required this.failureCode,
    required this.claimedAt,
    required this.lastTransitionAt,
  });

  final int id;
  final AccountId accountId;
  final int desiredStateId;
  final int generation;
  final String? title;
  final String? notes;
  final TaskStatus? status;
  final TaskDate? due;
  final DesiredStateLifecycle state;
  final String? failureCode;
  final DateTime claimedAt;
  final DateTime lastTransitionAt;
}

enum DesiredCreateResourceType { taskList, task }

final class DesiredCreateCandidate {
  const DesiredCreateCandidate({
    required this.resourceType,
    required this.taskListId,
    required this.taskId,
    required this.parentTaskId,
    required this.taskListRemoteId,
    required this.parentRemoteId,
    required this.previousTaskId,
    required this.previousRemoteId,
  });

  final DesiredCreateResourceType resourceType;
  final TaskListId taskListId;
  final TaskId? taskId;
  final TaskId? parentTaskId;
  final TaskListRemoteId? taskListRemoteId;
  final TaskRemoteId? parentRemoteId;
  final TaskId? previousTaskId;
  final TaskRemoteId? previousRemoteId;
}

final class DesiredCreateRecoveryRecord {
  const DesiredCreateRecoveryRecord({
    required this.attempt,
    required this.candidate,
    required this.uncertainAttemptCount,
  });

  final DesiredStateAttemptRecord attempt;
  final DesiredCreateCandidate candidate;
  final int uncertainAttemptCount;
}

enum DesiredUpdateResourceType { task, taskList }

final class DesiredUpdateCandidate {
  const DesiredUpdateCandidate({
    required this.resourceType,
    required this.taskListId,
    required this.taskListRemoteId,
    required this.taskId,
    required this.taskRemoteId,
    required this.parentTaskId,
    required this.parentRemoteId,
    required this.etag,
  });

  final DesiredUpdateResourceType resourceType;
  final TaskListId taskListId;
  final TaskListRemoteId taskListRemoteId;
  final TaskId? taskId;
  final TaskRemoteId? taskRemoteId;
  final TaskId? parentTaskId;
  final TaskRemoteId? parentRemoteId;
  final String? etag;
}

final class DesiredStateDao {
  const DesiredStateDao(this._database, {this.transactionControl});

  final AppDatabase _database;
  final DesiredStateTransactionControl? transactionControl;

  Future<TaskListDesiredStateRecord?> readTaskList(
    AccountId accountId,
    TaskListId taskListId,
  ) async {
    final row = await _taskListQuery(accountId, taskListId).getSingleOrNull();
    return row == null ? null : _mapTaskList(row);
  }

  Future<TaskDesiredStateRecord?> readTask(
    AccountId accountId,
    TaskId taskId,
  ) async {
    final row = await _taskQuery(accountId, taskId).getSingleOrNull();
    return row == null ? null : _mapTask(row);
  }

  Future<int> countForAccount(AccountId accountId) async {
    final count = _database.desiredStateRows.id.count();
    final query = _database.selectOnly(_database.desiredStateRows)
      ..addColumns(<Expression<Object>>[count])
      ..where(_database.desiredStateRows.accountId.equals(accountId.value));
    return (await query.getSingle()).read(count) ?? 0;
  }

  Future<DesiredCreateCandidate?> readNextCreateCandidate(
    AccountId accountId,
    String runId,
  ) async {
    final row = await _database
        .customSelect(
          '''
          SELECT
            d.resource_type,
            d.target_task_list_id,
            d.target_task_id,
            d.desired_task_list_id,
            d.desired_parent_task_id,
            d.desired_previous_task_id,
            desired_list.remote_id AS desired_list_remote_id,
            desired_parent.remote_id AS desired_parent_remote_id
            ,desired_previous.remote_id AS desired_previous_remote_id
          FROM desired_states d
          LEFT JOIN task_lists target_list
            ON target_list.account_id = d.account_id
           AND target_list.id = d.target_task_list_id
          LEFT JOIN tasks target_task
            ON target_task.account_id = d.account_id
           AND target_task.id = d.target_task_id
          LEFT JOIN task_lists desired_list
            ON desired_list.account_id = d.account_id
           AND desired_list.id = d.desired_task_list_id
          LEFT JOIN tasks desired_parent
            ON desired_parent.account_id = d.account_id
           AND desired_parent.id = d.desired_parent_task_id
          LEFT JOIN tasks desired_previous
            ON desired_previous.account_id = d.account_id
           AND desired_previous.id = d.desired_previous_task_id
          WHERE d.account_id = ?1
            AND EXISTS (
              SELECT 1
              FROM scope_completeness list_scope
              WHERE list_scope.account_id = d.account_id
                AND list_scope.scope_kind = 'task_lists'
                AND list_scope.publication_id = ?2
                AND list_scope.is_complete = 1
            )
            AND d.desired_lifecycle = 'present'
            AND d.state = 'pending'
            AND d.base_remote_id IS NULL
            AND NOT EXISTS (
              SELECT 1
              FROM desired_state_attempts uncertain_create
              WHERE uncertain_create.account_id = d.account_id
                AND uncertain_create.desired_state_id = d.id
                AND uncertain_create.base_remote_id IS NULL
                AND uncertain_create.state = 'uncertain'
            )
            AND (
              (d.resource_type = 'task_list'
                AND target_list.remote_id IS NULL)
              OR
              (d.resource_type = 'task'
                AND target_task.remote_id IS NULL
                AND desired_list.remote_id IS NOT NULL
                AND (
                  EXISTS (
                    SELECT 1
                    FROM scope_completeness task_scope
                    WHERE task_scope.account_id = d.account_id
                      AND task_scope.scope_kind = 'tasks'
                      AND task_scope.task_list_id = d.desired_task_list_id
                      AND task_scope.publication_id = ?2
                      AND task_scope.is_complete = 1
                  )
                  OR EXISTS (
                    SELECT 1
                    FROM task_list_remote_bases created_list_base
                    WHERE created_list_base.account_id = d.account_id
                      AND created_list_base.task_list_id = d.desired_task_list_id
                      AND created_list_base.observed_publication_id
                        LIKE 'mutation:' || ?2 || ':%'
                  )
                )
                AND (d.desired_parent_task_id IS NULL
                  OR desired_parent.remote_id IS NOT NULL)
                AND (d.desired_previous_task_id IS NULL
                  OR desired_previous.remote_id IS NOT NULL))
            )
          ORDER BY
            CASE
              WHEN d.resource_type = 'task_list' THEN 0
              WHEN d.desired_parent_task_id IS NULL THEN 1
              ELSE 2
            END,
            d.local_causal_sequence,
            d.id
          LIMIT 1
          ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<String>(runId),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.desiredStateRows,
            _database.taskListCacheRows,
            _database.taskCacheRows,
            _database.scopeCompletenessRows,
            _database.taskListRemoteBases,
            _database.desiredStateAttemptRows,
          },
        )
        .getSingleOrNull();
    if (row == null) return null;
    final resourceType = row.read<String>('resource_type');
    if (resourceType == 'task_list') {
      return DesiredCreateCandidate(
        resourceType: DesiredCreateResourceType.taskList,
        taskListId: TaskListId(row.read<int>('target_task_list_id')),
        taskId: null,
        parentTaskId: null,
        taskListRemoteId: null,
        parentRemoteId: null,
        previousTaskId: null,
        previousRemoteId: null,
      );
    }
    if (resourceType != 'task') {
      throw const DesiredStateInvariantException('unknown_resource_type');
    }
    final parentTaskId = row.readNullable<int>('desired_parent_task_id');
    final parentRemoteId = row.readNullable<String>('desired_parent_remote_id');
    final previousTaskId = row.readNullable<int>('desired_previous_task_id');
    final previousRemoteId = row.readNullable<String>(
      'desired_previous_remote_id',
    );
    return DesiredCreateCandidate(
      resourceType: DesiredCreateResourceType.task,
      taskListId: TaskListId(row.read<int>('desired_task_list_id')),
      taskId: TaskId(row.read<int>('target_task_id')),
      parentTaskId: parentTaskId == null ? null : TaskId(parentTaskId),
      taskListRemoteId: TaskListRemoteId(
        row.read<String>('desired_list_remote_id'),
      ),
      parentRemoteId: parentRemoteId == null
          ? null
          : TaskRemoteId(parentRemoteId),
      previousTaskId: previousTaskId == null ? null : TaskId(previousTaskId),
      previousRemoteId: previousRemoteId == null
          ? null
          : TaskRemoteId(previousRemoteId),
    );
  }

  Future<DesiredUpdateCandidate?> readNextUpdateCandidate(
    AccountId accountId,
    String runId,
  ) async {
    final row = await _database
        .customSelect(
          '''
          SELECT
            d.resource_type,
            d.target_task_list_id,
            d.target_task_id,
            d.desired_task_list_id,
            d.desired_parent_task_id,
            target_list.remote_id AS target_list_remote_id,
            target_task.remote_id AS target_task_remote_id,
            desired_list.remote_id AS desired_list_remote_id,
            desired_parent.remote_id AS desired_parent_remote_id,
            task_base.etag AS task_etag
          FROM desired_states d
          LEFT JOIN task_lists target_list
            ON target_list.account_id = d.account_id
           AND target_list.id = d.target_task_list_id
          LEFT JOIN tasks target_task
            ON target_task.account_id = d.account_id
           AND target_task.id = d.target_task_id
          LEFT JOIN task_lists desired_list
            ON desired_list.account_id = d.account_id
           AND desired_list.id = d.desired_task_list_id
          LEFT JOIN tasks desired_parent
            ON desired_parent.account_id = d.account_id
           AND desired_parent.id = d.desired_parent_task_id
          LEFT JOIN task_list_remote_bases list_base
            ON list_base.account_id = d.account_id
           AND list_base.task_list_id = d.target_task_list_id
          LEFT JOIN task_remote_bases task_base
            ON task_base.account_id = d.account_id
           AND task_base.task_id = d.target_task_id
          WHERE d.account_id = ?1
            AND d.desired_lifecycle = 'present'
            AND d.state = 'pending'
            AND d.content_dirty = 1
            AND d.structure_dirty = 0
            AND d.lifecycle_dirty = 0
            AND d.base_remote_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1
              FROM desired_state_attempts unresolved_attempt
              WHERE unresolved_attempt.account_id = d.account_id
                AND unresolved_attempt.desired_state_id = d.id
                AND unresolved_attempt.state IN ('in_flight', 'uncertain')
                AND unresolved_attempt.base_remote_id IS NOT NULL
            )
            AND (
              (d.resource_type = 'task'
                AND target_task.remote_id = d.base_remote_id
                AND desired_list.remote_id IS NOT NULL
                AND task_base.remote_id = d.base_remote_id
                AND task_base.deleted = 0
                AND task_base.observed_publication_id = ?2
                AND d.base_etag IS NOT NULL
                AND task_base.etag = d.base_etag
                AND task_base.task_list_id = d.desired_task_list_id
                AND task_base.parent_task_id IS d.desired_parent_task_id
                AND EXISTS (
                  SELECT 1
                  FROM scope_completeness task_scope
                  WHERE task_scope.account_id = d.account_id
                    AND task_scope.scope_kind = 'tasks'
                    AND task_scope.task_list_id = d.desired_task_list_id
                    AND task_scope.publication_id = ?2
                    AND task_scope.is_complete = 1
                )
                AND NOT (
                  task_base.title = d.title
                  AND task_base.notes IS d.notes
                  AND task_base.status = d.status
                  AND task_base.due_epoch_day IS d.due_epoch_day
                ))
              OR
              (d.resource_type = 'task_list'
                AND target_list.remote_id = d.base_remote_id
                AND list_base.remote_id = d.base_remote_id
                AND list_base.deleted = 0
                AND list_base.observed_publication_id = ?2
                AND d.base_etag IS NOT NULL
                AND list_base.etag = d.base_etag
                AND list_base.title <> d.title
                AND EXISTS (
                  SELECT 1
                  FROM scope_completeness list_scope
                  WHERE list_scope.account_id = d.account_id
                    AND list_scope.scope_kind = 'task_lists'
                    AND list_scope.publication_id = ?2
                    AND list_scope.is_complete = 1
                ))
            )
          ORDER BY
            CASE WHEN d.resource_type = 'task' THEN 0 ELSE 1 END,
            d.local_causal_sequence,
            d.id
          LIMIT 1
          ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<String>(runId),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.desiredStateRows,
            _database.taskListCacheRows,
            _database.taskCacheRows,
            _database.taskListRemoteBases,
            _database.taskRemoteBases,
            _database.scopeCompletenessRows,
            _database.desiredStateAttemptRows,
          },
        )
        .getSingleOrNull();
    if (row == null) return null;
    if (row.read<String>('resource_type') == 'task_list') {
      return DesiredUpdateCandidate(
        resourceType: DesiredUpdateResourceType.taskList,
        taskListId: TaskListId(row.read<int>('target_task_list_id')),
        taskListRemoteId: TaskListRemoteId(
          row.read<String>('target_list_remote_id'),
        ),
        taskId: null,
        taskRemoteId: null,
        parentTaskId: null,
        parentRemoteId: null,
        etag: null,
      );
    }
    final parentTaskId = row.readNullable<int>('desired_parent_task_id');
    final parentRemoteId = row.readNullable<String>('desired_parent_remote_id');
    return DesiredUpdateCandidate(
      resourceType: DesiredUpdateResourceType.task,
      taskListId: TaskListId(row.read<int>('desired_task_list_id')),
      taskListRemoteId: TaskListRemoteId(
        row.read<String>('desired_list_remote_id'),
      ),
      taskId: TaskId(row.read<int>('target_task_id')),
      taskRemoteId: TaskRemoteId(row.read<String>('target_task_remote_id')),
      parentTaskId: parentTaskId == null ? null : TaskId(parentTaskId),
      parentRemoteId: parentRemoteId == null
          ? null
          : TaskRemoteId(parentRemoteId),
      etag: row.read<String>('task_etag'),
    );
  }

  Future<ContentReconciliationSummary> reconcileContent({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  }) {
    return _database.transaction(() async {
      var confirmedReadBacks = 0;
      var localWritesPending = 0;
      var googleWonTaskContents = 0;
      var googleWonListTitles = 0;
      Failure? failure;
      final desiredRows =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.desiredLifecycle.equals('present') &
                    row.contentDirty.equals(true) &
                    row.baseRemoteId.isNotNull() &
                    row.state.isIn(const <String>['pending', 'uncertain']),
              ))
              .get();

      for (final desired in desiredRows) {
        if (desired.resourceType == 'task') {
          final taskId = desired.targetTaskId;
          if (taskId == null ||
              desired.baseTitle == null ||
              desired.baseStatus == null ||
              desired.title == null ||
              desired.status == null) {
            failure ??= _invalidConflictBaseFailure;
            continue;
          }
          final current =
              await (_database.select(_database.taskRemoteBases)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.taskId.equals(taskId) &
                        row.deleted.equals(false) &
                        row.observedPublicationId.equals(runId),
                  ))
                  .getSingleOrNull();
          if (current == null ||
              current.title == null ||
              current.status == null ||
              !await _taskScopeComplete(
                accountId,
                TaskListId(current.taskListId),
                runId,
              )) {
            continue;
          }
          final base = TaskContentSnapshot(
            title: desired.baseTitle!,
            notes: desired.baseNotes,
            status: _status(desired.baseStatus),
            due: _taskDate(desired.baseDueEpochDay),
          );
          final local = TaskContentSnapshot(
            title: desired.title!,
            notes: desired.notes,
            status: _status(desired.status),
            due: _taskDate(desired.dueEpochDay),
          );
          final remote = TaskContentSnapshot(
            title: current.title!,
            notes: current.notes,
            status: _status(current.status),
            due: _taskDate(current.dueEpochDay),
          );
          final result = reconcileWholeRecord(
            base: base,
            local: local,
            remote: remote,
            localModifiedAt: desired.localModifiedAt?.toUtc(),
            remoteModifiedAt: current.remoteUpdatedAt?.toUtc(),
          );
          switch (result) {
            case WholeRecordConflictEvidenceFailure<TaskContentSnapshot>():
              failure ??= _invalidConflictTimestampFailure;
            case WholeRecordResolution<TaskContentSnapshot>(
              winner: WholeRecordWinner.local,
            ):
              await _rebaseDesiredTask(
                desired: desired,
                current: current,
                state: DesiredStateLifecycle.pending,
                transitionedAt: reconciledAt,
                updateProjection: false,
              );
              await _resolvePriorAttempts(
                desired,
                DesiredStateLifecycle.superseded,
                reconciledAt,
              );
              localWritesPending += 1;
            case WholeRecordResolution<TaskContentSnapshot>(
              winner: WholeRecordWinner.confirmed,
            ):
              await _rebaseDesiredTask(
                desired: desired,
                current: current,
                state: DesiredStateLifecycle.confirmed,
                transitionedAt: reconciledAt,
                updateProjection: true,
              );
              await _resolvePriorAttempts(
                desired,
                DesiredStateLifecycle.confirmed,
                reconciledAt,
              );
              confirmedReadBacks += 1;
            case WholeRecordResolution<TaskContentSnapshot>(
              winner: WholeRecordWinner.google,
            ):
              await _rebaseDesiredTask(
                desired: desired,
                current: current,
                state: DesiredStateLifecycle.superseded,
                transitionedAt: reconciledAt,
                updateProjection: true,
              );
              await _resolvePriorAttempts(
                desired,
                DesiredStateLifecycle.superseded,
                reconciledAt,
              );
              googleWonTaskContents += 1;
          }
          continue;
        }

        if (desired.resourceType != 'task_list' ||
            desired.targetTaskListId == null ||
            desired.baseTitle == null ||
            desired.title == null) {
          failure ??= _invalidConflictBaseFailure;
          continue;
        }
        final current =
            await (_database.select(_database.taskListRemoteBases)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskListId.equals(desired.targetTaskListId!) &
                      row.deleted.equals(false) &
                      row.observedPublicationId.equals(runId),
                ))
                .getSingleOrNull();
        if (current == null || !await _listScopeComplete(accountId, runId)) {
          continue;
        }
        final result = reconcileWholeRecord(
          base: TaskListTitleSnapshot(desired.baseTitle!),
          local: TaskListTitleSnapshot(desired.title!),
          remote: TaskListTitleSnapshot(current.title),
          localModifiedAt: desired.localModifiedAt?.toUtc(),
          remoteModifiedAt: current.remoteUpdatedAt?.toUtc(),
        );
        switch (result) {
          case WholeRecordConflictEvidenceFailure<TaskListTitleSnapshot>():
            failure ??= _invalidConflictTimestampFailure;
          case WholeRecordResolution<TaskListTitleSnapshot>(
            winner: WholeRecordWinner.local,
          ):
            await _rebaseDesiredTaskList(
              desired: desired,
              current: current,
              state: DesiredStateLifecycle.pending,
              transitionedAt: reconciledAt,
              updateProjection: false,
            );
            await _resolvePriorAttempts(
              desired,
              DesiredStateLifecycle.superseded,
              reconciledAt,
            );
            localWritesPending += 1;
          case WholeRecordResolution<TaskListTitleSnapshot>(
            winner: WholeRecordWinner.confirmed,
          ):
            await _rebaseDesiredTaskList(
              desired: desired,
              current: current,
              state: DesiredStateLifecycle.confirmed,
              transitionedAt: reconciledAt,
              updateProjection: true,
            );
            await _resolvePriorAttempts(
              desired,
              DesiredStateLifecycle.confirmed,
              reconciledAt,
            );
            confirmedReadBacks += 1;
          case WholeRecordResolution<TaskListTitleSnapshot>(
            winner: WholeRecordWinner.google,
          ):
            await _rebaseDesiredTaskList(
              desired: desired,
              current: current,
              state: DesiredStateLifecycle.superseded,
              transitionedAt: reconciledAt,
              updateProjection: true,
            );
            await _resolvePriorAttempts(
              desired,
              DesiredStateLifecycle.superseded,
              reconciledAt,
            );
            googleWonListTitles += 1;
        }
      }
      await _recomputeCounts(accountId);
      return ContentReconciliationSummary(
        confirmedReadBacks: confirmedReadBacks,
        localWritesPending: localWritesPending,
        supersessions: <ContentSupersessionResult>[
          if (googleWonTaskContents > 0)
            ContentSupersessionResult(
              kind: ContentSupersessionKind.taskContent,
              count: googleWonTaskContents,
            ),
          if (googleWonListTitles > 0)
            ContentSupersessionResult(
              kind: ContentSupersessionKind.taskListTitle,
              count: googleWonListTitles,
            ),
        ],
        failure: failure,
      );
    });
  }

  Future<void> prepareTaskUpdateReplan({
    required AccountId accountId,
    required int attemptId,
    required int generation,
    required DateTime replannedAt,
  }) {
    return _database.transaction(() async {
      final attempt =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attemptId) &
                    row.generation.equals(generation) &
                    row.state.equals('in_flight'),
              ))
              .getSingleOrNull();
      if (attempt == null) {
        throw const DesiredStateInvariantException(
          'conditional_attempt_not_replannable',
        );
      }
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attempt.id))).write(
        DesiredStateAttemptRowsCompanion(
          state: const Value<String>('superseded'),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(replannedAt.toUtc()),
        ),
      );
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(attempt.desiredStateId) &
                row.generation.equals(generation),
          ))
          .write(
            DesiredStateRowsCompanion(
              state: const Value<String>('pending'),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(replannedAt.toUtc()),
            ),
          );
      await _recomputeCounts(accountId);
    });
  }

  Future<int> confirmNoOpUpdates({
    required AccountId accountId,
    required String runId,
    required DateTime confirmedAt,
  }) {
    return _database.transaction(() async {
      final rows = await _database
          .customSelect(
            '''
        SELECT
          d.id,
          d.resource_type,
          COALESCE(task_base.etag, list_base.etag) AS current_etag,
          COALESCE(
            task_base.remote_updated_at,
            list_base.remote_updated_at
          ) AS current_updated_at,
          COALESCE(
            task_base.observed_publication_id,
            list_base.observed_publication_id
          ) AS current_publication_id,
          COALESCE(task_base.title, list_base.title) AS current_title
          ,task_base.notes AS current_notes
          ,task_base.status AS current_status
          ,task_base.due_epoch_day AS current_due_epoch_day
        FROM desired_states d
        LEFT JOIN task_list_remote_bases list_base
          ON list_base.account_id = d.account_id
         AND list_base.task_list_id = d.target_task_list_id
        LEFT JOIN task_remote_bases task_base
          ON task_base.account_id = d.account_id
         AND task_base.task_id = d.target_task_id
        WHERE d.account_id = ?1
          AND d.desired_lifecycle = 'present'
          AND d.state = 'pending'
          AND d.content_dirty = 1
          AND d.structure_dirty = 0
          AND d.lifecycle_dirty = 0
          AND d.base_remote_id IS NOT NULL
          AND (
            (d.resource_type = 'task'
              AND task_base.remote_id = d.base_remote_id
              AND task_base.deleted = 0
              AND task_base.observed_publication_id = ?2
              AND task_base.task_list_id = d.desired_task_list_id
              AND task_base.parent_task_id IS d.desired_parent_task_id
              AND task_base.title = d.title
              AND task_base.notes IS d.notes
              AND task_base.status = d.status
              AND task_base.due_epoch_day IS d.due_epoch_day
              AND EXISTS (
                SELECT 1
                FROM scope_completeness task_scope
                WHERE task_scope.account_id = d.account_id
                  AND task_scope.scope_kind = 'tasks'
                  AND task_scope.task_list_id = d.desired_task_list_id
                  AND task_scope.publication_id = ?2
                  AND task_scope.is_complete = 1
              ))
            OR
            (d.resource_type = 'task_list'
              AND list_base.remote_id = d.base_remote_id
              AND list_base.deleted = 0
              AND list_base.observed_publication_id = ?2
              AND list_base.title = d.title
              AND EXISTS (
                SELECT 1
                FROM scope_completeness list_scope
                WHERE list_scope.account_id = d.account_id
                  AND list_scope.scope_kind = 'task_lists'
                  AND list_scope.publication_id = ?2
                  AND list_scope.is_complete = 1
              ))
          )
        ''',
            variables: <Variable<Object>>[
              Variable<int>(accountId.value),
              Variable<String>(runId),
            ],
            readsFrom: <ResultSetImplementation<Table, Object?>>{
              _database.desiredStateRows,
              _database.taskListRemoteBases,
              _database.taskRemoteBases,
              _database.scopeCompletenessRows,
            },
          )
          .get();
      for (final row in rows) {
        await (_database.update(_database.desiredStateRows)..where(
              (candidate) =>
                  candidate.accountId.equals(accountId.value) &
                  candidate.id.equals(row.read<int>('id')) &
                  candidate.state.equals('pending'),
            ))
            .write(
              DesiredStateRowsCompanion(
                baseEtag: Value<String?>(
                  row.readNullable<String>('current_etag'),
                ),
                baseRemoteUpdatedAt: Value<DateTime?>(
                  row.readNullable<DateTime>('current_updated_at')?.toUtc(),
                ),
                baseObservedPublicationId: Value<String>(
                  row.read<String>('current_publication_id'),
                ),
                baseTitle: Value<String?>(
                  row.readNullable<String>('current_title'),
                ),
                baseNotes: row.read<String>('resource_type') == 'task'
                    ? Value<String?>(row.readNullable<String>('current_notes'))
                    : const Value<String?>.absent(),
                baseStatus: row.read<String>('resource_type') == 'task'
                    ? Value<String?>(row.readNullable<String>('current_status'))
                    : const Value<String?>.absent(),
                baseDueEpochDay: row.read<String>('resource_type') == 'task'
                    ? Value<int?>(
                        row.readNullable<int>('current_due_epoch_day'),
                      )
                    : const Value<int?>.absent(),
                state: const Value<String>('confirmed'),
                failureCode: const Value<String?>(null),
                lastTransitionAt: Value<DateTime>(confirmedAt.toUtc()),
              ),
            );
      }
      await _recomputeCounts(accountId);
      return rows.length;
    });
  }

  Future<int> recoverInFlightCreates({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) {
    return _database.transaction(() async {
      final accountExists = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
      if (accountExists == null) return 0;
      final attempts =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.state.equals('in_flight') &
                    row.baseRemoteId.isNull(),
              ))
              .get();
      for (final attempt in attempts) {
        await (_database.update(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(attempt.id))).write(
          DesiredStateAttemptRowsCompanion(
            state: const Value<String>('uncertain'),
            failureCode: const Value<String>('sync.create_interrupted'),
            lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
          ),
        );
        await (_database.update(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(attempt.desiredStateId) &
                  row.generation.equals(attempt.generation),
            ))
            .write(
              DesiredStateRowsCompanion(
                state: const Value<String>('uncertain'),
                failureCode: const Value<String>('sync.create_interrupted'),
                lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
              ),
            );
      }
      await _recomputeCounts(accountId);
      return attempts.length;
    });
  }

  Future<List<int>> readRecoverableCreateAttemptIds(AccountId accountId) async {
    final rows = await _database
        .customSelect(
          '''
      SELECT a.id
      FROM desired_state_attempts a
      JOIN desired_states d
        ON d.account_id = a.account_id
       AND d.id = a.desired_state_id
      LEFT JOIN task_lists target_list
        ON target_list.account_id = d.account_id
       AND target_list.id = d.target_task_list_id
      LEFT JOIN tasks target_task
        ON target_task.account_id = d.account_id
       AND target_task.id = d.target_task_id
      WHERE a.account_id = ?1
        AND a.base_remote_id IS NULL
        AND a.state IN ('pending', 'uncertain')
        AND ((d.resource_type = 'task_list' AND target_list.remote_id IS NULL)
          OR (d.resource_type = 'task' AND target_task.remote_id IS NULL))
        AND EXISTS (
          SELECT 1
          FROM desired_state_attempts uncertain
          WHERE uncertain.account_id = a.account_id
            AND uncertain.desired_state_id = a.desired_state_id
            AND uncertain.generation = a.generation
            AND uncertain.base_remote_id IS NULL
            AND uncertain.state = 'uncertain'
        )
        AND NOT EXISTS (
          SELECT 1
          FROM desired_state_attempts newer
          WHERE newer.account_id = a.account_id
            AND newer.desired_state_id = a.desired_state_id
            AND newer.generation = a.generation
            AND newer.id > a.id
        )
      ORDER BY
        CASE
          WHEN d.resource_type = 'task_list' THEN 0
          WHEN a.desired_parent_task_id IS NULL THEN 1
          ELSE 2
        END,
        d.local_causal_sequence,
        a.id
      ''',
          variables: <Variable<Object>>[Variable<int>(accountId.value)],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.desiredStateAttemptRows,
            _database.desiredStateRows,
            _database.taskListCacheRows,
            _database.taskCacheRows,
          },
        )
        .get();
    return rows.map((row) => row.read<int>('id')).toList(growable: false);
  }

  Future<DesiredCreateRecoveryRecord?> claimCreateRecovery({
    required AccountId accountId,
    required int sourceAttemptId,
    required String runId,
    required DateTime claimedAt,
  }) {
    return _database.transaction(() async {
      final source =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(sourceAttemptId) &
                    row.baseRemoteId.isNull() &
                    row.state.isIn(const <String>['pending', 'uncertain']),
              ))
              .getSingleOrNull();
      if (source == null) return null;
      final newer =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.desiredStateId.equals(source.desiredStateId) &
                    row.generation.equals(source.generation) &
                    row.id.isBiggerThanValue(source.id),
              ))
              .getSingleOrNull();
      if (newer != null) return null;
      final uncertainCountExpression = _database.desiredStateAttemptRows.id
          .count();
      final uncertainCountQuery =
          _database.selectOnly(_database.desiredStateAttemptRows)
            ..addColumns(<Expression<Object>>[uncertainCountExpression])
            ..where(
              _database.desiredStateAttemptRows.accountId.equals(
                    accountId.value,
                  ) &
                  _database.desiredStateAttemptRows.desiredStateId.equals(
                    source.desiredStateId,
                  ) &
                  _database.desiredStateAttemptRows.generation.equals(
                    source.generation,
                  ) &
                  _database.desiredStateAttemptRows.state.equals('uncertain'),
            );
      final uncertainCount =
          (await uncertainCountQuery.getSingle()).read(
            uncertainCountExpression,
          ) ??
          0;
      if (uncertainCount == 0) return null;

      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(source.desiredStateId),
              ))
              .getSingleOrNull();
      if (desired == null) return null;

      late final DesiredCreateCandidate candidate;
      if (desired.resourceType == 'task_list') {
        final taskListId = desired.targetTaskListId;
        if (taskListId == null || !await _listScopeComplete(accountId, runId)) {
          return null;
        }
        final target =
            await (_database.select(_database.taskListCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.id.equals(taskListId),
                ))
                .getSingleOrNull();
        if (target == null || target.remoteId != null) return null;
        candidate = DesiredCreateCandidate(
          resourceType: DesiredCreateResourceType.taskList,
          taskListId: TaskListId(taskListId),
          taskId: null,
          parentTaskId: null,
          taskListRemoteId: null,
          parentRemoteId: null,
          previousTaskId: null,
          previousRemoteId: null,
        );
      } else if (desired.resourceType == 'task') {
        final taskId = desired.targetTaskId;
        final taskListId = source.desiredTaskListId;
        if (taskId == null || taskListId == null) return null;
        final target =
            await (_database.select(_database.taskCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.id.equals(taskId),
                ))
                .getSingleOrNull();
        final taskList =
            await (_database.select(_database.taskListCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.id.equals(taskListId),
                ))
                .getSingleOrNull();
        final taskListRemoteId = taskList?.remoteId;
        if (target == null ||
            target.remoteId != null ||
            taskListRemoteId == null) {
          return null;
        }
        final scopeComplete = await _taskScopeComplete(
          accountId,
          TaskListId(taskListId),
          runId,
        );
        final listCreatedThisRun =
            await (_database.select(_database.taskListRemoteBases)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskListId.equals(taskListId) &
                      row.observedPublicationId.like('mutation:$runId:%'),
                ))
                .getSingleOrNull() !=
            null;
        if (!scopeComplete && !listCreatedThisRun) return null;

        TaskRemoteId? parentRemoteId;
        if (source.desiredParentTaskId case final parentId?) {
          final parent =
              await (_database.select(_database.taskCacheRows)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.id.equals(parentId),
                  ))
                  .getSingleOrNull();
          if (parent?.remoteId == null) return null;
          parentRemoteId = TaskRemoteId(parent!.remoteId!);
        }
        TaskRemoteId? previousRemoteId;
        if (source.desiredPreviousTaskId case final previousId?) {
          final previous =
              await (_database.select(_database.taskCacheRows)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.id.equals(previousId),
                  ))
                  .getSingleOrNull();
          if (previous?.remoteId == null) return null;
          previousRemoteId = TaskRemoteId(previous!.remoteId!);
        }
        candidate = DesiredCreateCandidate(
          resourceType: DesiredCreateResourceType.task,
          taskListId: TaskListId(taskListId),
          taskId: TaskId(taskId),
          parentTaskId: source.desiredParentTaskId == null
              ? null
              : TaskId(source.desiredParentTaskId!),
          taskListRemoteId: TaskListRemoteId(taskListRemoteId),
          parentRemoteId: parentRemoteId,
          previousTaskId: source.desiredPreviousTaskId == null
              ? null
              : TaskId(source.desiredPreviousTaskId!),
          previousRemoteId: previousRemoteId,
        );
      } else {
        throw const DesiredStateInvariantException('unknown_resource_type');
      }

      if (source.state == 'pending') {
        await (_database.update(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(source.id))).write(
          DesiredStateAttemptRowsCompanion(
            state: const Value<String>('superseded'),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(claimedAt.toUtc()),
          ),
        );
      }
      final recoveryAttemptId = await _database
          .into(_database.desiredStateAttemptRows)
          .insert(
            DesiredStateAttemptRowsCompanion.insert(
              accountId: source.accountId,
              desiredStateId: source.desiredStateId,
              generation: source.generation,
              desiredLifecycle: source.desiredLifecycle,
              title: Value<String?>(source.title),
              notes: Value<String?>(source.notes),
              status: Value<String?>(source.status),
              dueEpochDay: Value<int?>(source.dueEpochDay),
              desiredTaskListId: Value<int?>(source.desiredTaskListId),
              desiredParentTaskId: Value<int?>(source.desiredParentTaskId),
              desiredPreviousTaskId: Value<int?>(source.desiredPreviousTaskId),
              baseRemoteId: const Value<String?>(null),
              baseEtag: Value<String?>(source.baseEtag),
              baseRemoteUpdatedAt: Value<DateTime?>(source.baseRemoteUpdatedAt),
              baseObservedPublicationId: Value<String?>(
                source.baseObservedPublicationId,
              ),
              baseTitle: Value<String?>(source.baseTitle),
              baseTaskListId: Value<int?>(source.baseTaskListId),
              baseParentTaskId: Value<int?>(source.baseParentTaskId),
              basePreviousTaskId: Value<int?>(source.basePreviousTaskId),
              basePosition: Value<String?>(source.basePosition),
              baseSiblingOrder: Value<String?>(source.baseSiblingOrder),
              notBefore: Value<DateTime?>(source.notBefore),
              state: 'in_flight',
              claimedAt: claimedAt.toUtc(),
              lastTransitionAt: claimedAt.toUtc(),
            ),
          );
      if (desired.generation == source.generation) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            state: const Value<String>('in_flight'),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(claimedAt.toUtc()),
          ),
        );
      }
      await _recomputeCounts(accountId);
      final attempt = await (_database.select(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(recoveryAttemptId))).getSingle();
      return DesiredCreateRecoveryRecord(
        attempt: _mapAttempt(attempt),
        candidate: candidate,
        uncertainAttemptCount: uncertainCount,
      );
    });
  }

  Future<int> recoverInFlightUpdates({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) {
    return _database.transaction(() async {
      final accountExists = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
      if (accountExists == null) return 0;
      final attempts =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.state.equals('in_flight') &
                    row.desiredLifecycle.equals('present') &
                    row.baseRemoteId.isNotNull(),
              ))
              .get();
      for (final attempt in attempts) {
        await (_database.update(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(attempt.id))).write(
          DesiredStateAttemptRowsCompanion(
            state: const Value<String>('uncertain'),
            failureCode: const Value<String>('sync.update_interrupted'),
            lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
          ),
        );
        await (_database.update(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(attempt.desiredStateId) &
                  row.generation.equals(attempt.generation),
            ))
            .write(
              DesiredStateRowsCompanion(
                state: const Value<String>('uncertain'),
                failureCode: const Value<String>('sync.update_interrupted'),
                lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
              ),
            );
      }
      await _recomputeCounts(accountId);
      return attempts.length;
    });
  }

  Future<UncertainMutationResolutionSummary> resolveOlderUncertainUpdates({
    required AccountId accountId,
    required String runId,
    required DateTime resolvedAt,
  }) {
    return _database.transaction(() async {
      var confirmed = 0;
      var superseded = 0;
      final attempts = await _database
          .customSelect(
            '''
        SELECT a.id AS attempt_id, a.desired_state_id,
               a.title AS attempt_title, a.notes AS attempt_notes,
               a.status AS attempt_status,
               a.due_epoch_day AS attempt_due_epoch_day,
               a.desired_task_list_id AS attempt_list_id,
               a.desired_parent_task_id AS attempt_parent_id,
               a.desired_previous_task_id AS attempt_previous_id,
               a.base_task_list_id AS attempt_base_list_id,
               a.base_parent_task_id AS attempt_base_parent_id,
               a.base_previous_task_id AS attempt_base_previous_id,
               d.resource_type, d.target_task_list_id, d.target_task_id
        FROM desired_state_attempts a
        JOIN desired_states d
          ON d.account_id = a.account_id AND d.id = a.desired_state_id
        WHERE a.account_id = ?1
          AND a.state = 'uncertain'
          AND a.desired_lifecycle = 'present'
          AND a.base_remote_id IS NOT NULL
          AND a.generation < d.generation
        ORDER BY a.id
        ''',
            variables: <Variable<Object>>[Variable<int>(accountId.value)],
            readsFrom: <ResultSetImplementation<Table, Object?>>{
              _database.desiredStateAttemptRows,
              _database.desiredStateRows,
            },
          )
          .get();
      final transitionedAt = resolvedAt.toUtc();
      for (final attempt in attempts) {
        final isMove =
            attempt.read<String>('resource_type') == 'task' &&
            attempt.readNullable<int>('attempt_base_list_id') != null &&
            (attempt.readNullable<int>('attempt_list_id') !=
                    attempt.readNullable<int>('attempt_base_list_id') ||
                attempt.readNullable<int>('attempt_parent_id') !=
                    attempt.readNullable<int>('attempt_base_parent_id') ||
                attempt.readNullable<int>('attempt_previous_id') !=
                    attempt.readNullable<int>('attempt_base_previous_id'));
        if (isMove) continue;
        final desired =
            await (_database.select(_database.desiredStateRows)..where(
                  (row) => row.id.equals(attempt.read<int>('desired_state_id')),
                ))
                .getSingle();
        if (desired.desiredLifecycle == 'deleted') {
          await _resolveAttemptRow(
            attempt.read<int>('attempt_id'),
            'superseded',
            transitionedAt,
          );
          superseded += 1;
          continue;
        }
        if (desired.resourceType == 'task_list') {
          final current =
              await (_database.select(_database.taskListRemoteBases)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.taskListId.equals(desired.targetTaskListId!) &
                        row.deleted.equals(false) &
                        row.observedPublicationId.equals(runId),
                  ))
                  .getSingleOrNull();
          if (current == null) continue;
          final exact = current.title == attempt.read<String>('attempt_title');
          await _resolveAttemptRow(
            attempt.read<int>('attempt_id'),
            exact ? 'confirmed' : 'superseded',
            transitionedAt,
          );
          if (!exact) {
            superseded += 1;
            continue;
          }
          final contentDirty = desired.title != current.title;
          await (_database.update(
            _database.desiredStateRows,
          )..where((row) => row.id.equals(desired.id))).write(
            DesiredStateRowsCompanion(
              contentDirty: Value<bool>(contentDirty),
              baseRemoteId: Value<String>(current.remoteId),
              baseEtag: Value<String?>(current.etag),
              baseRemoteUpdatedAt: Value<DateTime?>(
                current.remoteUpdatedAt?.toUtc(),
              ),
              baseObservedPublicationId: Value<String>(runId),
              baseTitle: Value<String>(current.title),
              state: Value<String>(
                contentDirty || desired.lifecycleDirty
                    ? 'pending'
                    : 'confirmed',
              ),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(transitionedAt),
            ),
          );
          confirmed += 1;
          continue;
        }
        final current =
            await (_database.select(_database.taskRemoteBases)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskId.equals(desired.targetTaskId!) &
                      row.deleted.equals(false) &
                      row.observedPublicationId.equals(runId),
                ))
                .getSingleOrNull();
        if (current == null) continue;
        final exact =
            current.title == attempt.read<String>('attempt_title') &&
            current.notes == attempt.readNullable<String>('attempt_notes') &&
            current.status == attempt.read<String>('attempt_status') &&
            current.dueEpochDay ==
                attempt.readNullable<int>('attempt_due_epoch_day');
        await _resolveAttemptRow(
          attempt.read<int>('attempt_id'),
          exact ? 'confirmed' : 'superseded',
          transitionedAt,
        );
        if (!exact) {
          superseded += 1;
          continue;
        }
        final contentDirty =
            desired.title != current.title ||
            desired.notes != current.notes ||
            desired.status != current.status ||
            desired.dueEpochDay != current.dueEpochDay;
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            contentDirty: Value<bool>(contentDirty),
            baseRemoteId: Value<String>(current.remoteId),
            baseEtag: Value<String?>(current.etag),
            baseRemoteUpdatedAt: Value<DateTime?>(
              current.remoteUpdatedAt?.toUtc(),
            ),
            baseObservedPublicationId: Value<String>(runId),
            baseTitle: Value<String>(current.title!),
            baseNotes: Value<String?>(current.notes),
            baseStatus: Value<String>(current.status!),
            baseDueEpochDay: Value<int?>(current.dueEpochDay),
            state: Value<String>(
              contentDirty || desired.structureDirty || desired.lifecycleDirty
                  ? 'pending'
                  : 'confirmed',
            ),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(transitionedAt),
          ),
        );
        confirmed += 1;
      }
      await _recomputeCounts(accountId);
      return UncertainMutationResolutionSummary(
        confirmed: confirmed,
        superseded: superseded,
      );
    });
  }

  Future<void> _resolveAttemptRow(
    int attemptId,
    String state,
    DateTime transitionedAt,
  ) =>
      (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attemptId))).write(
        DesiredStateAttemptRowsCompanion(
          state: Value<String>(state),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(transitionedAt),
        ),
      );

  Future<int> recoverInFlightDeletes({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) {
    return _database.transaction(() async {
      final accountExists = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
      if (accountExists == null) return 0;
      final attempts =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.state.equals('in_flight') &
                    row.desiredLifecycle.equals('deleted'),
              ))
              .get();
      for (final attempt in attempts) {
        await (_database.update(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(attempt.id))).write(
          DesiredStateAttemptRowsCompanion(
            state: const Value<String>('uncertain'),
            failureCode: const Value<String>('sync.delete_interrupted'),
            lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
          ),
        );
        await (_database.update(_database.desiredStateRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(attempt.desiredStateId) &
                  row.generation.equals(attempt.generation),
            ))
            .write(
              DesiredStateRowsCompanion(
                state: const Value<String>('uncertain'),
                failureCode: const Value<String>('sync.delete_interrupted'),
                lastTransitionAt: Value<DateTime>(recoveredAt.toUtc()),
              ),
            );
      }
      await _recomputeCounts(accountId);
      return attempts.length;
    });
  }

  Future<TaskListDesiredStateRecord> writeTaskListPresent({
    required AccountId accountId,
    required TaskListId taskListId,
    required String title,
    required DateTime modifiedAt,
  }) async {
    final existing = await _taskListQuery(
      accountId,
      taskListId,
    ).getSingleOrNull();
    final sequence = await _nextCausalSequence(accountId);
    if (existing == null) {
      final base =
          await (_database.select(_database.taskListRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskListId.equals(taskListId.value),
              ))
              .getSingleOrNull();
      await _database
          .into(_database.desiredStateRows)
          .insert(
            DesiredStateRowsCompanion.insert(
              accountId: accountId.value,
              targetKey: 'task_list:${taskListId.value}',
              resourceType: 'task_list',
              targetTaskListId: Value<int>(taskListId.value),
              targetTaskId: const Value<int?>.absent(),
              desiredLifecycle: 'present',
              title: Value<String>(title),
              contentDirty: const Value<bool>(true),
              generation: 1,
              localCausalSequence: sequence,
              state: _stateValue(DesiredStateLifecycle.pending),
              baseRemoteId: Value<String?>(base?.remoteId),
              baseEtag: Value<String?>(base?.etag),
              baseRemoteUpdatedAt: Value<DateTime?>(base?.remoteUpdatedAt),
              baseObservedPublicationId: Value<String?>(
                base?.observedPublicationId,
              ),
              baseTitle: Value<String?>(base?.title),
              localModifiedAt: Value<DateTime>(modifiedAt.toUtc()),
              createdAt: modifiedAt.toUtc(),
              lastTransitionAt: modifiedAt.toUtc(),
            ),
          );
    } else {
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(existing.id),
          ))
          .write(
            DesiredStateRowsCompanion(
              desiredLifecycle: const Value<String>('present'),
              title: Value<String>(title),
              contentDirty: const Value<bool>(true),
              generation: Value<int>(existing.generation + 1),
              localCausalSequence: Value<int>(sequence),
              state: Value<String>(_stateValue(DesiredStateLifecycle.pending)),
              failureCode: const Value<String?>(null),
              localModifiedAt: Value<DateTime>(modifiedAt.toUtc()),
              lastTransitionAt: Value<DateTime>(modifiedAt.toUtc()),
            ),
          );
    }
    await _recomputeCounts(accountId);
    final stored = await _taskListQuery(accountId, taskListId).getSingle();
    return _mapTaskList(stored);
  }

  Future<TaskDesiredStateRecord> writeTaskPresent({
    required AccountId accountId,
    required TaskId taskId,
    required TaskListId taskListId,
    required TaskId? parentTaskId,
    TaskId? previousTaskId,
    required String title,
    required String? notes,
    required TaskStatus status,
    required TaskDate? due,
    required DateTime modifiedAt,
  }) async {
    final existing = await _taskQuery(accountId, taskId).getSingleOrNull();
    final sequence = await _nextCausalSequence(accountId);
    if (existing == null) {
      final base =
          await (_database.select(_database.taskRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskId.equals(taskId.value),
              ))
              .getSingleOrNull();
      final id = await _database
          .into(_database.desiredStateRows)
          .insert(
            DesiredStateRowsCompanion.insert(
              accountId: accountId.value,
              targetKey: 'task:${taskId.value}',
              resourceType: 'task',
              targetTaskListId: const Value<int?>.absent(),
              targetTaskId: Value<int>(taskId.value),
              desiredLifecycle: 'present',
              title: Value<String>(title),
              notes: Value<String?>(notes),
              status: Value<String>(_statusValue(status)),
              dueEpochDay: Value<int?>(_epochDay(due)),
              desiredTaskListId: Value<int>(taskListId.value),
              desiredParentTaskId: Value<int?>(parentTaskId?.value),
              desiredPreviousTaskId: Value<int?>(previousTaskId?.value),
              contentDirty: const Value<bool>(true),
              structureDirty: Value<bool>(base == null),
              generation: 1,
              localCausalSequence: sequence,
              state: _stateValue(DesiredStateLifecycle.pending),
              baseRemoteId: Value<String?>(base?.remoteId),
              baseEtag: Value<String?>(base?.etag),
              baseRemoteUpdatedAt: Value<DateTime?>(base?.remoteUpdatedAt),
              baseObservedPublicationId: Value<String?>(
                base?.observedPublicationId,
              ),
              baseTitle: Value<String?>(base?.title),
              baseNotes: Value<String?>(base?.notes),
              baseStatus: Value<String?>(base?.status),
              baseDueEpochDay: Value<int?>(base?.dueEpochDay),
              localModifiedAt: Value<DateTime>(modifiedAt.toUtc()),
              createdAt: modifiedAt.toUtc(),
              lastTransitionAt: modifiedAt.toUtc(),
            ),
          );
      if (base == null) {
        await _database
            .into(_database.desiredStateDependencyRows)
            .insert(
              DesiredStateDependencyRowsCompanion.insert(
                accountId: accountId.value,
                desiredStateId: id,
                dependencyKind: 'task_list',
                dependsOnTaskListId: Value<int>(taskListId.value),
              ),
            );
        if (parentTaskId != null) {
          await _database
              .into(_database.desiredStateDependencyRows)
              .insert(
                DesiredStateDependencyRowsCompanion.insert(
                  accountId: accountId.value,
                  desiredStateId: id,
                  dependencyKind: 'parent_task',
                  dependsOnTaskId: Value<int>(parentTaskId.value),
                ),
              );
        }
        if (previousTaskId != null) {
          await _database
              .into(_database.desiredStateDependencyRows)
              .insert(
                DesiredStateDependencyRowsCompanion.insert(
                  accountId: accountId.value,
                  desiredStateId: id,
                  dependencyKind: 'previous_task',
                  dependsOnTaskId: Value<int>(previousTaskId.value),
                ),
              );
        }
      }
    } else {
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(existing.id),
          ))
          .write(
            DesiredStateRowsCompanion(
              desiredLifecycle: const Value<String>('present'),
              title: Value<String>(title),
              notes: Value<String?>(notes),
              status: Value<String>(_statusValue(status)),
              dueEpochDay: Value<int?>(_epochDay(due)),
              desiredTaskListId: Value<int>(taskListId.value),
              desiredParentTaskId: Value<int?>(parentTaskId?.value),
              contentDirty: const Value<bool>(true),
              generation: Value<int>(existing.generation + 1),
              localCausalSequence: Value<int>(sequence),
              state: Value<String>(_stateValue(DesiredStateLifecycle.pending)),
              failureCode: const Value<String?>(null),
              localModifiedAt: Value<DateTime>(modifiedAt.toUtc()),
              lastTransitionAt: Value<DateTime>(modifiedAt.toUtc()),
            ),
          );
    }
    await _recomputeCounts(accountId);
    return _mapTask(await _taskQuery(accountId, taskId).getSingle());
  }

  Future<TaskDesiredStateRecord> writeTaskStructure({
    required AccountId accountId,
    required TaskId taskId,
    required TaskListId taskListId,
    required TaskId? parentTaskId,
    required TaskId? previousTaskId,
    required String title,
    required String? notes,
    required TaskStatus status,
    required TaskDate? due,
    required DateTime modifiedAt,
  }) async {
    final existing = await _taskQuery(accountId, taskId).getSingleOrNull();
    final sequence = await _nextCausalSequence(accountId);
    TaskRemoteBase? newlyCapturedBase;
    _StoredStructureBase? newlyCapturedStructure;
    if (existing != null &&
        (!existing.structureDirty ||
            existing.state == 'confirmed' ||
            existing.state == 'superseded')) {
      newlyCapturedBase =
          await (_database.select(_database.taskRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskId.equals(taskId.value) &
                    row.deleted.equals(false),
              ))
              .getSingleOrNull();
      if (newlyCapturedBase == null) {
        throw const DesiredStateInvariantException(
          'structure_without_remote_base',
        );
      }
      newlyCapturedStructure = await _taskStructureBase(newlyCapturedBase);
    }
    final int desiredStateId;
    if (existing == null) {
      final base =
          await (_database.select(_database.taskRemoteBases)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.taskId.equals(taskId.value) &
                    row.deleted.equals(false),
              ))
              .getSingleOrNull();
      if (base == null) {
        throw const DesiredStateInvariantException(
          'structure_without_remote_base',
        );
      }
      final structureBase = await _taskStructureBase(base);
      desiredStateId = await _database
          .into(_database.desiredStateRows)
          .insert(
            DesiredStateRowsCompanion.insert(
              accountId: accountId.value,
              targetKey: 'task:${taskId.value}',
              resourceType: 'task',
              targetTaskListId: const Value<int?>.absent(),
              targetTaskId: Value<int>(taskId.value),
              desiredLifecycle: 'present',
              title: Value<String>(title),
              notes: Value<String?>(notes),
              status: Value<String>(_statusValue(status)),
              dueEpochDay: Value<int?>(_epochDay(due)),
              desiredTaskListId: Value<int>(taskListId.value),
              desiredParentTaskId: Value<int?>(parentTaskId?.value),
              desiredPreviousTaskId: Value<int?>(previousTaskId?.value),
              structureDirty: const Value<bool>(true),
              generation: 1,
              localCausalSequence: sequence,
              state: _stateValue(DesiredStateLifecycle.pending),
              baseRemoteId: Value<String>(base.remoteId),
              baseEtag: Value<String?>(base.etag),
              baseRemoteUpdatedAt: Value<DateTime?>(base.remoteUpdatedAt),
              baseObservedPublicationId: Value<String>(
                base.observedPublicationId,
              ),
              baseTitle: Value<String?>(base.title),
              baseNotes: Value<String?>(base.notes),
              baseStatus: Value<String?>(base.status),
              baseDueEpochDay: Value<int?>(base.dueEpochDay),
              baseTaskListId: Value<int>(base.taskListId),
              baseParentTaskId: Value<int?>(base.parentTaskId),
              basePreviousTaskId: Value<int?>(
                structureBase.previousTaskId?.value,
              ),
              basePosition: Value<String>(base.position!),
              baseSiblingOrder: Value<String>(structureBase.fingerprint),
              createdAt: modifiedAt.toUtc(),
              lastTransitionAt: modifiedAt.toUtc(),
            ),
          );
    } else {
      desiredStateId = existing.id;
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(existing.id),
          ))
          .write(
            DesiredStateRowsCompanion(
              desiredLifecycle: const Value<String>('present'),
              title: Value<String>(title),
              notes: Value<String?>(notes),
              status: Value<String>(_statusValue(status)),
              dueEpochDay: Value<int?>(_epochDay(due)),
              desiredTaskListId: Value<int>(taskListId.value),
              desiredParentTaskId: Value<int?>(parentTaskId?.value),
              desiredPreviousTaskId: Value<int?>(previousTaskId?.value),
              structureDirty: const Value<bool>(true),
              baseTaskListId: newlyCapturedBase == null
                  ? const Value<int>.absent()
                  : Value<int>(newlyCapturedBase.taskListId),
              baseParentTaskId: newlyCapturedBase == null
                  ? const Value<int?>.absent()
                  : Value<int?>(newlyCapturedBase.parentTaskId),
              basePreviousTaskId: newlyCapturedStructure == null
                  ? const Value<int?>.absent()
                  : Value<int?>(newlyCapturedStructure.previousTaskId?.value),
              basePosition: newlyCapturedBase == null
                  ? const Value<String?>.absent()
                  : Value<String?>(newlyCapturedBase.position),
              baseSiblingOrder: newlyCapturedStructure == null
                  ? const Value<String?>.absent()
                  : Value<String>(newlyCapturedStructure.fingerprint),
              generation: Value<int>(existing.generation + 1),
              localCausalSequence: Value<int>(sequence),
              state: Value<String>(_stateValue(DesiredStateLifecycle.pending)),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(modifiedAt.toUtc()),
            ),
          );
    }
    await (_database.delete(_database.desiredStateDependencyRows)..where(
          (row) =>
              row.accountId.equals(accountId.value) &
              row.desiredStateId.equals(desiredStateId) &
              row.dependencyKind.isIn(const <String>[
                'task_list',
                'parent_task',
                'previous_task',
              ]),
        ))
        .go();
    if (existing != null && existing.baseRemoteId == null) {
      await _database
          .into(_database.desiredStateDependencyRows)
          .insert(
            DesiredStateDependencyRowsCompanion.insert(
              accountId: accountId.value,
              desiredStateId: desiredStateId,
              dependencyKind: 'task_list',
              dependsOnTaskListId: Value<int>(taskListId.value),
            ),
          );
    }
    if (parentTaskId != null) {
      await _database
          .into(_database.desiredStateDependencyRows)
          .insert(
            DesiredStateDependencyRowsCompanion.insert(
              accountId: accountId.value,
              desiredStateId: desiredStateId,
              dependencyKind: 'parent_task',
              dependsOnTaskId: Value<int>(parentTaskId.value),
            ),
          );
    }
    if (previousTaskId != null) {
      await _database
          .into(_database.desiredStateDependencyRows)
          .insert(
            DesiredStateDependencyRowsCompanion.insert(
              accountId: accountId.value,
              desiredStateId: desiredStateId,
              dependencyKind: 'previous_task',
              dependsOnTaskId: Value<int>(previousTaskId.value),
            ),
          );
    }
    await _recomputeCounts(accountId);
    return _mapTask(await _taskQuery(accountId, taskId).getSingle());
  }

  Future<DesiredStateAttemptRecord> claimTaskList({
    required AccountId accountId,
    required TaskListId taskListId,
    required DateTime claimedAt,
  }) {
    return _database.transaction(() async {
      final desired = await _taskListQuery(
        accountId,
        taskListId,
      ).getSingleOrNull();
      if (desired == null ||
          !_claimableStates.contains(_state(desired.state))) {
        throw const DesiredStateInvariantException('generation_not_claimable');
      }
      final id = await _database
          .into(_database.desiredStateAttemptRows)
          .insert(
            DesiredStateAttemptRowsCompanion.insert(
              accountId: accountId.value,
              desiredStateId: desired.id,
              generation: desired.generation,
              desiredLifecycle: desired.desiredLifecycle,
              title: Value<String?>(desired.title),
              notes: Value<String?>(desired.notes),
              status: Value<String?>(desired.status),
              dueEpochDay: Value<int?>(desired.dueEpochDay),
              desiredTaskListId: Value<int?>(desired.desiredTaskListId),
              desiredParentTaskId: Value<int?>(desired.desiredParentTaskId),
              desiredPreviousTaskId: Value<int?>(desired.desiredPreviousTaskId),
              baseRemoteId: Value<String?>(desired.baseRemoteId),
              baseEtag: Value<String?>(desired.baseEtag),
              baseRemoteUpdatedAt: Value<DateTime?>(
                desired.baseRemoteUpdatedAt,
              ),
              baseObservedPublicationId: Value<String?>(
                desired.baseObservedPublicationId,
              ),
              baseTitle: Value<String?>(desired.baseTitle),
              baseTaskListId: Value<int?>(desired.baseTaskListId),
              baseParentTaskId: Value<int?>(desired.baseParentTaskId),
              basePreviousTaskId: Value<int?>(desired.basePreviousTaskId),
              basePosition: Value<String?>(desired.basePosition),
              baseSiblingOrder: Value<String?>(desired.baseSiblingOrder),
              state: _stateValue(DesiredStateLifecycle.inFlight),
              claimedAt: claimedAt.toUtc(),
              lastTransitionAt: claimedAt.toUtc(),
            ),
          );
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(desired.id),
          ))
          .write(
            DesiredStateRowsCompanion(
              state: Value<String>(_stateValue(DesiredStateLifecycle.inFlight)),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(claimedAt.toUtc()),
            ),
          );
      await _recomputeCounts(accountId);
      return _mapAttempt(
        await (_database.select(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(id))).getSingle(),
      );
    });
  }

  Future<DesiredStateAttemptRecord> claimTask({
    required AccountId accountId,
    required TaskId taskId,
    required DateTime claimedAt,
  }) {
    return _claim(
      accountId: accountId,
      desiredQuery: _taskQuery(accountId, taskId),
      claimedAt: claimedAt,
    );
  }

  Future<DesiredStateAttemptRecord> _claim({
    required AccountId accountId,
    required SimpleSelectStatement<$DesiredStateRowsTable, DesiredStateRow>
    desiredQuery,
    required DateTime claimedAt,
  }) {
    return _database.transaction(() async {
      final desired = await desiredQuery.getSingleOrNull();
      if (desired == null ||
          !_claimableStates.contains(_state(desired.state))) {
        throw const DesiredStateInvariantException('generation_not_claimable');
      }
      final id = await _database
          .into(_database.desiredStateAttemptRows)
          .insert(
            DesiredStateAttemptRowsCompanion.insert(
              accountId: accountId.value,
              desiredStateId: desired.id,
              generation: desired.generation,
              desiredLifecycle: desired.desiredLifecycle,
              title: Value<String?>(desired.title),
              notes: Value<String?>(desired.notes),
              status: Value<String?>(desired.status),
              dueEpochDay: Value<int?>(desired.dueEpochDay),
              desiredTaskListId: Value<int?>(desired.desiredTaskListId),
              desiredParentTaskId: Value<int?>(desired.desiredParentTaskId),
              desiredPreviousTaskId: Value<int?>(desired.desiredPreviousTaskId),
              baseRemoteId: Value<String?>(desired.baseRemoteId),
              baseEtag: Value<String?>(desired.baseEtag),
              baseRemoteUpdatedAt: Value<DateTime?>(
                desired.baseRemoteUpdatedAt,
              ),
              baseObservedPublicationId: Value<String?>(
                desired.baseObservedPublicationId,
              ),
              baseTitle: Value<String?>(desired.baseTitle),
              baseTaskListId: Value<int?>(desired.baseTaskListId),
              baseParentTaskId: Value<int?>(desired.baseParentTaskId),
              basePreviousTaskId: Value<int?>(desired.basePreviousTaskId),
              basePosition: Value<String?>(desired.basePosition),
              baseSiblingOrder: Value<String?>(desired.baseSiblingOrder),
              state: _stateValue(DesiredStateLifecycle.inFlight),
              claimedAt: claimedAt.toUtc(),
              lastTransitionAt: claimedAt.toUtc(),
            ),
          );
      await (_database.update(_database.desiredStateRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(desired.id),
          ))
          .write(
            DesiredStateRowsCompanion(
              state: Value<String>(_stateValue(DesiredStateLifecycle.inFlight)),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(claimedAt.toUtc()),
            ),
          );
      await _recomputeCounts(accountId);
      return _mapAttempt(
        await (_database.select(
          _database.desiredStateAttemptRows,
        )..where((row) => row.id.equals(id))).getSingle(),
      );
    });
  }

  Future<DesiredStateAttemptRecord?> readAttempt(
    AccountId accountId,
    int attemptId,
  ) async {
    final row =
        await (_database.select(_database.desiredStateAttemptRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(attemptId),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapAttempt(row);
  }

  Future<void> transitionAttempt({
    required AccountId accountId,
    required int attemptId,
    required DesiredStateLifecycle state,
    required DateTime transitionedAt,
    String? failureCode,
  }) {
    return _database.transaction(() async {
      final attempt =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attemptId),
              ))
              .getSingleOrNull();
      if (attempt == null) {
        throw const DesiredStateInvariantException('attempt_not_found');
      }
      final from = _state(attempt.state);
      if (!_allowedAttemptTransitions[from]!.contains(state) ||
          (state == DesiredStateLifecycle.failed ||
                  state == DesiredStateLifecycle.uncertain) !=
              (failureCode != null && failureCode.isNotEmpty)) {
        throw const DesiredStateInvariantException(
          'illegal_attempt_transition',
        );
      }
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attemptId))).write(
        DesiredStateAttemptRowsCompanion(
          state: Value<String>(_stateValue(state)),
          failureCode: Value<String?>(failureCode),
          lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
        ),
      );
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attempt.desiredStateId),
              ))
              .getSingleOrNull();
      if (desired != null && desired.generation == attempt.generation) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            state: Value<String>(_stateValue(state)),
            failureCode: Value<String?>(failureCode),
            lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
          ),
        );
      }
      await _recomputeCounts(accountId);
    });
  }

  Future<void> prepareUncertainAttemptReplay({
    required AccountId accountId,
    required int attemptId,
    required int generation,
    required DateTime preparedAt,
  }) {
    return _database.transaction(() async {
      final attempt =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attemptId) &
                    row.generation.equals(generation) &
                    row.state.equals('uncertain'),
              ))
              .getSingleOrNull();
      if (attempt == null) {
        throw const DesiredStateInvariantException(
          'uncertain_attempt_not_replayable',
        );
      }
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attempt.desiredStateId) &
                    row.generation.equals(generation),
              ))
              .getSingleOrNull();
      if (desired == null) {
        throw const DesiredStateInvariantException(
          'uncertain_generation_not_current',
        );
      }
      final at = preparedAt.toUtc();
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attempt.id))).write(
        DesiredStateAttemptRowsCompanion(
          state: const Value<String>('superseded'),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(at),
        ),
      );
      await (_database.update(
        _database.desiredStateRows,
      )..where((row) => row.id.equals(desired.id))).write(
        DesiredStateRowsCompanion(
          state: const Value<String>('pending'),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(at),
        ),
      );
      await _recomputeCounts(accountId);
    });
  }

  Future<void> acknowledgeTaskList({
    required AccountId accountId,
    required int attemptId,
    required TaskListRemoteId remoteId,
    required String title,
    required String? etag,
    required DateTime? remoteUpdatedAt,
    required String observedPublicationId,
    required DateTime acknowledgedAt,
    DesiredStateLifecycle resolution = DesiredStateLifecycle.confirmed,
  }) {
    return _database.transaction(() async {
      if (resolution != DesiredStateLifecycle.confirmed &&
          resolution != DesiredStateLifecycle.superseded) {
        throw const DesiredStateInvariantException(
          'invalid_acknowledgement_resolution',
        );
      }
      final attempt =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attemptId),
              ))
              .getSingleOrNull();
      if (attempt == null ||
          !_acknowledgeableStates.contains(_state(attempt.state))) {
        throw const DesiredStateInvariantException(
          'attempt_not_acknowledgeable',
        );
      }
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attempt.desiredStateId),
              ))
              .getSingle();
      final taskListId = desired.targetTaskListId;
      if (taskListId == null || desired.resourceType != 'task_list') {
        throw const DesiredStateInvariantException('attempt_target_mismatch');
      }
      final isCurrent = desired.generation == attempt.generation;
      await (_database.update(_database.taskListCacheRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(taskListId),
          ))
          .write(
            isCurrent
                ? TaskListCacheRowsCompanion(
                    remoteId: Value<String>(remoteId.value),
                    title: Value<String>(title),
                  )
                : TaskListCacheRowsCompanion(
                    remoteId: Value<String>(remoteId.value),
                  ),
          );
      await _reach(DesiredStateTransactionBoundary.afterRemoteIdentityWrite);
      await CacheDao(_database).putTaskListRemoteBase(
        accountId: accountId,
        taskListId: TaskListId(taskListId),
        remoteId: remoteId,
        title: title,
        etag: etag,
        remoteUpdatedAt: remoteUpdatedAt,
        observedPublicationId: observedPublicationId,
      );
      await _reach(DesiredStateTransactionBoundary.afterRemoteBaseWrite);
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attemptId))).write(
        DesiredStateAttemptRowsCompanion(
          state: Value<String>(_stateValue(resolution)),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
        ),
      );
      if (isCurrent) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            title: Value<String>(title),
            baseRemoteId: Value<String>(remoteId.value),
            baseEtag: Value<String?>(etag),
            baseRemoteUpdatedAt: Value<DateTime?>(remoteUpdatedAt?.toUtc()),
            baseObservedPublicationId: Value<String>(observedPublicationId),
            baseTitle: Value<String>(title),
            state: Value<String>(_stateValue(resolution)),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
          ),
        );
      } else {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            baseRemoteId: Value<String>(remoteId.value),
            baseEtag: Value<String?>(etag),
            baseRemoteUpdatedAt: Value<DateTime?>(remoteUpdatedAt?.toUtc()),
            baseObservedPublicationId: Value<String>(observedPublicationId),
            baseTitle: Value<String>(title),
          ),
        );
      }
      await _recomputeCounts(accountId);
      await _reach(DesiredStateTransactionBoundary.beforeRemoteCommit);
    });
  }

  Future<void> acknowledgeTask({
    required AccountId accountId,
    required int attemptId,
    required TaskRemoteId remoteId,
    required TaskListId taskListId,
    required TaskId? parentTaskId,
    required String title,
    required String? notes,
    required TaskStatus status,
    required TaskDate? due,
    required String position,
    required String? etag,
    required DateTime? remoteUpdatedAt,
    required String observedPublicationId,
    required DateTime acknowledgedAt,
    DesiredStateLifecycle resolution = DesiredStateLifecycle.confirmed,
  }) {
    return _database.transaction(() async {
      if (resolution != DesiredStateLifecycle.confirmed &&
          resolution != DesiredStateLifecycle.superseded) {
        throw const DesiredStateInvariantException(
          'invalid_acknowledgement_resolution',
        );
      }
      final attempt =
          await (_database.select(_database.desiredStateAttemptRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attemptId),
              ))
              .getSingleOrNull();
      if (attempt == null ||
          !_acknowledgeableStates.contains(_state(attempt.state))) {
        throw const DesiredStateInvariantException(
          'attempt_not_acknowledgeable',
        );
      }
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(attempt.desiredStateId),
              ))
              .getSingle();
      final taskId = desired.targetTaskId;
      if (taskId == null || desired.resourceType != 'task') {
        throw const DesiredStateInvariantException('attempt_target_mismatch');
      }
      final isCurrent = desired.generation == attempt.generation;
      await (_database.update(_database.taskCacheRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) & row.id.equals(taskId),
          ))
          .write(
            isCurrent
                ? TaskCacheRowsCompanion(
                    remoteId: Value<String>(remoteId.value),
                    taskListId: Value<int>(taskListId.value),
                    parentTaskId: Value<int?>(parentTaskId?.value),
                    title: Value<String>(title),
                    notes: Value<String?>(notes),
                    status: Value<String>(_statusValue(status)),
                    dueEpochDay: Value<int?>(_epochDay(due)),
                    position: Value<String>(position),
                  )
                : TaskCacheRowsCompanion(
                    remoteId: Value<String>(remoteId.value),
                  ),
          );
      await _reach(DesiredStateTransactionBoundary.afterRemoteIdentityWrite);
      await CacheDao(_database).putTaskRemoteBase(
        accountId: accountId,
        taskId: TaskId(taskId),
        taskListId: taskListId,
        parentTaskId: parentTaskId,
        remoteId: remoteId,
        observedPublicationId: observedPublicationId,
        deleted: false,
        title: title,
        notes: notes,
        status: status,
        due: due,
        position: position,
        etag: etag,
        remoteUpdatedAt: remoteUpdatedAt,
      );
      final siblings =
          await (_database.select(_database.taskRemoteBases)
                ..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskListId.equals(taskListId.value) &
                      (parentTaskId == null
                          ? row.parentTaskId.isNull()
                          : row.parentTaskId.equals(parentTaskId.value)) &
                      row.deleted.equals(false),
                )
                ..orderBy(<OrderingTerm Function($TaskRemoteBasesTable)>[
                  (row) => OrderingTerm.asc(row.position),
                  (row) => OrderingTerm.asc(row.taskId),
                ]))
              .get();
      final siblingIndex = siblings.indexWhere((row) => row.taskId == taskId);
      if (siblingIndex < 0) {
        throw const DesiredStateInvariantException(
          'create_structure_base_missing',
        );
      }
      final basePreviousTaskId = siblingIndex == 0
          ? null
          : siblings[siblingIndex - 1].taskId;
      final baseSiblingOrder = siblings
          .map((row) => '${row.taskId}:${row.position}')
          .join('|');
      await _reach(DesiredStateTransactionBoundary.afterRemoteBaseWrite);
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attemptId))).write(
        DesiredStateAttemptRowsCompanion(
          state: Value<String>(_stateValue(resolution)),
          failureCode: const Value<String?>(null),
          lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
        ),
      );
      if (isCurrent) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            title: Value<String>(title),
            notes: Value<String?>(notes),
            status: Value<String>(_statusValue(status)),
            dueEpochDay: Value<int?>(_epochDay(due)),
            desiredTaskListId: Value<int>(taskListId.value),
            desiredParentTaskId: Value<int?>(parentTaskId?.value),
            baseRemoteId: Value<String>(remoteId.value),
            baseEtag: Value<String?>(etag),
            baseRemoteUpdatedAt: Value<DateTime?>(remoteUpdatedAt?.toUtc()),
            baseObservedPublicationId: Value<String>(observedPublicationId),
            baseTitle: Value<String>(title),
            baseNotes: Value<String?>(notes),
            baseStatus: Value<String>(_statusValue(status)),
            baseDueEpochDay: Value<int?>(_epochDay(due)),
            baseTaskListId: Value<int>(taskListId.value),
            baseParentTaskId: Value<int?>(parentTaskId?.value),
            basePreviousTaskId: Value<int?>(basePreviousTaskId),
            basePosition: Value<String>(position),
            baseSiblingOrder: Value<String>(baseSiblingOrder),
            state: Value<String>(_stateValue(resolution)),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
          ),
        );
      } else {
        final createdPlacementStillDesired =
            desired.desiredLifecycle == 'present' &&
            desired.desiredTaskListId == taskListId.value &&
            desired.desiredParentTaskId == parentTaskId?.value &&
            desired.desiredPreviousTaskId == basePreviousTaskId;
        final structureRemainsDirty =
            desired.structureDirty && !createdPlacementStillDesired;
        final currentState =
            desired.contentDirty ||
                structureRemainsDirty ||
                desired.lifecycleDirty
            ? 'pending'
            : 'confirmed';
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            baseRemoteId: Value<String>(remoteId.value),
            baseEtag: Value<String?>(etag),
            baseRemoteUpdatedAt: Value<DateTime?>(remoteUpdatedAt?.toUtc()),
            baseObservedPublicationId: Value<String>(observedPublicationId),
            baseTitle: Value<String>(title),
            baseNotes: Value<String?>(notes),
            baseStatus: Value<String>(_statusValue(status)),
            baseDueEpochDay: Value<int?>(_epochDay(due)),
            baseTaskListId: Value<int>(taskListId.value),
            baseParentTaskId: Value<int?>(parentTaskId?.value),
            basePreviousTaskId: Value<int?>(basePreviousTaskId),
            basePosition: Value<String>(position),
            baseSiblingOrder: Value<String>(baseSiblingOrder),
            structureDirty: Value<bool>(structureRemainsDirty),
            state: Value<String>(currentState),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
          ),
        );
      }
      await _recomputeCounts(accountId);
      await _reach(DesiredStateTransactionBoundary.beforeRemoteCommit);
    });
  }

  Future<int> compactResolvedAttempts({
    required AccountId accountId,
    required DateTime resolvedBeforeOrAt,
  }) {
    return (_database.delete(_database.desiredStateAttemptRows)..where(
          (row) =>
              row.accountId.equals(accountId.value) &
              row.state.isIn(const <String>['confirmed', 'superseded']) &
              row.lastTransitionAt.isSmallerOrEqualValue(
                resolvedBeforeOrAt.toUtc(),
              ),
        ))
        .go();
  }

  Future<void> recomputeCounts(AccountId accountId) =>
      _recomputeCounts(accountId);

  SimpleSelectStatement<$DesiredStateRowsTable, DesiredStateRow> _taskListQuery(
    AccountId accountId,
    TaskListId taskListId,
  ) => _database.select(_database.desiredStateRows)
    ..where(
      (row) =>
          row.accountId.equals(accountId.value) &
          row.resourceType.equals('task_list') &
          row.targetTaskListId.equals(taskListId.value),
    );

  SimpleSelectStatement<$DesiredStateRowsTable, DesiredStateRow> _taskQuery(
    AccountId accountId,
    TaskId taskId,
  ) => _database.select(_database.desiredStateRows)
    ..where(
      (row) =>
          row.accountId.equals(accountId.value) &
          row.resourceType.equals('task') &
          row.targetTaskId.equals(taskId.value),
    );

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

  Future<void> _recomputeCounts(AccountId accountId) async {
    final rows = await (_database.select(
      _database.desiredStateRows,
    )..where((row) => row.accountId.equals(accountId.value))).get();
    int count(DesiredStateLifecycle state) =>
        rows.where((row) => _state(row.state) == state).length;
    await _database
        .into(_database.syncFactRows)
        .insert(
          SyncFactRowsCompanion.insert(accountId: Value<int>(accountId.value)),
          mode: InsertMode.insertOrIgnore,
        );
    await (_database.update(
      _database.syncFactRows,
    )..where((row) => row.accountId.equals(accountId.value))).write(
      SyncFactRowsCompanion(
        pendingCount: Value<int>(count(DesiredStateLifecycle.pending)),
        inFlightCount: Value<int>(count(DesiredStateLifecycle.inFlight)),
        uncertainCount: Value<int>(count(DesiredStateLifecycle.uncertain)),
        failedCount: Value<int>(count(DesiredStateLifecycle.failed)),
      ),
    );
    await _database.customUpdate(
      '''
      UPDATE bulk_operation_members AS member
      SET outcome = CASE
        WHEN EXISTS (
          SELECT 1
          FROM desired_state_attempts attempt
          WHERE attempt.account_id = member.account_id
            AND attempt.desired_state_id = member.desired_state_id
            AND attempt.generation = member.generation
        ) THEN CASE (
          SELECT attempt.state
          FROM desired_state_attempts attempt
          WHERE attempt.account_id = member.account_id
            AND attempt.desired_state_id = member.desired_state_id
            AND attempt.generation = member.generation
          ORDER BY attempt.id DESC
          LIMIT 1
        )
          WHEN 'confirmed' THEN 'confirmed'
          WHEN 'failed' THEN 'failed'
          WHEN 'superseded' THEN 'failed'
          ELSE 'pending'
        END
        WHEN EXISTS (
          SELECT 1
          FROM desired_states desired
          WHERE desired.account_id = member.account_id
            AND desired.id = member.desired_state_id
            AND desired.generation = member.generation
        ) THEN CASE (
          SELECT desired.state
          FROM desired_states desired
          WHERE desired.account_id = member.account_id
            AND desired.id = member.desired_state_id
        )
          WHEN 'confirmed' THEN 'confirmed'
          WHEN 'failed' THEN 'failed'
          WHEN 'superseded' THEN 'failed'
          ELSE 'pending'
        END
        WHEN EXISTS (
          SELECT 1
          FROM desired_states desired
          WHERE desired.account_id = member.account_id
            AND desired.id = member.desired_state_id
            AND desired.generation > member.generation
        ) THEN 'failed'
        ELSE member.outcome
      END
      WHERE member.account_id = ?1
      ''',
      variables: <Variable<Object>>[Variable<int>(accountId.value)],
      updates: <TableInfo<Table, Object?>>{_database.bulkOperationMemberRows},
    );
  }

  Future<bool> _listScopeComplete(AccountId accountId, String runId) async =>
      await (_database.select(_database.scopeCompletenessRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.scopeKind.equals('task_lists') &
                row.taskListId.isNull() &
                row.publicationId.equals(runId) &
                row.isComplete.equals(true),
          ))
          .getSingleOrNull() !=
      null;

  Future<bool> _taskScopeComplete(
    AccountId accountId,
    TaskListId taskListId,
    String runId,
  ) async =>
      await (_database.select(_database.scopeCompletenessRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.scopeKind.equals('tasks') &
                row.taskListId.equals(taskListId.value) &
                row.publicationId.equals(runId) &
                row.isComplete.equals(true),
          ))
          .getSingleOrNull() !=
      null;

  Future<void> _rebaseDesiredTask({
    required DesiredStateRow desired,
    required TaskRemoteBase current,
    required DesiredStateLifecycle state,
    required DateTime transitionedAt,
    required bool updateProjection,
  }) async {
    final contentResolved = state != DesiredStateLifecycle.pending;
    final effectiveState = contentResolved && desired.structureDirty
        ? DesiredStateLifecycle.pending
        : state;
    if (updateProjection) {
      await (_database.update(_database.taskCacheRows)..where(
            (row) =>
                row.accountId.equals(desired.accountId) &
                row.id.equals(desired.targetTaskId!),
          ))
          .write(
            TaskCacheRowsCompanion(
              title: Value<String>(current.title!),
              notes: Value<String?>(current.notes),
              status: Value<String>(current.status!),
              dueEpochDay: Value<int?>(current.dueEpochDay),
            ),
          );
    }
    await (_database.update(
      _database.desiredStateRows,
    )..where((row) => row.id.equals(desired.id))).write(
      DesiredStateRowsCompanion(
        contentDirty: contentResolved && desired.structureDirty
            ? const Value<bool>(false)
            : const Value<bool>.absent(),
        title: updateProjection
            ? Value<String>(current.title!)
            : const Value<String>.absent(),
        notes: updateProjection
            ? Value<String?>(current.notes)
            : const Value<String?>.absent(),
        status: updateProjection
            ? Value<String>(current.status!)
            : const Value<String>.absent(),
        dueEpochDay: updateProjection
            ? Value<int?>(current.dueEpochDay)
            : const Value<int?>.absent(),
        baseRemoteId: Value<String>(current.remoteId),
        baseEtag: Value<String?>(current.etag),
        baseRemoteUpdatedAt: Value<DateTime?>(current.remoteUpdatedAt?.toUtc()),
        baseObservedPublicationId: Value<String>(current.observedPublicationId),
        baseTitle: Value<String>(current.title!),
        baseNotes: Value<String?>(current.notes),
        baseStatus: Value<String>(current.status!),
        baseDueEpochDay: Value<int?>(current.dueEpochDay),
        state: Value<String>(_stateValue(effectiveState)),
        failureCode: const Value<String?>(null),
        lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
      ),
    );
  }

  Future<void> _rebaseDesiredTaskList({
    required DesiredStateRow desired,
    required TaskListRemoteBase current,
    required DesiredStateLifecycle state,
    required DateTime transitionedAt,
    required bool updateProjection,
  }) async {
    if (updateProjection) {
      await (_database.update(_database.taskListCacheRows)..where(
            (row) =>
                row.accountId.equals(desired.accountId) &
                row.id.equals(desired.targetTaskListId!),
          ))
          .write(TaskListCacheRowsCompanion(title: Value(current.title)));
    }
    await (_database.update(
      _database.desiredStateRows,
    )..where((row) => row.id.equals(desired.id))).write(
      DesiredStateRowsCompanion(
        title: updateProjection
            ? Value<String>(current.title)
            : const Value<String>.absent(),
        baseRemoteId: Value<String>(current.remoteId),
        baseEtag: Value<String?>(current.etag),
        baseRemoteUpdatedAt: Value<DateTime?>(current.remoteUpdatedAt?.toUtc()),
        baseObservedPublicationId: Value<String>(current.observedPublicationId),
        baseTitle: Value<String>(current.title),
        state: Value<String>(_stateValue(state)),
        failureCode: const Value<String?>(null),
        lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
      ),
    );
  }

  Future<void> _resolvePriorAttempts(
    DesiredStateRow desired,
    DesiredStateLifecycle state,
    DateTime transitionedAt,
  ) async {
    await (_database.update(_database.desiredStateAttemptRows)..where(
          (row) =>
              row.accountId.equals(desired.accountId) &
              row.desiredStateId.equals(desired.id) &
              row.generation.equals(desired.generation) &
              row.state.isIn(const <String>[
                'in_flight',
                'uncertain',
                'failed',
              ]),
        ))
        .write(
          DesiredStateAttemptRowsCompanion(
            state: Value<String>(_stateValue(state)),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
          ),
        );
  }

  Future<_StoredStructureBase> _taskStructureBase(TaskRemoteBase base) async {
    if (base.position == null) {
      throw const DesiredStateInvariantException('structure_base_incomplete');
    }
    final siblings =
        await (_database.select(_database.taskRemoteBases)
              ..where(
                (row) =>
                    row.accountId.equals(base.accountId) &
                    row.taskListId.equals(base.taskListId) &
                    (base.parentTaskId == null
                        ? row.parentTaskId.isNull()
                        : row.parentTaskId.equals(base.parentTaskId!)) &
                    row.deleted.equals(false),
              )
              ..orderBy(<OrderingTerm Function($TaskRemoteBasesTable)>[
                (row) => OrderingTerm.asc(row.position),
                (row) => OrderingTerm.asc(row.taskId),
              ]))
            .get();
    final index = siblings.indexWhere((row) => row.taskId == base.taskId);
    if (index < 0) {
      throw const DesiredStateInvariantException('structure_base_missing');
    }
    return _StoredStructureBase(
      previousTaskId: index == 0 ? null : TaskId(siblings[index - 1].taskId),
      fingerprint: siblings
          .map((row) => '${row.taskId}:${row.position}')
          .join('|'),
    );
  }

  Future<void> _reach(DesiredStateTransactionBoundary boundary) async {
    await transactionControl?.call(boundary);
  }
}

final class _StoredStructureBase {
  const _StoredStructureBase({
    required this.previousTaskId,
    required this.fingerprint,
  });

  final TaskId? previousTaskId;
  final String fingerprint;
}

TaskListDesiredStateRecord _mapTaskList(DesiredStateRow row) =>
    TaskListDesiredStateRecord(
      id: row.id,
      accountId: AccountId(row.accountId),
      taskListId: TaskListId(row.targetTaskListId!),
      title: row.title!,
      generation: row.generation,
      localCausalSequence: row.localCausalSequence,
      state: _state(row.state),
      desiredLifecycle: _desiredLifecycle(row.desiredLifecycle),
      baseRemoteId: row.baseRemoteId == null
          ? null
          : TaskListRemoteId(row.baseRemoteId!),
      baseEtag: row.baseEtag,
      baseRemoteUpdatedAt: row.baseRemoteUpdatedAt?.toUtc(),
      baseObservedPublicationId: row.baseObservedPublicationId,
      baseTitle: row.baseTitle,
      localModifiedAt: row.localModifiedAt?.toUtc(),
      createdAt: row.createdAt.toUtc(),
      lastTransitionAt: row.lastTransitionAt.toUtc(),
    );

TaskDesiredStateRecord _mapTask(DesiredStateRow row) => TaskDesiredStateRecord(
  id: row.id,
  accountId: AccountId(row.accountId),
  taskId: TaskId(row.targetTaskId!),
  taskListId: TaskListId(row.desiredTaskListId!),
  parentTaskId: row.desiredParentTaskId == null
      ? null
      : TaskId(row.desiredParentTaskId!),
  previousTaskId: row.desiredPreviousTaskId == null
      ? null
      : TaskId(row.desiredPreviousTaskId!),
  contentDirty: row.contentDirty,
  structureDirty: row.structureDirty,
  title: row.title!,
  notes: row.notes,
  status: _status(row.status),
  due: _taskDate(row.dueEpochDay),
  generation: row.generation,
  localCausalSequence: row.localCausalSequence,
  state: _state(row.state),
  desiredLifecycle: _desiredLifecycle(row.desiredLifecycle),
  baseRemoteId: row.baseRemoteId == null
      ? null
      : TaskRemoteId(row.baseRemoteId!),
  baseEtag: row.baseEtag,
  baseRemoteUpdatedAt: row.baseRemoteUpdatedAt?.toUtc(),
  baseObservedPublicationId: row.baseObservedPublicationId,
  baseTitle: row.baseTitle,
  baseNotes: row.baseNotes,
  baseStatus: row.baseStatus == null ? null : _status(row.baseStatus),
  baseDue: _taskDate(row.baseDueEpochDay),
  baseTaskListId: row.baseTaskListId == null
      ? null
      : TaskListId(row.baseTaskListId!),
  baseParentTaskId: row.baseParentTaskId == null
      ? null
      : TaskId(row.baseParentTaskId!),
  basePreviousTaskId: row.basePreviousTaskId == null
      ? null
      : TaskId(row.basePreviousTaskId!),
  basePosition: row.basePosition,
  baseSiblingOrder: row.baseSiblingOrder,
  localModifiedAt: row.localModifiedAt?.toUtc(),
  createdAt: row.createdAt.toUtc(),
  lastTransitionAt: row.lastTransitionAt.toUtc(),
);

DesiredStateAttemptRecord _mapAttempt(DesiredStateAttemptRow row) =>
    DesiredStateAttemptRecord(
      id: row.id,
      accountId: AccountId(row.accountId),
      desiredStateId: row.desiredStateId,
      generation: row.generation,
      title: row.title,
      notes: row.notes,
      status: row.status == null ? null : _status(row.status),
      due: _taskDate(row.dueEpochDay),
      state: _state(row.state),
      failureCode: row.failureCode,
      claimedAt: row.claimedAt.toUtc(),
      lastTransitionAt: row.lastTransitionAt.toUtc(),
    );

const Set<DesiredStateLifecycle> _claimableStates = <DesiredStateLifecycle>{
  DesiredStateLifecycle.pending,
  DesiredStateLifecycle.failed,
  DesiredStateLifecycle.uncertain,
};

const Set<DesiredStateLifecycle> _acknowledgeableStates =
    <DesiredStateLifecycle>{
      DesiredStateLifecycle.inFlight,
      DesiredStateLifecycle.uncertain,
      DesiredStateLifecycle.failed,
    };

const Map<DesiredStateLifecycle, Set<DesiredStateLifecycle>>
_allowedAttemptTransitions =
    <DesiredStateLifecycle, Set<DesiredStateLifecycle>>{
      DesiredStateLifecycle.pending: <DesiredStateLifecycle>{
        DesiredStateLifecycle.inFlight,
        DesiredStateLifecycle.failed,
        DesiredStateLifecycle.superseded,
      },
      DesiredStateLifecycle.inFlight: <DesiredStateLifecycle>{
        DesiredStateLifecycle.pending,
        DesiredStateLifecycle.confirmed,
        DesiredStateLifecycle.superseded,
        DesiredStateLifecycle.uncertain,
        DesiredStateLifecycle.failed,
      },
      DesiredStateLifecycle.uncertain: <DesiredStateLifecycle>{
        DesiredStateLifecycle.pending,
        DesiredStateLifecycle.confirmed,
        DesiredStateLifecycle.superseded,
      },
      DesiredStateLifecycle.failed: <DesiredStateLifecycle>{
        DesiredStateLifecycle.pending,
        DesiredStateLifecycle.confirmed,
        DesiredStateLifecycle.superseded,
      },
      DesiredStateLifecycle.confirmed: <DesiredStateLifecycle>{},
      DesiredStateLifecycle.superseded: <DesiredStateLifecycle>{},
    };

String _stateValue(DesiredStateLifecycle state) => switch (state) {
  DesiredStateLifecycle.pending => 'pending',
  DesiredStateLifecycle.inFlight => 'in_flight',
  DesiredStateLifecycle.uncertain => 'uncertain',
  DesiredStateLifecycle.failed => 'failed',
  DesiredStateLifecycle.confirmed => 'confirmed',
  DesiredStateLifecycle.superseded => 'superseded',
};

const Failure _invalidConflictBaseFailure = Failure(
  code: 'sync.content_conflict_base_invalid',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'A pending Google Tasks edit could not be reconciled safely.',
  safeSummary: 'The stored whole-record conflict base was incomplete.',
);

const Failure _invalidConflictTimestampFailure = Failure(
  code: 'sync.content_conflict_timestamp_invalid',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'Concurrent Google Tasks edits could not be ordered safely.',
  safeSummary: 'Required whole-record conflict timestamp evidence was absent.',
);

DesiredStateLifecycle _state(String state) => switch (state) {
  'pending' => DesiredStateLifecycle.pending,
  'in_flight' => DesiredStateLifecycle.inFlight,
  'uncertain' => DesiredStateLifecycle.uncertain,
  'failed' => DesiredStateLifecycle.failed,
  'confirmed' => DesiredStateLifecycle.confirmed,
  'superseded' => DesiredStateLifecycle.superseded,
  _ => throw const DesiredStateInvariantException('unknown_lifecycle_state'),
};

DesiredLifecycle _desiredLifecycle(String value) => switch (value) {
  'present' => DesiredLifecycle.present,
  'deleted' => DesiredLifecycle.deleted,
  _ => throw const DesiredStateInvariantException('unknown_desired_lifecycle'),
};

String _statusValue(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'needs_action',
  TaskStatus.completed => 'completed',
};

TaskStatus _status(String? value) => switch (value) {
  'needs_action' => TaskStatus.needsAction,
  'completed' => TaskStatus.completed,
  _ => throw const DesiredStateInvariantException('unknown_task_status'),
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
