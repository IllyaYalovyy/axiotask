import 'dart:async';

import 'package:drift/drift.dart';

import '../../domain/model/tasks.dart';
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
    required this.baseRemoteId,
    required this.baseEtag,
    required this.baseRemoteUpdatedAt,
    required this.baseObservedPublicationId,
    required this.baseTitle,
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
  final TaskListRemoteId? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
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
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
    required this.generation,
    required this.localCausalSequence,
    required this.state,
    required this.baseRemoteId,
    required this.baseEtag,
    required this.baseRemoteUpdatedAt,
    required this.baseObservedPublicationId,
    required this.baseTitle,
    required this.createdAt,
    required this.lastTransitionAt,
  });

  final int id;
  final AccountId accountId;
  final TaskId taskId;
  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;
  final int generation;
  final int localCausalSequence;
  final DesiredStateLifecycle state;
  final TaskRemoteId? baseRemoteId;
  final String? baseEtag;
  final DateTime? baseRemoteUpdatedAt;
  final String? baseObservedPublicationId;
  final String? baseTitle;
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
  final DesiredStateLifecycle state;
  final String? failureCode;
  final DateTime claimedAt;
  final DateTime lastTransitionAt;
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
          (state == DesiredStateLifecycle.failed) !=
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

  Future<void> acknowledgeTaskList({
    required AccountId accountId,
    required int attemptId,
    required TaskListRemoteId remoteId,
    required String title,
    required String? etag,
    required DateTime? remoteUpdatedAt,
    required String observedPublicationId,
    required DateTime acknowledgedAt,
  }) {
    return _database.transaction(() async {
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
            title: Value<String>(title),
            state: const Value<String>('confirmed'),
            failureCode: const Value<String?>(null),
            lastTransitionAt: Value<DateTime>(acknowledgedAt.toUtc()),
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
  }) {
    return _database.transaction(() async {
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
      await _reach(DesiredStateTransactionBoundary.afterRemoteBaseWrite);
      await (_database.update(
        _database.desiredStateAttemptRows,
      )..where((row) => row.id.equals(attemptId))).write(
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
            title: Value<String>(title),
            notes: Value<String?>(notes),
            status: Value<String>(_statusValue(status)),
            dueEpochDay: Value<int?>(_epochDay(due)),
            desiredTaskListId: Value<int>(taskListId.value),
            desiredParentTaskId: Value<int?>(parentTaskId?.value),
            state: const Value<String>('confirmed'),
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
  }

  Future<void> _reach(DesiredStateTransactionBoundary boundary) async {
    await transactionControl?.call(boundary);
  }
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
      baseRemoteId: row.baseRemoteId == null
          ? null
          : TaskListRemoteId(row.baseRemoteId!),
      baseEtag: row.baseEtag,
      baseRemoteUpdatedAt: row.baseRemoteUpdatedAt?.toUtc(),
      baseObservedPublicationId: row.baseObservedPublicationId,
      baseTitle: row.baseTitle,
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
  title: row.title!,
  notes: row.notes,
  status: _status(row.status),
  due: _taskDate(row.dueEpochDay),
  generation: row.generation,
  localCausalSequence: row.localCausalSequence,
  state: _state(row.state),
  baseRemoteId: row.baseRemoteId == null
      ? null
      : TaskRemoteId(row.baseRemoteId!),
  baseEtag: row.baseEtag,
  baseRemoteUpdatedAt: row.baseRemoteUpdatedAt?.toUtc(),
  baseObservedPublicationId: row.baseObservedPublicationId,
  baseTitle: row.baseTitle,
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

DesiredStateLifecycle _state(String state) => switch (state) {
  'pending' => DesiredStateLifecycle.pending,
  'in_flight' => DesiredStateLifecycle.inFlight,
  'uncertain' => DesiredStateLifecycle.uncertain,
  'failed' => DesiredStateLifecycle.failed,
  'confirmed' => DesiredStateLifecycle.confirmed,
  'superseded' => DesiredStateLifecycle.superseded,
  _ => throw const DesiredStateInvariantException('unknown_lifecycle_state'),
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
