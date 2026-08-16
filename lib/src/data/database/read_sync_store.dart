import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../data/google_tasks/dto.dart';
import '../../domain/model/tasks.dart';
import '../../sync/create_operations.dart';
import '../../sync/delete_operations.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/reconciliation/structure_policy.dart';
import '../../sync/retry/retry_episode.dart';
import '../../sync/run.dart';
import '../../sync/structure_operations.dart';
import '../../sync/update_operations.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'delete_state_dao.dart';
import 'desired_state_dao.dart';
import 'sync_health_dao.dart';

final class DatabaseReadSyncStore implements SyncStore, SyncRetryEpisodeStore {
  DatabaseReadSyncStore(
    this._database, {
    DesiredStateTransactionControl? transactionControl,
  }) : _cache = CacheDao(_database),
       _desired = DesiredStateDao(
         _database,
         transactionControl: transactionControl,
       ),
       _deletes = DeleteStateDao(_database),
       _health = SyncHealthDao(_database);

  final AppDatabase _database;
  final CacheDao _cache;
  final DesiredStateDao _desired;
  final DeleteStateDao _deletes;
  final SyncHealthDao _health;

  @override
  Future<bool> readReauthorizationRequired(AccountId accountId) async =>
      (await readEligibility(accountId)).reauthorizationRequired;

  @override
  Future<String?> readAuthorizationSubject(AccountId accountId) async =>
      (await readEligibility(accountId)).googleSubject;

