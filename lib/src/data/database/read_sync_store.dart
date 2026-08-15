import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../data/google_tasks/dto.dart';
import '../../domain/model/tasks.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/run.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'sync_health_dao.dart';

final class DatabaseReadSyncStore implements ReadSyncStore {
  DatabaseReadSyncStore(this._database)
    : _cache = CacheDao(_database),
      _health = SyncHealthDao(_database);

  final AppDatabase _database;
  final CacheDao _cache;
  final SyncHealthDao _health;

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
              AS reauthorization_required
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
        googleSubject: null,
      );
    }
    return ReadSyncEligibility(
      exists: true,
      syncEnabled: row.read<bool>('sync_enabled'),
      reauthorizationRequired: row.read<bool>('reauthorization_required'),
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
          final projectionChanged =
              existing.projection != CacheProjection.supported.name;
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
                          projection: Value<String>(
                            CacheProjection.supported.name,
                          ),
                        )
                      : TaskListCacheRowsCompanion(
                          projection: Value<String>(
                            CacheProjection.supported.name,
                          ),
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
      for (final item in items) {
        final existing =
            await (_database.select(_database.taskCacheRows)..where(
                  (row) =>
                      row.accountId.equals(accountId.value) &
                      row.remoteId.equals(item.id.value),
                ))
                .getSingleOrNull();
        final parentId = await _parentLocalId(
          accountId: accountId,
          taskListId: taskList.localId,
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
              if (!_sameLiveProjection(
                existing,
                taskList.localId,
                parentId,
                item,
              )) {
                await (_database.update(_database.taskCacheRows)..where(
                      (row) =>
                          row.accountId.equals(accountId.value) &
                          row.id.equals(existing.id),
                    ))
                    .write(
                      TaskCacheRowsCompanion(
                        taskListId: Value<int>(taskList.localId.value),
                        parentTaskId: Value<int?>(parentId?.value),
                        title: Value<String>(item.title),
                        notes: Value<String?>(item.notes),
                        status: Value<String>(_statusValue(status)),
                        dueEpochDay: Value<int?>(_epochDay(due)),
                        position: Value<String>(item.position),
                        projection: Value<String>(
                          CacheProjection.supported.name,
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
    required TaskListId taskListId,
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
                  row.taskListId.equals(taskListId.value) &
                  row.remoteId.equals(remoteParent.value),
            ))
            .getSingleOrNull();
    if (row == null || row.parentTaskId != null) {
      throw const CacheInvariantException('unsupported_task_parent');
    }
    return TaskId(row.id);
  }
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

bool _sameLiveProjection(
  TaskCacheRow existing,
  TaskListId taskListId,
  TaskId? parentId,
  RemoteLiveTask item,
) =>
    existing.taskListId == taskListId.value &&
    existing.parentTaskId == parentId?.value &&
    existing.title == item.title &&
    existing.notes == item.notes &&
    existing.status == _statusValue(_taskStatus(item.status)) &&
    existing.dueEpochDay == _epochDay(_taskDate(item.due)) &&
    existing.position == item.position &&
    existing.projection == CacheProjection.supported.name;