  @override
  Future<void> requireReauthorization(AccountId accountId) {
    return _database.transaction(() async {
      await _requireAccount(accountId);
      await _ensureSyncFacts(accountId);
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        const SyncFactRowsCompanion(reauthorizationRequired: Value<bool>(true)),
      );
    });
  }

  @override
  Future<void> completeReauthorization(AccountId accountId) {
    return _database.transaction(() async {
      await _requireAccount(accountId);
      await _ensureSyncFacts(accountId);
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        const SyncFactRowsCompanion(
          reauthorizationRequired: Value<bool>(false),
          latestFailureReason: Value<String?>(null),
          latestFailureAt: Value<DateTime?>(null),
          latestFailureDiagnosticCode: Value<String?>(null),
          latestFailureAction: Value<String?>(null),
          requiredScopeIncomplete: Value<bool>(false),
        ),
      );
    });
  }

  @override
  Future<RetryEpisode?> readRetryEpisode(AccountId accountId) async {
    final row = await (_database.select(
      _database.syncFactRows,
    )..where((row) => row.accountId.equals(accountId.value))).getSingleOrNull();
    final startedAt = row?.retryEpisodeStartedAt;
    if (startedAt == null) return null;
    final deadlineAt = row!.retryEpisodeDeadlineAt;
    final lastObservedAt = row.retryLastObservedAt;
    if (deadlineAt == null || lastObservedAt == null) {
      throw const CacheInvariantException('retry_episode_incomplete');
    }
    return RetryEpisode(
      startedAt: startedAt.toUtc(),
      deadlineAt: deadlineAt.toUtc(),
      nextAttemptAt: row.retryNextAttemptAt?.toUtc(),
      serverNotBeforeAt: row.retryServerNotBeforeAt?.toUtc(),
      lastObservedAt: lastObservedAt.toUtc(),
      attemptCount: row.retryAttemptCount,
      automaticRetryExhausted: row.automaticRetryExhausted,
    );
  }

  @override
  Future<void> writeRetryEpisode(AccountId accountId, RetryEpisode episode) {
    return _database.transaction(() async {
      await _requireAccount(accountId);
      await _ensureSyncFacts(accountId);
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        SyncFactRowsCompanion(
          retryWaiting: Value<bool>(episode.retryWaiting),
          automaticRetryExhausted: Value<bool>(episode.automaticRetryExhausted),
          retryEpisodeStartedAt: Value<DateTime>(episode.startedAt.toUtc()),
          retryEpisodeDeadlineAt: Value<DateTime>(episode.deadlineAt.toUtc()),
          retryNextAttemptAt: Value<DateTime?>(episode.nextAttemptAt?.toUtc()),
          retryServerNotBeforeAt: Value<DateTime?>(
            episode.serverNotBeforeAt?.toUtc(),
          ),
          retryLastObservedAt: Value<DateTime>(episode.lastObservedAt.toUtc()),
          retryAttemptCount: Value<int>(episode.attemptCount),
        ),
      );
    });
  }

  @override
  Future<void> clearRetryEpisode(AccountId accountId) {
    return _database.transaction(() async {
      await _requireAccount(accountId);
      await _ensureSyncFacts(accountId);
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        const SyncFactRowsCompanion(
          retryWaiting: Value<bool>(false),
          automaticRetryExhausted: Value<bool>(false),
          retryEpisodeStartedAt: Value<DateTime?>(null),
          retryEpisodeDeadlineAt: Value<DateTime?>(null),
          retryNextAttemptAt: Value<DateTime?>(null),
          retryServerNotBeforeAt: Value<DateTime?>(null),
          retryLastObservedAt: Value<DateTime?>(null),
          retryAttemptCount: Value<int>(0),
        ),
      );
    });
  }

  @override
  Future<StructureReconciliationSummary> reconcileStructure({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  }) async {
    if (!await isPublicationComplete(
      accountId: accountId,
      runId: SyncRunId(runId),
    )) {
      return const StructureReconciliationSummary();
    }
    return _database.transaction(() async {
      var confirmedReadBacks = 0;
      var localMovesPending = 0;
      var googleWins = 0;
      Failure? failure;
      final desiredRows =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.resourceType.equals('task') &
                    row.desiredLifecycle.equals('present') &
                    row.structureDirty.equals(true) &
                    row.baseRemoteId.isNotNull() &
                    row.state.isIn(const <String>['pending', 'uncertain']),
              ))
              .get();
      for (final desired in desiredRows) {
        if (desired.targetTaskId == null ||
            desired.desiredTaskListId == null ||
            desired.baseTaskListId == null ||
            desired.basePosition == null ||
            desired.baseSiblingOrder == null) {
          failure ??= _invalidStructureBaseFailure;
          continue;
        }
        final currentBase =
            await (_database.select(_database.taskRemoteBases)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskId.equals(desired.targetTaskId!) &
                      row.deleted.equals(false) &
                      row.observedPublicationId.equals(runId),
                ))
                .getSingleOrNull();
        if (currentBase == null) continue;
        final remote = await _structureSnapshot(currentBase, runId: runId);
        if (remote == null) continue;
        final base = TaskStructureSnapshot(
          taskListId: TaskListId(desired.baseTaskListId!),
          parentTaskId: desired.baseParentTaskId == null
              ? null
              : TaskId(desired.baseParentTaskId!),
          previousTaskId: desired.basePreviousTaskId == null
              ? null
              : TaskId(desired.basePreviousTaskId!),
          siblingOrderFingerprint: desired.baseSiblingOrder!,
        );
        final local = TaskPlacement(
          taskListId: TaskListId(desired.desiredTaskListId!),
          parentTaskId: desired.desiredParentTaskId == null
              ? null
              : TaskId(desired.desiredParentTaskId!),
          previousTaskId: desired.desiredPreviousTaskId == null
              ? null
              : TaskId(desired.desiredPreviousTaskId!),
        );
        final anchorValid = await _placementReferencesAreCurrent(
          accountId: accountId,
          placement: local,
          runId: runId,
          targetTaskId: TaskId(desired.targetTaskId!),
        );
        final winner = anchorValid
            ? reconcileTaskStructure(base: base, local: local, remote: remote)
            : StructureWinner.google;
        switch (winner) {
          case StructureWinner.local:
            await _rebasePendingStructure(
              desired: desired,
              currentBase: currentBase,
              remote: remote,
              transitionedAt: reconciledAt,
            );
            localMovesPending += 1;
          case StructureWinner.google:
          case StructureWinner.confirmed:
            await _resolveObservedStructure(
              desired: desired,
              currentBase: currentBase,
              remote: remote,
              resolution: winner == StructureWinner.google
                  ? DesiredStateLifecycle.superseded
                  : DesiredStateLifecycle.confirmed,
              transitionedAt: reconciledAt,
            );
            if (winner == StructureWinner.google) {
              googleWins += 1;
            } else {
              confirmedReadBacks += 1;
            }
        }
      }
      await _desired.recomputeCounts(accountId);
      return StructureReconciliationSummary(
        confirmedReadBacks: confirmedReadBacks,
        localMovesPending: localMovesPending,
        supersessions: <StructureSupersessionResult>[
          if (googleWins > 0)
            StructureSupersessionResult(
              kind: StructureSupersessionKind.taskPlacement,
              count: googleWins,
            ),
        ],
        failure: failure,
      );
    });
  }

  @override
  Future<MoveOperationClaim?> claimNextMove({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  }) async {
    if (!await isPublicationComplete(
      accountId: accountId,
      runId: SyncRunId(runId),
    )) {
      return null;
    }
    return _database.transaction(() async {
      final rows =
          await (_database.select(_database.desiredStateRows)
                ..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.resourceType.equals('task') &
                      row.desiredLifecycle.equals('present') &
                      row.structureDirty.equals(true) &
                      row.baseRemoteId.isNotNull() &
                      row.state.equals('pending'),
                )
                ..orderBy(<OrderingTerm Function($DesiredStateRowsTable)>[
                  (row) => OrderingTerm.asc(row.localCausalSequence),
                  (row) => OrderingTerm.asc(row.id),
                ]))
              .get();
      for (final desired in rows) {
        final current =
            await (_database.select(_database.taskRemoteBases)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.taskId.equals(desired.targetTaskId!) &
                      row.deleted.equals(false) &
                      row.observedPublicationId.equals(runId),
                ))
                .getSingleOrNull();
        if (current == null || current.etag == null) continue;
        final sourceList = await _taskListRow(
          accountId,
          TaskListId(current.taskListId),
        );
        final destinationList = await _taskListRow(
          accountId,
          TaskListId(desired.desiredTaskListId!),
        );
        if (sourceList?.remoteId == null || destinationList?.remoteId == null) {
          continue;
        }
        final parent = await _currentRemoteTask(
          accountId,
          desired.desiredParentTaskId,
          runId,
        );
        final previous = await _currentRemoteTask(
          accountId,
          desired.desiredPreviousTaskId,
          runId,
        );
        if ((desired.desiredParentTaskId != null && parent == null) ||
            (desired.desiredPreviousTaskId != null && previous == null)) {
          continue;
        }
        final attempt = await _desired.claimTask(
          accountId: accountId,
          taskId: TaskId(desired.targetTaskId!),
          claimedAt: claimedAt,
        );
        return MoveOperationClaim(
          attemptId: attempt.id,
          generation: attempt.generation,
          taskId: TaskId(desired.targetTaskId!),
          taskRemoteId: RemoteTaskId(current.remoteId),
          sourceTaskListId: TaskListId(current.taskListId),
          sourceTaskListRemoteId: RemoteTaskListId(sourceList!.remoteId!),
          destinationTaskListId: TaskListId(desired.desiredTaskListId!),
          destinationTaskListRemoteId: RemoteTaskListId(
            destinationList!.remoteId!,
          ),
          parentTaskId: desired.desiredParentTaskId == null
              ? null
              : TaskId(desired.desiredParentTaskId!),
          parentRemoteId: parent == null ? null : RemoteTaskId(parent.remoteId),
          previousTaskId: desired.desiredPreviousTaskId == null
              ? null
              : TaskId(desired.desiredPreviousTaskId!),
          previousRemoteId: previous == null
              ? null
              : RemoteTaskId(previous.remoteId),
          etag: current.etag!,
        );
      }
      return null;
    });
  }

  @override
  Future<void> acknowledgeMove({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
      if (remote.id != claim.taskRemoteId ||
          remote.parentId != claim.parentRemoteId) {
        throw const DesiredStateInvariantException('move_response_mismatch');
      }
      final desired =
          await (_database.select(_database.desiredStateRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.targetTaskId.equals(claim.taskId.value),
              ))
              .getSingle();
      final isCurrent = desired.generation == claim.generation;
      if (isCurrent) {
        await _moveProjectedSubtree(
          accountId: accountId,
          taskId: claim.taskId,
          taskListId: claim.destinationTaskListId,
          parentTaskId: claim.parentTaskId,
          position: remote.position,
          content: desired.contentDirty ? null : remote,
        );
      }
      await _cache.putTaskRemoteBase(
        accountId: accountId,
        taskId: claim.taskId,
        taskListId: claim.destinationTaskListId,
        parentTaskId: claim.parentTaskId,
        remoteId: TaskRemoteId(remote.id.value),
        observedPublicationId: observationId,
        deleted: false,
        title: remote.title,
        notes: remote.notes,
        status: _taskStatus(remote.status),
        due: _taskDate(remote.due),
        position: remote.position,
        completedAt: remote.completed,
        hidden: remote.hidden,
        etag: remote.etag,
        remoteUpdatedAt: remote.updated,
        selfLink: remote.selfLink,
        links: _links(remote.links),
        webViewLink: remote.webViewLink,
      );
      await (_database.update(_database.desiredStateAttemptRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(claim.attemptId),
          ))
          .write(
            DesiredStateAttemptRowsCompanion(
              state: const Value<String>('confirmed'),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
            ),
          );
      if (isCurrent) {
        await (_database.update(
          _database.desiredStateRows,
        )..where((row) => row.id.equals(desired.id))).write(
          DesiredStateRowsCompanion(
            structureDirty: desired.contentDirty
                ? const Value<bool>(false)
                : const Value<bool>.absent(),
            baseRemoteId: Value<String>(remote.id.value),
            baseEtag: Value<String?>(remote.etag),
            baseRemoteUpdatedAt: Value<DateTime?>(remote.updated?.toUtc()),
            baseObservedPublicationId: Value<String>(observationId),
            baseTaskListId: Value<int>(claim.destinationTaskListId.value),
            baseParentTaskId: Value<int?>(claim.parentTaskId?.value),
            basePreviousTaskId: Value<int?>(claim.previousTaskId?.value),
            basePosition: Value<String>(remote.position),
            baseSiblingOrder: Value<String>(
              'canonical-response:${claim.taskId.value}:${remote.position}',
            ),
            state: Value<String>(
              desired.contentDirty ? 'pending' : 'confirmed',
            ),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
          ),
        );
      }
      await _desired.recomputeCounts(accountId);
    });
  }

  @override
  Future<void> prepareMoveReplan({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required DateTime replannedAt,
  }) => _desired.prepareTaskUpdateReplan(
    accountId: accountId,
    attemptId: claim.attemptId,
    generation: claim.generation,
    replannedAt: replannedAt,
  );

  @override
  Future<void> resolveMoveFailure({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  }) => _desired.transitionAttempt(
    accountId: accountId,
    attemptId: claim.attemptId,
    state: uncertain
        ? DesiredStateLifecycle.uncertain
        : failure.retry == RetryClassification.transient
        ? DesiredStateLifecycle.pending
        : DesiredStateLifecycle.failed,
    transitionedAt: resolvedAt,
    failureCode: uncertain || failure.retry != RetryClassification.transient
        ? failure.code
        : null,
  );

  @override
  Future<void> recoverDeletes({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) async {
    await _desired.recoverInFlightDeletes(
      accountId: accountId,
      recoveredAt: recoveredAt,
    );
    await _deletes.cleanupExpiredTaskDeletes(
      accountId: accountId,
      now: recoveredAt,
    );
  }

  @override
  Future<void> reconcileDeletes({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  }) => _deletes.reconcileDeletes(
    accountId: accountId,
    runId: runId,
    reconciledAt: reconciledAt,
  );

  @override
  Future<DeleteOperationClaim?> claimNextDelete({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  }) => _database.transaction(() async {
    final candidate = await _deletes.readNextEligibleDelete(
      accountId: accountId,
      now: claimedAt,
      runId: runId,
    );
    if (candidate == null) return null;
    final attempt = candidate.resourceType == DeleteResourceType.taskList
        ? await _desired.claimTaskList(
            accountId: accountId,
            taskListId: candidate.taskListId,
            claimedAt: claimedAt,
          )
        : await _desired.claimTask(
            accountId: accountId,
            taskId: candidate.taskId!,
            claimedAt: claimedAt,
          );
    return DeleteOperationClaim(
      kind: candidate.resourceType == DeleteResourceType.taskList
          ? DeleteOperationKind.taskList
          : DeleteOperationKind.task,
      attemptId: attempt.id,
      generation: attempt.generation,
      taskListId: candidate.taskListId,
      taskListRemoteId: candidate.taskListRemoteId,
      taskId: candidate.taskId,
      taskRemoteId: candidate.taskRemoteId,
      etag: candidate.etag,
    );
  });

  @override
  Future<void> acknowledgeTaskListDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  }) => _deletes.acknowledgeTaskListDelete(
    accountId: accountId,
    claim: claim,
    observationId: observationId,
    acknowledgedAt: acknowledgedAt,
  );

  @override
  Future<void> acknowledgeTaskDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  }) => _deletes.acknowledgeTaskDelete(
    accountId: accountId,
    claim: claim,
    observationId: observationId,
    acknowledgedAt: acknowledgedAt,
  );

  @override
  Future<void> resolveDeleteFailure({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  }) => _desired.transitionAttempt(
    accountId: accountId,
    attemptId: claim.attemptId,
    state: uncertain
        ? DesiredStateLifecycle.uncertain
        : failure.retry == RetryClassification.transient
        ? DesiredStateLifecycle.pending
        : DesiredStateLifecycle.failed,
    transitionedAt: resolvedAt,
    failureCode: uncertain || failure.retry != RetryClassification.transient
        ? failure.code
        : null,
  );

  @override
  Future<void> recoverCreateAttempts({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) async {
    await _desired.recoverInFlightCreates(
      accountId: accountId,
      recoveredAt: recoveredAt,
    );
  }

  @override
  Future<void> recoverUpdateAttempts({
    required AccountId accountId,
    required DateTime recoveredAt,
  }) async {
    await _desired.recoverInFlightUpdates(
      accountId: accountId,
      recoveredAt: recoveredAt,
    );
  }

  @override
  Future<int> confirmNoOpUpdates({
    required AccountId accountId,
    required String runId,
    required DateTime confirmedAt,
  }) => _desired.confirmNoOpUpdates(
    accountId: accountId,
    runId: runId,
    confirmedAt: confirmedAt,
  );

  @override
  Future<ContentReconciliationSummary> reconcileContent({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  }) => _desired.reconcileContent(
    accountId: accountId,
    runId: runId,
    reconciledAt: reconciledAt,
  );

  @override
  Future<void> prepareTaskUpdateReplan({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required DateTime replannedAt,
  }) => _desired.prepareTaskUpdateReplan(
    accountId: accountId,
    attemptId: claim.attemptId,
    generation: claim.generation,
    replannedAt: replannedAt,
  );

  @override
  Future<UpdateOperationClaim?> claimNextUpdate({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  }) => _database.transaction(() async {
    final candidate = await _desired.readNextUpdateCandidate(accountId, runId);
    if (candidate == null) return null;
    switch (candidate.resourceType) {
      case DesiredUpdateResourceType.task:
        final attempt = await _desired.claimTask(
          accountId: accountId,
          taskId: candidate.taskId!,
          claimedAt: claimedAt,
        );
        return UpdateOperationClaim.task(
          attemptId: attempt.id,
          generation: attempt.generation,
          taskListId: candidate.taskListId,
          taskListRemoteId: RemoteTaskListId(candidate.taskListRemoteId.value),
          taskId: candidate.taskId!,
          taskRemoteId: RemoteTaskId(candidate.taskRemoteId!.value),
          parentTaskId: candidate.parentTaskId,
          parentRemoteId: candidate.parentRemoteId == null
              ? null
              : RemoteTaskId(candidate.parentRemoteId!.value),
          etag: candidate.etag!,
          title: attempt.title!,
          notes: attempt.notes,
          status: attempt.status!,
          due: attempt.due,
        );
      case DesiredUpdateResourceType.taskList:
        final attempt = await _desired.claimTaskList(
          accountId: accountId,
          taskListId: candidate.taskListId,
          claimedAt: claimedAt,
        );
        return UpdateOperationClaim.taskList(
          attemptId: attempt.id,
          generation: attempt.generation,
          taskListId: candidate.taskListId,
          taskListRemoteId: RemoteTaskListId(candidate.taskListRemoteId.value),
          title: attempt.title!,
        );
    }
  });

  @override
  Future<void> acknowledgeTaskListUpdate({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required RemoteTaskList remote,
    required String observationId,
    required DateTime acknowledgedAt,
  }) async {
    if (remote.id != claim.taskListRemoteId) {
      throw const DesiredStateInvariantException(
        'update_task_list_response_mismatch',
      );
    }
    await _desired.acknowledgeTaskList(
      accountId: accountId,
      attemptId: claim.attemptId,
      remoteId: TaskListRemoteId(remote.id.value),
      title: remote.title,
      etag: remote.etag,
      remoteUpdatedAt: remote.updated,
      observedPublicationId: observationId,
      acknowledgedAt: acknowledgedAt,
      resolution: remote.title == claim.title
          ? DesiredStateLifecycle.confirmed
          : DesiredStateLifecycle.superseded,
    );
  }

  @override
  Future<void> acknowledgeTaskUpdate({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  }) async {
    if (remote.id != claim.taskRemoteId ||
        remote.parentId != claim.parentRemoteId) {
      throw const DesiredStateInvariantException(
        'update_task_response_mismatch',
      );
    }
    await _desired.acknowledgeTask(
      accountId: accountId,
      attemptId: claim.attemptId,
      remoteId: TaskRemoteId(remote.id.value),
      taskListId: claim.taskListId,
      parentTaskId: claim.parentTaskId,
      title: remote.title,
      notes: remote.notes,
      status: _taskStatus(remote.status),
      due: _taskDate(remote.due),
      position: remote.position,
      etag: remote.etag,
      remoteUpdatedAt: remote.updated,
      observedPublicationId: observationId,
      acknowledgedAt: acknowledgedAt,
      resolution:
          remote.title == claim.title &&
              remote.notes == claim.notes &&
              _taskStatus(remote.status) == claim.status &&
              _taskDate(remote.due) == claim.due
          ? DesiredStateLifecycle.confirmed
          : DesiredStateLifecycle.superseded,
    );
  }

  @override
  Future<void> resolveUpdateFailure({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  }) => _desired.transitionAttempt(
    accountId: accountId,
    attemptId: claim.attemptId,
    state: uncertain
        ? DesiredStateLifecycle.uncertain
        : failure.retry == RetryClassification.transient
        ? DesiredStateLifecycle.pending
        : DesiredStateLifecycle.failed,
    transitionedAt: resolvedAt,
    failureCode: uncertain || failure.retry != RetryClassification.transient
        ? failure.code
        : null,
  );

  @override
  Future<CreateOperationClaim?> claimNextCreate({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  }) => _database.transaction(() async {
    final candidate = await _desired.readNextCreateCandidate(accountId, runId);
    if (candidate == null) return null;
    switch (candidate.resourceType) {
      case DesiredCreateResourceType.taskList:
        final attempt = await _desired.claimTaskList(
          accountId: accountId,
          taskListId: candidate.taskListId,
          claimedAt: claimedAt,
        );
        return CreateOperationClaim.taskList(
          attemptId: attempt.id,
          generation: attempt.generation,
          taskListId: candidate.taskListId,
          title: attempt.title!,
        );
      case DesiredCreateResourceType.task:
        final attempt = await _desired.claimTask(
          accountId: accountId,
          taskId: candidate.taskId!,
          claimedAt: claimedAt,
        );
        return CreateOperationClaim.task(
          attemptId: attempt.id,
          generation: attempt.generation,
          taskListId: candidate.taskListId,
          taskId: candidate.taskId!,
          parentTaskId: candidate.parentTaskId,
          taskListRemoteId: RemoteTaskListId(candidate.taskListRemoteId!.value),
          parentRemoteId: candidate.parentRemoteId == null
              ? null
              : RemoteTaskId(candidate.parentRemoteId!.value),
          previousTaskId: candidate.previousTaskId,
          previousRemoteId: candidate.previousRemoteId == null
              ? null
              : RemoteTaskId(candidate.previousRemoteId!.value),
          title: attempt.title!,
          notes: attempt.notes,
          status: attempt.status!,
          due: attempt.due,
        );
    }
  });

  @override
  Future<void> acknowledgeTaskListCreate({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required RemoteTaskList remote,
    required String observationId,
    required DateTime acknowledgedAt,
  }) => _desired.acknowledgeTaskList(
    accountId: accountId,
    attemptId: claim.attemptId,
    remoteId: TaskListRemoteId(remote.id.value),
    title: remote.title,
    etag: remote.etag,
    remoteUpdatedAt: remote.updated,
    observedPublicationId: observationId,
    acknowledgedAt: acknowledgedAt,
  );

  @override
  Future<void> acknowledgeTaskCreate({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  }) async {
    if (remote.parentId != claim.parentRemoteId) {
      throw const DesiredStateInvariantException(
        'create_parent_response_mismatch',
      );
    }
    await _desired.acknowledgeTask(
      accountId: accountId,
      attemptId: claim.attemptId,
      remoteId: TaskRemoteId(remote.id.value),
      taskListId: claim.taskListId,
      parentTaskId: claim.parentTaskId,
      title: remote.title,
      notes: remote.notes,
      status: _taskStatus(remote.status),
      due: _taskDate(remote.due),
      position: remote.position,
      etag: remote.etag,
      remoteUpdatedAt: remote.updated,
      observedPublicationId: observationId,
      acknowledgedAt: acknowledgedAt,
    );
  }

  @override
  Future<void> resolveCreateFailure({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  }) => _desired.transitionAttempt(
    accountId: accountId,
    attemptId: claim.attemptId,
    state: uncertain
        ? DesiredStateLifecycle.uncertain
        : failure.retry == RetryClassification.transient
        ? DesiredStateLifecycle.pending
        : DesiredStateLifecycle.failed,
    transitionedAt: resolvedAt,
    failureCode: uncertain || failure.retry != RetryClassification.transient
        ? failure.code
        : null,
  );

  @override
  Future<void> recoverReadRun(AccountId accountId) async {
    // Read requests have no remote side effect. An interrupted publication is
    // deliberately left incomplete and a new run starts a fresh publication.
    await readEligibility(accountId);
  }

  @override
  Future<ReadSyncEligibility> readEligibility(AccountId accountId) async {
    final row = await _database
        .customSelect(
          '''
          SELECT
            a.google_subject,
            COALESCE(p.sync_enabled, 1) AS sync_enabled,
            COALESCE(f.reauthorization_required, 0)
              AS reauthorization_required,
            COALESCE(f.automatic_retry_exhausted, 0)
              AS automatic_retry_exhausted
          FROM accounts a
          LEFT JOIN account_preferences p ON p.account_id = a.id
          LEFT JOIN sync_facts f ON f.account_id = a.id
          WHERE a.id = ?1
          ''',
          variables: <Variable<Object>>[Variable<int>(accountId.value)],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.accounts,
            _database.accountPreferenceRows,
            _database.syncFactRows,
          },
        )
        .getSingleOrNull();
    if (row == null) {
      return const ReadSyncEligibility(
        exists: false,
        syncEnabled: false,
        reauthorizationRequired: false,
        automaticRetryExhausted: false,
        googleSubject: null,
      );
    }
    return ReadSyncEligibility(
      exists: true,
      syncEnabled: row.read<bool>('sync_enabled'),
      reauthorizationRequired: row.read<bool>('reauthorization_required'),
      automaticRetryExhausted: row.read<bool>('automatic_retry_exhausted'),
      googleSubject: row.read<String>('google_subject'),
    );
  }

  @override
  Future<void> beginReadRun({
    required AccountId accountId,
    required SyncRunId runId,
    required Set<String> triggers,
    required DateTime startedAt,
  }) {
    // Schema v1 uses the publication ID as the durable read-run identity. The
    // trigger set and start time are intentionally not persisted until the
    // accepted sync-attempt schema lands in its owning slice.
    return _database.transaction(() async {
      await _requireAccount(accountId);
      await _ensureSyncFacts(accountId);
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        const SyncFactRowsCompanion(requiredScopeIncomplete: Value<bool>(true)),
      );
      await _cache.putScopeCompleteness(
        accountId: accountId,
        scope: const CacheScope.taskLists(),
        publicationId: runId.value,
        isComplete: false,
      );
    });
  }

  @override
  Future<PagePublicationResult<PublishedTaskList>> publishTaskListPage({
    required AccountId accountId,
    required SyncRunId runId,
    required List<RemoteTaskList> items,
    required PageToken? nextPageToken,
    required String? collectionEtag,
  }) {
    return _database.transaction(() async {
      final published = <PublishedTaskList>[];
      var writes = 0;
      for (final item in items) {
        final existing =
            await (_database.select(_database.taskListCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.remoteId.equals(item.id.value),
                ))
                .getSingleOrNull();
        final TaskListId localId;
        if (existing == null) {
          localId = await _cache.putTaskList(
            accountId: accountId,
            remoteId: TaskListRemoteId(item.id.value),
            title: item.title,
          );
          writes += 1;
        } else {
          localId = TaskListId(existing.id);
          final hasUnresolvedLocalTitle =
              await (_database.select(_database.desiredStateRows)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.resourceType.equals('task_list') &
                        row.targetTaskListId.equals(existing.id) &
                        row.desiredLifecycle.equals('present') &
                        row.state.isIn(const <String>[
                          'pending',
                          'in_flight',
                          'uncertain',
                          'failed',
                        ]),
                  ))
                  .getSingleOrNull() !=
              null;
          final hasUnresolvedDelete =
              await (_database.select(_database.desiredStateRows)..where(
                    (row) =>
                        row.accountId.equals(accountId.value) &
                        row.resourceType.equals('task_list') &
                        row.targetTaskListId.equals(existing.id) &
                        row.desiredLifecycle.equals('deleted') &
                        row.state.isIn(const <String>[
                          'pending',
                          'in_flight',
                          'uncertain',
                          'failed',
                        ]),
                  ))
                  .getSingleOrNull() !=
              null;
          final desiredProjection = hasUnresolvedDelete
              ? CacheProjection.deleted.name
              : CacheProjection.supported.name;
          final projectionChanged = existing.projection != desiredProjection;
          final titleChanged =
              !hasUnresolvedLocalTitle && existing.title != item.title;
          if (titleChanged || projectionChanged) {
            await (_database.update(_database.taskListCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.id.equals(existing.id),
                ))
                .write(
                  titleChanged
                      ? TaskListCacheRowsCompanion(
                          title: Value<String>(item.title),
                          projection: Value<String>(desiredProjection),
                        )
                      : TaskListCacheRowsCompanion(
                          projection: Value<String>(desiredProjection),
                        ),
                );
            writes += 1;
          }
        }
        await _cache.putTaskListRemoteBase(
          accountId: accountId,
          taskListId: localId,
          remoteId: TaskListRemoteId(item.id.value),
          title: item.title,
          etag: item.etag,
          remoteUpdatedAt: item.updated,
          observedPublicationId: runId.value,
        );
        published.add(PublishedTaskList(localId: localId, remoteId: item.id));
      }
      await _cache.putScopeCompleteness(
        accountId: accountId,
        scope: const CacheScope.taskLists(),
        publicationId: runId.value,
        nextPageToken: nextPageToken?.value,
        collectionEtag: collectionEtag,
        isComplete: nextPageToken == null,
      );
      return PagePublicationResult<PublishedTaskList>(
        values: published,
        resourceWrites: writes,
      );
    });
  }

  @override
  Future<PagePublicationResult<void>> publishTaskPage({
    required AccountId accountId,
    required SyncRunId runId,
    required PublishedTaskList taskList,
    required List<RemoteTask> items,
    required PageToken? nextPageToken,
    required String? collectionEtag,
  }) {
    return _database.transaction(() async {
      var writes = 0;
      for (final item in _parentsBeforeChildren(items)) {
        final existing =
            await (_database.select(_database.taskCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.remoteId.equals(item.id.value),
                ))
                .getSingleOrNull();
        final parentId = await _parentLocalId(
          accountId: accountId,
          remoteTask: item,
        );
        final TaskId localId;
        switch (item) {
          case RemoteLiveTask():
            final status = _taskStatus(item.status);
            final due = _taskDate(item.due);
            if (existing == null) {
              localId = await _cache.putTask(
                accountId: accountId,
                taskListId: taskList.localId,
                parentTaskId: parentId,
                remoteId: TaskRemoteId(item.id.value),
                title: item.title,
                notes: item.notes,
                status: status,
                due: due,
                position: item.position,
              );
              writes += 1;
            } else {
              localId = TaskId(existing.id);
              await _deletes.preserveMovedDeleteSurvivor(
                accountId: accountId,
                taskId: localId,
                currentTaskListId: taskList.localId,
                currentParentTaskId: parentId,
              );
              final protectedByDelete = await _deletes
                  .isTaskProtectedByDeleteSnapshot(
                    accountId: accountId,
                    taskId: localId,
                  );
              final hasUnresolvedLocalContent =
                  await (_database.select(_database.desiredStateRows)..where(
                        (row) =>
                            row.accountId.equals(accountId.value) &
                            row.resourceType.equals('task') &
                            row.targetTaskId.equals(existing.id) &
                            row.desiredLifecycle.equals('present') &
                            row.contentDirty.equals(true) &
                            row.state.isIn(const <String>[
                              'pending',
                              'in_flight',
                              'uncertain',
                              'failed',
                            ]),
                      ))
                      .getSingleOrNull() !=
                  null;
              final protectedStructureIds = <int>{
                existing.id,
                ?existing.parentTaskId,
              };
              final hasUnresolvedLocalStructure =
                  await (_database.select(_database.desiredStateRows)..where(
                        (row) =>
                            row.accountId.equals(accountId.value) &
                            row.resourceType.equals('task') &
                            row.targetTaskId.isIn(protectedStructureIds) &
                            row.desiredLifecycle.equals('present') &
                            row.structureDirty.equals(true) &
                            row.state.isIn(const <String>[
                              'pending',
                              'in_flight',
                              'uncertain',
                              'failed',
                            ]),
                      ))
                      .getSingleOrNull() !=
                  null;
              final structureChanged =
                  !hasUnresolvedLocalStructure &&
                  (existing.taskListId != taskList.localId.value ||
                      existing.parentTaskId != parentId?.value ||
                      existing.position != item.position ||
                      existing.projection !=
                          (protectedByDelete
                              ? CacheProjection.deleted.name
                              : CacheProjection.supported.name));
              final contentChanged =
                  !hasUnresolvedLocalContent &&
                  (existing.title != item.title ||
                      existing.notes != item.notes ||
                      existing.status != _statusValue(status) ||
                      existing.dueEpochDay != _epochDay(due));
              if (structureChanged || contentChanged) {
                await (_database.update(_database.taskCacheRows)..where(
                      (row) =>
                          row.accountId.equals(accountId.value) &
                          row.id.equals(existing.id),
                    ))
                    .write(
                      TaskCacheRowsCompanion(
                        taskListId: hasUnresolvedLocalStructure
                            ? const Value<int>.absent()
                            : Value<int>(taskList.localId.value),
                        parentTaskId: hasUnresolvedLocalStructure
                            ? const Value<int?>.absent()
                            : Value<int?>(parentId?.value),
                        title: hasUnresolvedLocalContent
                            ? const Value<String>.absent()
                            : Value<String>(item.title),
                        notes: hasUnresolvedLocalContent
                            ? const Value<String?>.absent()
                            : Value<String?>(item.notes),
                        status: hasUnresolvedLocalContent
                            ? const Value<String>.absent()
                            : Value<String>(_statusValue(status)),
                        dueEpochDay: hasUnresolvedLocalContent
                            ? const Value<int?>.absent()
                            : Value<int?>(_epochDay(due)),
                        position: hasUnresolvedLocalStructure
                            ? const Value<String>.absent()
                            : Value<String>(item.position),
                        projection: hasUnresolvedLocalStructure
                            ? const Value<String>.absent()
                            : Value<String>(
                                protectedByDelete
                                    ? CacheProjection.deleted.name
                                    : CacheProjection.supported.name,
                              ),
                      ),
                    );
                writes += 1;
              }
            }
            await _cache.putTaskRemoteBase(
              accountId: accountId,
              taskId: localId,
              taskListId: taskList.localId,
              parentTaskId: parentId,
              remoteId: TaskRemoteId(item.id.value),
              observedPublicationId: runId.value,
              deleted: false,
              title: item.title,
              notes: item.notes,
              status: status,
              due: due,
              position: item.position,
              completedAt: item.completed,
              hidden: item.hidden,
              etag: item.etag,
              remoteUpdatedAt: item.updated,
              selfLink: item.selfLink,
              links: _links(item.links),
              webViewLink: item.webViewLink,
            );
          case RemoteTaskTombstone():
            if (existing == null) {
              localId = await _cache.putTask(
                accountId: accountId,
                taskListId: taskList.localId,
                remoteId: TaskRemoteId(item.id.value),
                title: item.retainedTitle ?? '',
                notes: item.retainedNotes,
                status: _taskStatus(
                  item.retainedStatus ?? RemoteTaskStatus.needsAction,
                ),
                due: _taskDate(item.retainedDue),
                position: item.retainedPosition ?? 'deleted',
                projection: CacheProjection.deleted,
              );
              writes += 1;
            } else {
              localId = TaskId(existing.id);
              if (existing.projection != CacheProjection.deleted.name ||
                  existing.parentTaskId != null) {
                await (_database.update(_database.taskCacheRows)..where(
                      (row) =>
                          row.accountId.equals(accountId.value) &
                          row.id.equals(existing.id),
                    ))
                    .write(
                      TaskCacheRowsCompanion(
                        parentTaskId: const Value<int?>(null),
                        projection: Value<String>(CacheProjection.deleted.name),
                      ),
                    );
                writes += 1;
              }
            }
            await _cache.putTaskRemoteBase(
              accountId: accountId,
              taskId: localId,
              taskListId: taskList.localId,
              remoteId: TaskRemoteId(item.id.value),
              observedPublicationId: runId.value,
              deleted: true,
              title: item.retainedTitle,
              notes: item.retainedNotes,
              status: item.retainedStatus == null
                  ? null
                  : _taskStatus(item.retainedStatus!),
              due: _taskDate(item.retainedDue),
              position: item.retainedPosition,
              completedAt: item.retainedCompleted,
              hidden: item.hidden,
              etag: item.etag,
              remoteUpdatedAt: item.updated,
              selfLink: item.selfLink,
              links: _links(item.retainedLinks),
              webViewLink: item.retainedWebViewLink,
            );
        }
      }
      await _cache.putScopeCompleteness(
        accountId: accountId,
        scope: CacheScope.tasks(taskList.localId),
        publicationId: runId.value,
        nextPageToken: nextPageToken?.value,
        collectionEtag: collectionEtag,
        isComplete: nextPageToken == null,
      );
      return PagePublicationResult<void>(
        values: const <void>[],
        resourceWrites: writes,
      );
    });
  }

  @override
  Future<bool> isPublicationComplete({
    required AccountId accountId,
    required SyncRunId runId,
  }) async {
    final row = await _database
        .customSelect(
          '''
      SELECT
        EXISTS (
          SELECT 1 FROM scope_completeness list_scope
          WHERE list_scope.account_id = ?1
            AND list_scope.scope_kind = 'task_lists'
            AND list_scope.publication_id = ?2
            AND list_scope.is_complete = 1
        ) AS list_complete,
        EXISTS (
          SELECT 1 FROM task_list_remote_bases selected_list
          WHERE selected_list.account_id = ?1
            AND selected_list.observed_publication_id = ?2
            AND selected_list.deleted = 0
            AND NOT EXISTS (
              SELECT 1 FROM scope_completeness task_scope
              WHERE task_scope.account_id = ?1
                AND task_scope.scope_kind = 'tasks'
                AND task_scope.task_list_id = selected_list.task_list_id
                AND task_scope.publication_id = ?2
                AND task_scope.is_complete = 1
            )
        ) AS missing_task_scope
      ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<String>(runId.value),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.scopeCompletenessRows,
            _database.taskListRemoteBases,
          },
        )
        .getSingle();
    return row.read<bool>('list_complete') &&
        !row.read<bool>('missing_task_scope');
  }

  @override
  Future<void> finalizeReadSuccess({
    required AccountId accountId,
    required SyncRunId runId,
    required DateTime completedAt,
  }) async {
    await _database.transaction(() async {
      if (!await isPublicationComplete(accountId: accountId, runId: runId)) {
        throw const CacheInvariantException('publication_not_complete');
      }
      final prior = await _health.watchFacts(accountId).first;
      await _health.writeFacts(
        accountId,
        _copyFacts(
          prior,
          lastSuccessfulSyncAt: completedAt.toUtc(),
          clearFailure: true,
          requiredScopeIncomplete: false,
        ),
      );
      await (_database.update(
        _database.syncFactRows,
      )..where((row) => row.accountId.equals(accountId.value))).write(
        const SyncFactRowsCompanion(
          retryWaiting: Value<bool>(false),
          automaticRetryExhausted: Value<bool>(false),
          retryEpisodeStartedAt: Value<DateTime?>(null),
          retryEpisodeDeadlineAt: Value<DateTime?>(null),
          retryNextAttemptAt: Value<DateTime?>(null),
          retryServerNotBeforeAt: Value<DateTime?>(null),
          retryLastObservedAt: Value<DateTime?>(null),
          retryAttemptCount: Value<int>(0),
        ),
      );
    });
  }

  @override
  Future<void> finalizeReadFailure({
    required AccountId accountId,
    required SyncRunId runId,
    required DateTime failedAt,
    required Failure failure,
  }) async {
    final prior = await _health.watchFacts(accountId).first;
    await _health.writeFacts(
      accountId,
      _copyFacts(
        prior,
        latestFailure: SyncFailureFact(
          reason: _syncFailureReason(failure),
          occurredAt: failedAt.toUtc(),
          diagnosticCode: failure.code,
          action: _failureAction(failure),
        ),
        requiredScopeIncomplete: true,
      ),
    );
  }

  Future<TaskStructureSnapshot?> _structureSnapshot(
    TaskRemoteBase task, {
    required String runId,
  }) async {
    if (task.position == null) return null;
    final siblings =
        await (_database.select(_database.taskRemoteBases)
              ..where(
                (row) =>
                    row.accountId.equals(task.accountId) &
                    row.taskListId.equals(task.taskListId) &
                    (task.parentTaskId == null
                        ? row.parentTaskId.isNull()
                        : row.parentTaskId.equals(task.parentTaskId!)) &
                    row.deleted.equals(false) &
                    row.observedPublicationId.equals(runId),
              )
              ..orderBy(<OrderingTerm Function($TaskRemoteBasesTable)>[
                (row) => OrderingTerm.asc(row.position),
                (row) => OrderingTerm.asc(row.taskId),
              ]))
            .get();
    final index = siblings.indexWhere((row) => row.taskId == task.taskId);
    if (index < 0) return null;
    return TaskStructureSnapshot(
      taskListId: TaskListId(task.taskListId),
      parentTaskId: task.parentTaskId == null
          ? null
          : TaskId(task.parentTaskId!),
      previousTaskId: index == 0 ? null : TaskId(siblings[index - 1].taskId),
      siblingOrderFingerprint: siblings
          .map((row) => '${row.taskId}:${row.position}')
          .join('|'),
    );
  }

  Future<bool> _placementReferencesAreCurrent({
    required AccountId accountId,
    required TaskPlacement placement,
    required String runId,
    required TaskId targetTaskId,
  }) async {
    final parent = await _currentRemoteTask(
      accountId,
      placement.parentTaskId?.value,
      runId,
    );
    if (placement.parentTaskId != null &&
        (parent == null ||
            parent.taskListId != placement.taskListId.value ||
            parent.parentTaskId != null)) {
      return false;
    }
    final previous = await _currentRemoteTask(
      accountId,
      placement.previousTaskId?.value,
      runId,
    );
    if (placement.previousTaskId != null &&
        (previous == null ||
            previous.taskId == targetTaskId.value ||
            previous.taskListId != placement.taskListId.value ||
            previous.parentTaskId != placement.parentTaskId?.value)) {
      return false;
    }
    return true;
  }

  Future<TaskRemoteBase?> _currentRemoteTask(
    AccountId accountId,
    int? taskId,
    String runId,
  ) {
    if (taskId == null) return Future<TaskRemoteBase?>.value();
    return (_database.select(_database.taskRemoteBases)..where(
          (row) =>
              row.accountId.equals(accountId.value) &
              row.taskId.equals(taskId) &
              row.deleted.equals(false) &
              row.observedPublicationId.equals(runId),
        ))
        .getSingleOrNull();
  }

  Future<TaskListCacheRow?> _taskListRow(
    AccountId accountId,
    TaskListId taskListId,
  ) =>
      (_database.select(_database.taskListCacheRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.id.equals(taskListId.value) &
                row.projection.equals(CacheProjection.supported.name),
          ))
          .getSingleOrNull();

  Future<void> _rebasePendingStructure({
    required DesiredStateRow desired,
    required TaskRemoteBase currentBase,
    required TaskStructureSnapshot remote,
    required DateTime transitionedAt,
  }) async {
    await (_database.update(
      _database.desiredStateRows,
    )..where((row) => row.id.equals(desired.id))).write(
      DesiredStateRowsCompanion(
        baseEtag: Value<String?>(currentBase.etag),
        baseRemoteUpdatedAt: Value<DateTime?>(
          currentBase.remoteUpdatedAt?.toUtc(),
        ),
        baseObservedPublicationId: Value<String>(
          currentBase.observedPublicationId,
        ),
        baseTaskListId: Value<int>(remote.taskListId.value),
        baseParentTaskId: Value<int?>(remote.parentTaskId?.value),
        basePreviousTaskId: Value<int?>(remote.previousTaskId?.value),
        basePosition: Value<String>(currentBase.position!),
        baseSiblingOrder: Value<String>(remote.siblingOrderFingerprint),
        state: const Value<String>('pending'),
        failureCode: const Value<String?>(null),
        lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
      ),
    );
    await _resolveStructureAttempts(
      desired,
      DesiredStateLifecycle.superseded,
      transitionedAt,
    );
  }

  Future<void> _resolveObservedStructure({
    required DesiredStateRow desired,
    required TaskRemoteBase currentBase,
    required TaskStructureSnapshot remote,
    required DesiredStateLifecycle resolution,
    required DateTime transitionedAt,
  }) async {
    final taskId = TaskId(desired.targetTaskId!);
    await _moveProjectedSubtree(
      accountId: AccountId(desired.accountId),
      taskId: taskId,
      taskListId: remote.taskListId,
      parentTaskId: remote.parentTaskId,
      position: currentBase.position!,
    );
    if (!desired.contentDirty &&
        currentBase.title != null &&
        currentBase.status != null) {
      await (_database.update(_database.taskCacheRows)..where(
            (row) =>
                row.accountId.equals(desired.accountId) &
                row.id.equals(taskId.value),
          ))
          .write(
            TaskCacheRowsCompanion(
              title: Value<String>(currentBase.title!),
              notes: Value<String?>(currentBase.notes),
              status: Value<String>(currentBase.status!),
              dueEpochDay: Value<int?>(currentBase.dueEpochDay),
            ),
          );
    }
    final remainingContent = desired.contentDirty;
    await (_database.update(
      _database.desiredStateRows,
    )..where((row) => row.id.equals(desired.id))).write(
      DesiredStateRowsCompanion(
        desiredTaskListId: Value<int>(remote.taskListId.value),
        desiredParentTaskId: Value<int?>(remote.parentTaskId?.value),
        desiredPreviousTaskId: Value<int?>(remote.previousTaskId?.value),
        structureDirty: remainingContent
            ? const Value<bool>(false)
            : const Value<bool>.absent(),
        baseEtag: Value<String?>(currentBase.etag),
        baseRemoteUpdatedAt: Value<DateTime?>(
          currentBase.remoteUpdatedAt?.toUtc(),
        ),
        baseObservedPublicationId: Value<String>(
          currentBase.observedPublicationId,
        ),
        baseTaskListId: Value<int>(remote.taskListId.value),
        baseParentTaskId: Value<int?>(remote.parentTaskId?.value),
        basePreviousTaskId: Value<int?>(remote.previousTaskId?.value),
        basePosition: Value<String>(currentBase.position!),
        baseSiblingOrder: Value<String>(remote.siblingOrderFingerprint),
        state: Value<String>(
          remainingContent ? 'pending' : _stateValue(resolution),
        ),
        failureCode: const Value<String?>(null),
        lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
      ),
    );
    await _resolveStructureAttempts(desired, resolution, transitionedAt);
  }

  Future<void> _resolveStructureAttempts(
    DesiredStateRow desired,
    DesiredStateLifecycle resolution,
    DateTime transitionedAt,
  ) =>
      (_database.update(_database.desiredStateAttemptRows)..where(
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
              state: Value<String>(_stateValue(resolution)),
              failureCode: const Value<String?>(null),
              lastTransitionAt: Value<DateTime>(transitionedAt.toUtc()),
            ),
          );

  Future<void> _moveProjectedSubtree({
    required AccountId accountId,
    required TaskId taskId,
    required TaskListId taskListId,
    required TaskId? parentTaskId,
    required String position,
    RemoteLiveTask? content,
  }) async {
    await _database.customUpdate(
      '''
      UPDATE tasks
      SET task_list_id = ?1,
          parent_task_id = CASE
            WHEN id = ?2 THEN NULLIF(?3, 0)
            ELSE ?2
          END,
          position = CASE WHEN id = ?2 THEN ?4 ELSE position END
      WHERE account_id = ?5
        AND (id = ?2 OR parent_task_id = ?2)
      ''',
      variables: <Variable<Object>>[
        Variable<int>(taskListId.value),
        Variable<int>(taskId.value),
        Variable<int>(parentTaskId?.value ?? 0),
        Variable<String>(position),
        Variable<int>(accountId.value),
      ],
      updates: <TableInfo<Table, Object?>>{_database.taskCacheRows},
    );
    if (content != null) {
      await (_database.update(
        _database.taskCacheRows,
      )..where((row) => row.id.equals(taskId.value))).write(
        TaskCacheRowsCompanion(
          title: Value<String>(content.title),
          notes: Value<String?>(content.notes),
          status: Value<String>(_statusValue(_taskStatus(content.status))),
          dueEpochDay: Value<int?>(_epochDay(_taskDate(content.due))),
        ),
      );
    }
  }

  Future<void> _requireAccount(AccountId accountId) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
    if (account == null) {
      throw const CacheInvariantException('account_not_found');
    }
  }

  Future<void> _ensureSyncFacts(AccountId accountId) async {
    await _database
        .into(_database.syncFactRows)
        .insert(
          SyncFactRowsCompanion.insert(accountId: Value<int>(accountId.value)),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<TaskId?> _parentLocalId({
    required AccountId accountId,
    required RemoteTask remoteTask,
  }) async {
    final remoteParent = switch (remoteTask) {
      RemoteLiveTask(:final parentId) => parentId,
      RemoteTaskTombstone() => null,
    };
    if (remoteParent == null) return null;
    final row =
        await (_database.select(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.remoteId.equals(remoteParent.value),
            ))
            .getSingleOrNull();
    if (row == null || row.parentTaskId != null) {
      throw const CacheInvariantException('unsupported_task_parent');
    }
    return TaskId(row.id);
  }
}

List<RemoteTask> _parentsBeforeChildren(List<RemoteTask> items) {
  final ids = items.map((task) => task.id.value).toSet();
  final roots = <RemoteTask>[];
  final children = <RemoteTask>[];
  for (final item in items) {
    final parentId = switch (item) {
      RemoteLiveTask(:final parentId) => parentId?.value,
      RemoteTaskTombstone() => null,
    };
    (parentId != null && ids.contains(parentId) ? children : roots).add(item);
  }
  return <RemoteTask>[...roots, ...children];
}

PersistedSyncFacts _copyFacts(
  PersistedSyncFacts value, {
  DateTime? lastSuccessfulSyncAt,
  SyncFailureFact? latestFailure,
  bool clearFailure = false,
  bool? requiredScopeIncomplete,
}) => PersistedSyncFacts(
  syncEnabled: value.syncEnabled,
  reauthorizationRequired: value.reauthorizationRequired,
  lastSuccessfulSyncAt: lastSuccessfulSyncAt ?? value.lastSuccessfulSyncAt,
  latestFailure: clearFailure ? null : latestFailure ?? value.latestFailure,
  counts: value.counts,
  retryWaiting: value.retryWaiting,
  automaticRetryExhausted: value.automaticRetryExhausted,
  retryNextAttemptAt: value.retryNextAttemptAt,
  retryAttemptCount: value.retryAttemptCount,
  requiredScopeIncomplete:
      requiredScopeIncomplete ?? value.requiredScopeIncomplete,
  followUpRequired: value.followUpRequired,
);

SyncFailureReason _syncFailureReason(Failure failure) =>
    switch (failure.category) {
      FailureCategory.network => SyncFailureReason.noConnection,
      FailureCategory.rateLimit ||
      FailureCategory.remote => SyncFailureReason.remoteFailure,
      _ => SyncFailureReason.applicationFailure,
    };

SyncHealthAction _failureAction(Failure failure) =>
    failure.retry == RetryClassification.transient ||
        failure.action == FailureAction.retry
    ? SyncHealthAction.retry
    : SyncHealthAction.none;

TaskStatus _taskStatus(RemoteTaskStatus status) => switch (status) {
  RemoteTaskStatus.needsAction => TaskStatus.needsAction,
  RemoteTaskStatus.completed => TaskStatus.completed,
};

String _statusValue(TaskStatus status) => switch (status) {
  TaskStatus.needsAction => 'needs_action',
  TaskStatus.completed => 'completed',
};

TaskDate? _taskDate(RemoteDate? value) =>
    value == null ? null : TaskDate(value.year, value.month, value.day);

int? _epochDay(TaskDate? value) => value == null
    ? null
    : DateTime.utc(
        value.year,
        value.month,
        value.day,
      ).difference(DateTime.utc(1970)).inDays;

List<TaskRemoteLinkRecord> _links(List<RemoteTaskLink> values) => values
    .map(
      (value) => TaskRemoteLinkRecord(
        type: value.type,
        description: value.description,
        link: value.link,
      ),
    )
    .toList(growable: false);

String _stateValue(DesiredStateLifecycle state) => switch (state) {
  DesiredStateLifecycle.pending => 'pending',
  DesiredStateLifecycle.inFlight => 'in_flight',
  DesiredStateLifecycle.uncertain => 'uncertain',
  DesiredStateLifecycle.failed => 'failed',
  DesiredStateLifecycle.confirmed => 'confirmed',
  DesiredStateLifecycle.superseded => 'superseded',
};

const Failure _invalidStructureBaseFailure = Failure(
  code: 'sync.structure_base_invalid',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The task placement was not synchronized.',
  safeSummary: 'Required structural reconciliation evidence is incomplete.',
);
