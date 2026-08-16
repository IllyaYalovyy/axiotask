import 'dart:async';

import '../core/clock.dart';
import '../core/diagnostics/diagnostics.dart';
import '../core/failure.dart';
import '../core/outcome.dart';
import '../core/randomness.dart';
import '../data/auth/authorization.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../data/google_tasks/request.dart';
import '../data/google_tasks/service.dart';
import '../domain/model/tasks.dart';
import 'create_operations.dart';
import 'delete_operations.dart';
import 'phase.dart';
import 'read_plan.dart';
import 'retry/retry_policy.dart';
import 'run.dart';
import 'structure_operations.dart';
import 'update_operations.dart';

final class SyncEngine {
  SyncEngine({
    required this.store,
    required this.googleTasks,
    required this.authorization,
    required this.clock,
    required this.random,
    MonotonicScheduler? scheduler,
    this.observer = const NoopSyncRunObserver(),
    this.retryObserver = const NoopSyncRequestRetryObserver(),
    this.control = const NoopSyncRunControl(),
    this.diagnostics,
  }) : scheduler = scheduler ?? _schedulerFromClock(clock),
       retryPolicy = SyncRetryPolicy(random);

  final SyncStore store;
  final GoogleTasksService googleTasks;
  final AuthorizationPort authorization;
  final Clock clock;
  final RandomSource random;
  final MonotonicScheduler scheduler;
  final SyncRetryPolicy retryPolicy;
  final SyncRunObserver observer;
  final SyncRequestRetryObserver retryObserver;
  final SyncRunControl control;
  final DiagnosticSink? diagnostics;

  Future<SyncRunReport> run(SyncRunRequest request) async {
    final runDeadline =
        request.deadline ?? clock.monotonicElapsed + const Duration(minutes: 2);
    final readCancellation = _readCancellation();
    final runId = _newRunId();
    var taskListPages = 0;
    var taskPages = 0;
    var remoteTaskLists = 0;
    var remoteTasks = 0;
    var resourceProjectionWrites = 0;
    var createOperations = 0;
    var updateOperations = 0;
    var moveOperations = 0;
    var deleteOperations = 0;
    var googleWonReplacements = 0;
    final googleWonReplacementCounts = <ContentSupersessionKind, int>{};
    var confirmedUpdateReadBacks = 0;
    var googleWonStructures = 0;
    var confirmedStructureReadBacks = 0;
    var conditionalReplans = 0;
    Failure? firstFailure;
    var begun = false;

    SyncRunReport report(
      SyncRunOutcome outcome, {
      bool complete = false,
      SyncRunIneligibleReason? ineligibleReason,
      Failure? failure,
    }) => SyncRunReport(
      outcome: outcome,
      runId: runId,
      complete: complete,
      ineligibleReason: ineligibleReason,
      failure: failure,
      taskListPages: taskListPages,
      taskPages: taskPages,
      remoteTaskLists: remoteTaskLists,
      remoteTasks: remoteTasks,
      resourceProjectionWrites: resourceProjectionWrites,
      createOperations: createOperations,
      updateOperations: updateOperations,
      moveOperations: moveOperations,
      deleteOperations: deleteOperations,
      googleWonReplacements: googleWonReplacements,
      googleWonReplacementDetails: ContentSupersessionKind.values
          .where((kind) => (googleWonReplacementCounts[kind] ?? 0) > 0)
          .map(
            (kind) => ContentSupersessionResult(
              kind: kind,
              count: googleWonReplacementCounts[kind]!,
            ),
          )
          .toList(growable: false),
      confirmedUpdateReadBacks: confirmedUpdateReadBacks,
      googleWonStructures: googleWonStructures,
      confirmedStructureReadBacks: confirmedStructureReadBacks,
      conditionalReplans: conditionalReplans,
    );

    void recordSupersessions(Iterable<ContentSupersessionResult> results) {
      for (final result in results) {
        googleWonReplacements += result.count;
        googleWonReplacementCounts.update(
          result.kind,
          (count) => count + result.count,
          ifAbsent: () => result.count,
        );
      }
    }

    void recordUnsupported(ReadPlanException error) {
      diagnostics?.record(
        DiagnosticEvent(
          code: error.failure.code,
          operation: 'synchronize_task_scope',
          fields: <DiagnosticField>[
            const DiagnosticField.safe('scope', 'tasks'),
            if (error.decodedScope case final evidence?)
              DiagnosticField.private('decoded_scope', evidence),
          ],
        ),
      );
    }

    Future<SyncRunReport?> interrupted(SyncRunBoundary boundary) async {
      if (!await _interrupted(boundary)) return null;
      final failure = switch (control) {
        SyncRunInterruptionFailure(:final interruptionFailure) =>
          interruptionFailure,
        _ => null,
      };
      if (begun && failure != null) {
        await store.finalizeReadFailure(
          accountId: request.accountId,
          runId: runId,
          failedAt: clock.now().toUtc(),
          failure: failure,
        );
        return report(SyncRunOutcome.failed, failure: failure);
      }
      return report(SyncRunOutcome.interrupted);
    }

    Future<SyncRunReport?> phase(SyncRunPhase value) async {
      observer.phaseStarted(runId, value);
      return interrupted(
        SyncRunBoundary(kind: SyncRunBoundaryKind.phase, phase: value),
      );
    }

    Future<Failure?> refetchTaskScope({
      required TaskListId taskListId,
      required RemoteTaskListId taskListRemoteId,
      required String reason,
      required AccountSubject expectedSubject,
    }) async {
      final plan = TaskScopeReadPlan();
      PageToken? token;
      var pageIndex = 0;
      do {
        final result = await _retryRead(
          () => googleTasks.listTasks(
            taskListRemoteId,
            pageToken: token,
            cancellation: readCancellation,
          ),
          runDeadline,
          accountId: request.accountId,
          expectedSubject: expectedSubject,
        );
        switch (result) {
          case Failed<RemotePage<RemoteTask>>(:final failure):
            return failure;
          case Success<RemotePage<RemoteTask>>(:final value):
            final List<RemoteTask> ready;
            try {
              ready = plan.acceptPage(
                value.items,
                terminal: value.nextPageToken == null,
              );
            } on ReadPlanException catch (error) {
              recordUnsupported(error);
              return error.failure;
            }
            final scope = 'tasks:${taskListId.value}:$reason';
            if (await interrupted(
                  SyncRunBoundary(
                    kind: SyncRunBoundaryKind.beforePagePublication,
                    scope: scope,
                    pageIndex: pageIndex,
                  ),
                )
                case final interruption?) {
              return interruption.failure ?? _conditionalRefetchFailure;
            }
            final published = await store.publishTaskPage(
              accountId: request.accountId,
              runId: runId,
              taskList: PublishedTaskList(
                localId: taskListId,
                remoteId: taskListRemoteId,
              ),
              items: ready,
              nextPageToken: value.nextPageToken,
              collectionEtag: value.collectionEtag,
            );
            resourceProjectionWrites += published.resourceWrites;
            taskPages += 1;
            remoteTasks += value.items.length;
            token = value.nextPageToken;
            pageIndex += 1;
        }
      } while (token != null);
      return null;
    }

    if (await phase(SyncRunPhase.recover) case final interruption?) {
      return interruption;
    }
    await store.recoverReadRun(request.accountId);
    await store.recoverCreateAttempts(
      accountId: request.accountId,
      recoveredAt: clock.now().toUtc(),
    );
    await store.recoverUpdateAttempts(
      accountId: request.accountId,
      recoveredAt: clock.now().toUtc(),
    );
    await store.recoverDeletes(
      accountId: request.accountId,
      recoveredAt: clock.now().toUtc(),
    );

    if (await phase(SyncRunPhase.checkEligibility) case final interruption?) {
      return interruption;
    }
    final eligibility = await store.readEligibility(request.accountId);
    if (!eligibility.exists) {
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.accountMissing,
      );
    }
    if (!eligibility.syncEnabled) {
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.syncStopped,
      );
    }
    if (eligibility.reauthorizationRequired) {
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.noAuthorization,
      );
    }
    if (eligibility.automaticRetryExhausted) {
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.automaticRetryExhausted,
      );
    }

    if (await phase(SyncRunPhase.authorize) case final interruption?) {
      return interruption;
    }
    final subject = await _usableSubject();
    if (subject == null) {
      if (authorization.currentState is AuthorizationRejected) {
        await store.requireReauthorization(request.accountId);
      }
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.noAuthorization,
      );
    }
    if (subject.value != eligibility.googleSubject) {
      await store.requireReauthorization(request.accountId);
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.accountMismatch,
      );
    }

    if (await phase(SyncRunPhase.begin) case final interruption?) {
      return interruption;
    }
    await store.beginReadRun(
      accountId: request.accountId,
      runId: runId,
      triggers: request.triggers,
      startedAt: clock.now().toUtc(),
    );
    begun = true;

    if (await phase(SyncRunPhase.enumerateGoogle) case final interruption?) {
      return interruption;
    }
    final listPlan = TaskListReadPlan();
    final selectedLists = <PublishedTaskList>[];
    PageToken? listToken;
    var listPageIndex = 0;
    do {
      final result = await _retryRead(
        () => googleTasks.listTaskLists(
          pageToken: listToken,
          cancellation: readCancellation,
        ),
        runDeadline,
        accountId: request.accountId,
        expectedSubject: subject,
      );
      switch (result) {
        case Failed<RemotePage<RemoteTaskList>>(:final failure):
          firstFailure ??= failure;
          listToken = null;
        case Success<RemotePage<RemoteTaskList>>(:final value):
          try {
            listPlan.validatePage(value.items);
          } on ReadPlanException catch (error) {
            recordUnsupported(error);
            firstFailure ??= error.failure;
            listToken = null;
            break;
          }
          final boundary = SyncRunBoundary(
            kind: SyncRunBoundaryKind.beforePagePublication,
            scope: 'task_lists',
            pageIndex: listPageIndex,
          );
          if (await interrupted(boundary) case final interruption?) {
            return interruption;
          }
          final published = await store.publishTaskListPage(
            accountId: request.accountId,
            runId: runId,
            items: value.items,
            nextPageToken: value.nextPageToken,
            collectionEtag: value.collectionEtag,
          );
          selectedLists.addAll(published.values);
          resourceProjectionWrites += published.resourceWrites;
          taskListPages += 1;
          remoteTaskLists += value.items.length;
          if (await interrupted(
                SyncRunBoundary(
                  kind: SyncRunBoundaryKind.afterPagePublication,
                  scope: 'task_lists',
                  pageIndex: listPageIndex,
                ),
              )
              case final interruption?) {
            return interruption;
          }
          listToken = value.nextPageToken;
          listPageIndex += 1;
      }
      if (firstFailure != null) break;
    } while (listToken != null);

    if (firstFailure == null) {
      for (final taskList in selectedLists) {
        final plan = TaskScopeReadPlan();
        PageToken? taskToken;
        var pageIndex = 0;
        Failure? scopeFailure;
        do {
          final result = await _retryRead(
            () => googleTasks.listTasks(
              taskList.remoteId,
              pageToken: taskToken,
              cancellation: readCancellation,
            ),
            runDeadline,
            accountId: request.accountId,
            expectedSubject: subject,
          );
          switch (result) {
            case Failed<RemotePage<RemoteTask>>(:final failure):
              scopeFailure = failure;
              taskToken = null;
            case Success<RemotePage<RemoteTask>>(:final value):
              final List<RemoteTask> ready;
              try {
                ready = plan.acceptPage(
                  value.items,
                  terminal: value.nextPageToken == null,
                );
              } on ReadPlanException catch (error) {
                recordUnsupported(error);
                scopeFailure = error.failure;
                taskToken = null;
                break;
              }
              final scope = 'tasks:${taskList.localId.value}';
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.beforePagePublication,
                      scope: scope,
                      pageIndex: pageIndex,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              final published = await store.publishTaskPage(
                accountId: request.accountId,
                runId: runId,
                taskList: taskList,
                items: ready,
                nextPageToken: value.nextPageToken,
                collectionEtag: value.collectionEtag,
              );
              resourceProjectionWrites += published.resourceWrites;
              taskPages += 1;
              remoteTasks += value.items.length;
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.afterPagePublication,
                      scope: scope,
                      pageIndex: pageIndex,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              taskToken = value.nextPageToken;
              pageIndex += 1;
          }
          if (scopeFailure != null) break;
        } while (taskToken != null);
        firstFailure ??= scopeFailure;
      }
    }

    if (await phase(SyncRunPhase.reconcileAndPlan) case final interruption?) {
      return interruption;
    }
    await store.reconcileDeletes(
      accountId: request.accountId,
      runId: runId.value,
      reconciledAt: clock.now().toUtc(),
    );
    final structureReconciliation = await store.reconcileStructure(
      accountId: request.accountId,
      runId: runId.value,
      reconciledAt: clock.now().toUtc(),
    );
    confirmedStructureReadBacks += structureReconciliation.confirmedReadBacks;
    googleWonStructures += structureReconciliation.supersessions.fold<int>(
      0,
      (count, result) => count + result.count,
    );
    firstFailure ??= structureReconciliation.failure;
    final reconciliation = await store.reconcileContent(
      accountId: request.accountId,
      runId: runId.value,
      reconciledAt: clock.now().toUtc(),
    );
    recordSupersessions(reconciliation.supersessions);
    confirmedUpdateReadBacks += reconciliation.confirmedReadBacks;
    firstFailure ??= reconciliation.failure;
    if (await phase(SyncRunPhase.executeOperations) case final interruption?) {
      return interruption;
    }
    var stopOperations = false;
    while (!stopOperations) {
      if (await interrupted(
            const SyncRunBoundary(
              kind: SyncRunBoundaryKind.beforeOperationClaim,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      final claim = await store.claimNextDelete(
        accountId: request.accountId,
        runId: runId.value,
        claimedAt: clock.now().toUtc(),
      );
      if (claim == null) break;
      if (await interrupted(
            SyncRunBoundary(
              kind: SyncRunBoundaryKind.afterOperationClaim,
              operationAttemptId: claim.attemptId,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      deleteOperations += 1;
      final operation = const DeleteOperationMapper().map(claim);
      final result = switch (claim.kind) {
        DeleteOperationKind.taskList => await _retryMutation(
          () =>
              googleTasks.deleteTaskList(operation as DeleteTaskListOperation),
          runDeadline,
        ),
        DeleteOperationKind.task => await _retryMutation(
          () => googleTasks.deleteTask(operation as DeleteTaskOperation),
          runDeadline,
        ),
      };
      switch (result) {
        case CommittedMutation<void>():
          if (claim.kind == DeleteOperationKind.taskList) {
            try {
              await store.acknowledgeTaskListDelete(
                accountId: request.accountId,
                claim: claim,
                observationId: 'mutation:${runId.value}:${claim.attemptId}',
                acknowledgedAt: clock.now().toUtc(),
              );
            } on Object {
              firstFailure ??= _deleteAcknowledgementFailure;
              stopOperations = true;
            }
            break;
          }
          final verification = await _verifyTaskDelete(
            claim,
            readCancellation,
            runDeadline,
            accountId: request.accountId,
            expectedSubject: subject,
          );
          if (verification case Failed<void>(:final failure)) {
            await store.resolveDeleteFailure(
              accountId: request.accountId,
              claim: claim,
              failure: failure,
              uncertain: true,
              resolvedAt: clock.now().toUtc(),
            );
            firstFailure ??= failure;
            break;
          }
          try {
            await store.acknowledgeTaskDelete(
              accountId: request.accountId,
              claim: claim,
              observationId: 'mutation:${runId.value}:${claim.attemptId}',
              acknowledgedAt: clock.now().toUtc(),
            );
          } on Object {
            firstFailure ??= _deleteAcknowledgementFailure;
            stopOperations = true;
          }
        case RejectedMutation<void>(:final error):
          await store.resolveDeleteFailure(
            accountId: request.accountId,
            claim: claim,
            failure: error.failure,
            uncertain: false,
            resolvedAt: clock.now().toUtc(),
          );
          firstFailure ??= error.failure;
          if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
            stopOperations = true;
          }
        case UncertainMutation<void>(:final error):
          await store.resolveDeleteFailure(
            accountId: request.accountId,
            claim: claim,
            failure: error.failure,
            uncertain: true,
            resolvedAt: clock.now().toUtc(),
          );
          firstFailure ??= error.failure;
      }
    }
    while (!stopOperations) {
      if (await interrupted(
            const SyncRunBoundary(
              kind: SyncRunBoundaryKind.beforeOperationClaim,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      final claim = await store.claimNextCreate(
        accountId: request.accountId,
        runId: runId.value,
        claimedAt: clock.now().toUtc(),
      );
      if (claim == null) break;
      if (await interrupted(
            SyncRunBoundary(
              kind: SyncRunBoundaryKind.afterOperationClaim,
              operationAttemptId: claim.attemptId,
            ),
          )
          case final interruption?) {
        return interruption;
      }

      final mapped = const CreateOperationMapper().map(claim);
      switch (mapped) {
        case final CreateTaskListOperation operation:
          createOperations += 1;
          final result = await _retryMutation(
            () => googleTasks.createTaskList(operation),
            runDeadline,
          );
          switch (result) {
            case CommittedMutation<RemoteTaskList>(:final value):
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.beforeRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              try {
                await store.acknowledgeTaskListCreate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
              } on Object {
                firstFailure ??= _mutationAcknowledgementFailure;
                stopOperations = true;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.afterRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
            case RejectedMutation<RemoteTaskList>(:final error):
              await store.resolveCreateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: false,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
              if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
                stopOperations = true;
              }
            case UncertainMutation<RemoteTaskList>(:final error):
              await store.resolveCreateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: true,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
          }
        case final CreateTaskOperation operation:
          createOperations += 1;
          final result = await _retryMutation(
            () => googleTasks.createTask(operation),
            runDeadline,
          );
          switch (result) {
            case CommittedMutation<RemoteTask>(:final value):
              if (value is! RemoteLiveTask ||
                  value.parentId != claim.parentRemoteId) {
                await store.resolveCreateFailure(
                  accountId: request.accountId,
                  claim: claim,
                  failure: _invalidCreateResponseFailure,
                  uncertain: false,
                  resolvedAt: clock.now().toUtc(),
                );
                firstFailure ??= _invalidCreateResponseFailure;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.beforeRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              try {
                await store.acknowledgeTaskCreate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
              } on Object {
                firstFailure ??= _mutationAcknowledgementFailure;
                stopOperations = true;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.afterRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
            case RejectedMutation<RemoteTask>(:final error):
              await store.resolveCreateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: false,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
              if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
                stopOperations = true;
              }
            case UncertainMutation<RemoteTask>(:final error):
              await store.resolveCreateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: true,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
          }
        default:
          throw StateError('Unsupported create operation mapping.');
      }
    }
    final moveReplans = <RemoteTaskId, int>{};
    moveLoop:
    while (!stopOperations) {
      if (await interrupted(
            const SyncRunBoundary(
              kind: SyncRunBoundaryKind.beforeOperationClaim,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      final claim = await store.claimNextMove(
        accountId: request.accountId,
        runId: runId.value,
        claimedAt: clock.now().toUtc(),
      );
      if (claim == null) break;
      if (await interrupted(
            SyncRunBoundary(
              kind: SyncRunBoundaryKind.afterOperationClaim,
              operationAttemptId: claim.attemptId,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      moveOperations += 1;
      final result = await _retryMutation(
        () => googleTasks.moveTask(const MoveOperationMapper().map(claim)),
        runDeadline,
      );
      switch (result) {
        case CommittedMutation<RemoteTask>(:final value):
          if (value is! RemoteLiveTask ||
              value.id != claim.taskRemoteId ||
              value.parentId != claim.parentRemoteId) {
            await store.resolveMoveFailure(
              accountId: request.accountId,
              claim: claim,
              failure: _invalidMoveResponseFailure,
              uncertain: true,
              resolvedAt: clock.now().toUtc(),
            );
            firstFailure ??= _invalidMoveResponseFailure;
            break;
          }
          if (await interrupted(
                SyncRunBoundary(
                  kind: SyncRunBoundaryKind.beforeRemoteAcknowledgement,
                  operationAttemptId: claim.attemptId,
                ),
              )
              case final interruption?) {
            return interruption;
          }
          try {
            await store.acknowledgeMove(
              accountId: request.accountId,
              claim: claim,
              remote: value,
              observationId: 'mutation:${runId.value}:${claim.attemptId}',
              acknowledgedAt: clock.now().toUtc(),
            );
          } on Object {
            firstFailure ??= _moveAcknowledgementFailure;
            stopOperations = true;
            break;
          }
          if (await interrupted(
                SyncRunBoundary(
                  kind: SyncRunBoundaryKind.afterRemoteAcknowledgement,
                  operationAttemptId: claim.attemptId,
                ),
              )
              case final interruption?) {
            return interruption;
          }
        case RejectedMutation<RemoteTask>(:final error):
          if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
            await store.resolveMoveFailure(
              accountId: request.accountId,
              claim: claim,
              failure: error.failure,
              uncertain: false,
              resolvedAt: clock.now().toUtc(),
            );
            firstFailure ??= error.failure;
            stopOperations = true;
            break;
          }
          final canReplan =
              error.kind == GoogleTasksErrorKind.conditional ||
              error.kind == GoogleTasksErrorKind.notFound ||
              error.kind == GoogleTasksErrorKind.permanent;
          final count = (moveReplans[claim.taskRemoteId] ?? 0) + 1;
          moveReplans[claim.taskRemoteId] = count;
          if (canReplan && count <= _maximumConditionalReplans) {
            conditionalReplans += 1;
            await store.prepareMoveReplan(
              accountId: request.accountId,
              claim: claim,
              replannedAt: clock.now().toUtc(),
            );
            var refetchFailure = await refetchTaskScope(
              taskListId: claim.sourceTaskListId,
              taskListRemoteId: claim.sourceTaskListRemoteId,
              reason: 'move-replan',
              expectedSubject: subject,
            );
            if (refetchFailure == null &&
                claim.destinationTaskListId != claim.sourceTaskListId) {
              refetchFailure = await refetchTaskScope(
                taskListId: claim.destinationTaskListId,
                taskListRemoteId: claim.destinationTaskListRemoteId,
                reason: 'move-replan',
                expectedSubject: subject,
              );
            }
            if (refetchFailure != null) {
              firstFailure ??= refetchFailure;
              stopOperations = true;
              break;
            }
            final replanned = await store.reconcileStructure(
              accountId: request.accountId,
              runId: runId.value,
              reconciledAt: clock.now().toUtc(),
            );
            confirmedStructureReadBacks += replanned.confirmedReadBacks;
            googleWonStructures += replanned.supersessions.fold<int>(
              0,
              (total, value) => total + value.count,
            );
            firstFailure ??= replanned.failure;
            if (replanned.failure == null) continue moveLoop;
            stopOperations = true;
            break;
          }
          await store.resolveMoveFailure(
            accountId: request.accountId,
            claim: claim,
            failure: error.failure,
            uncertain: false,
            resolvedAt: clock.now().toUtc(),
          );
          firstFailure ??= error.failure;
        case UncertainMutation<RemoteTask>(:final error):
          await store.resolveMoveFailure(
            accountId: request.accountId,
            claim: claim,
            failure: error.failure,
            uncertain: true,
            resolvedAt: clock.now().toUtc(),
          );
          firstFailure ??= error.failure;
      }
    }
    if (!stopOperations) {
      try {
        await store.confirmNoOpUpdates(
          accountId: request.accountId,
          runId: runId.value,
          confirmedAt: clock.now().toUtc(),
        );
      } on Object {
        firstFailure ??= _updateAcknowledgementFailure;
        stopOperations = true;
      }
    }
    final conditionalAttempts = <RemoteTaskId, int>{};
    updateLoop:
    while (!stopOperations) {
      if (await interrupted(
            const SyncRunBoundary(
              kind: SyncRunBoundaryKind.beforeOperationClaim,
            ),
          )
          case final interruption?) {
        return interruption;
      }
      final claim = await store.claimNextUpdate(
        accountId: request.accountId,
        runId: runId.value,
        claimedAt: clock.now().toUtc(),
      );
      if (claim == null) break;
      if (await interrupted(
            SyncRunBoundary(
              kind: SyncRunBoundaryKind.afterOperationClaim,
              operationAttemptId: claim.attemptId,
            ),
          )
          case final interruption?) {
        return interruption;
      }

      final mapped = const UpdateOperationMapper().map(claim);
      switch (mapped) {
        case final PatchTaskOperation operation:
          updateOperations += 1;
          final result = await _retryMutation(
            () => googleTasks.patchTask(operation),
            runDeadline,
          );
          switch (result) {
            case CommittedMutation<RemoteTask>(:final value):
              if (value is! RemoteLiveTask ||
                  value.id != claim.taskRemoteId ||
                  value.parentId != claim.parentRemoteId) {
                await store.resolveUpdateFailure(
                  accountId: request.accountId,
                  claim: claim,
                  failure: _invalidUpdateResponseFailure,
                  uncertain: true,
                  resolvedAt: clock.now().toUtc(),
                );
                firstFailure ??= _invalidUpdateResponseFailure;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.beforeRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              try {
                final googleReplacedClaim =
                    value.title != claim.title ||
                    value.notes != claim.notes ||
                    _taskStatus(value.status) != claim.status ||
                    _taskDate(value.due) != claim.due;
                await store.acknowledgeTaskUpdate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
                if (googleReplacedClaim) {
                  recordSupersessions(<ContentSupersessionResult>[
                    ContentSupersessionResult(
                      kind:
                          claim.status == TaskStatus.needsAction &&
                              value.status == RemoteTaskStatus.completed
                          ? ContentSupersessionKind.completionCascade
                          : ContentSupersessionKind.taskContent,
                      count: 1,
                    ),
                  ]);
                }
              } on Object {
                firstFailure ??= _updateAcknowledgementFailure;
                stopOperations = true;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.afterRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
            case RejectedMutation<RemoteTask>(:final error):
              if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
                await store.resolveUpdateFailure(
                  accountId: request.accountId,
                  claim: claim,
                  failure: error.failure,
                  uncertain: false,
                  resolvedAt: clock.now().toUtc(),
                );
                firstFailure ??= error.failure;
                stopOperations = true;
                break;
              }
              if (error.kind == GoogleTasksErrorKind.conditional) {
                final count =
                    (conditionalAttempts[claim.taskRemoteId!] ?? 0) + 1;
                conditionalAttempts[claim.taskRemoteId!] = count;
                if (count <= _maximumConditionalReplans) {
                  conditionalReplans += 1;
                  await store.prepareTaskUpdateReplan(
                    accountId: request.accountId,
                    claim: claim,
                    replannedAt: clock.now().toUtc(),
                  );
                  final refetchFailure = await refetchTaskScope(
                    taskListId: claim.taskListId,
                    taskListRemoteId: claim.taskListRemoteId,
                    reason: 'conditional',
                    expectedSubject: subject,
                  );
                  if (refetchFailure != null) {
                    firstFailure ??= refetchFailure;
                    stopOperations = true;
                    break;
                  }
                  final replanned = await store.reconcileContent(
                    accountId: request.accountId,
                    runId: runId.value,
                    reconciledAt: clock.now().toUtc(),
                  );
                  recordSupersessions(replanned.supersessions);
                  confirmedUpdateReadBacks += replanned.confirmedReadBacks;
                  firstFailure ??= replanned.failure;
                  if (replanned.failure == null) continue updateLoop;
                  stopOperations = true;
                  break;
                }
              }
              await store.resolveUpdateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: false,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
            case UncertainMutation<RemoteTask>(:final error):
              await store.resolveUpdateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: true,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
          }
        case final RenameTaskListOperation operation:
          updateOperations += 1;
          final result = await _retryMutation(
            () => googleTasks.renameTaskList(operation),
            runDeadline,
          );
          switch (result) {
            case CommittedMutation<RemoteTaskList>(:final value):
              if (value.id != claim.taskListRemoteId) {
                await store.resolveUpdateFailure(
                  accountId: request.accountId,
                  claim: claim,
                  failure: _invalidUpdateResponseFailure,
                  uncertain: true,
                  resolvedAt: clock.now().toUtc(),
                );
                firstFailure ??= _invalidUpdateResponseFailure;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.beforeRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
              try {
                final googleReplacedClaim = value.title != claim.title;
                await store.acknowledgeTaskListUpdate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
                if (googleReplacedClaim) {
                  recordSupersessions(const <ContentSupersessionResult>[
                    ContentSupersessionResult(
                      kind: ContentSupersessionKind.taskListTitle,
                      count: 1,
                    ),
                  ]);
                }
              } on Object {
                firstFailure ??= _updateAcknowledgementFailure;
                stopOperations = true;
                break;
              }
              if (await interrupted(
                    SyncRunBoundary(
                      kind: SyncRunBoundaryKind.afterRemoteAcknowledgement,
                      operationAttemptId: claim.attemptId,
                    ),
                  )
                  case final interruption?) {
                return interruption;
              }
            case RejectedMutation<RemoteTaskList>(:final error):
              await store.resolveUpdateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: false,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
              if (retryPolicy.isAutomaticallyRetryable(error.failure)) {
                stopOperations = true;
              }
            case UncertainMutation<RemoteTaskList>(:final error):
              await store.resolveUpdateFailure(
                accountId: request.accountId,
                claim: claim,
                failure: error.failure,
                uncertain: true,
                resolvedAt: clock.now().toUtc(),
              );
              firstFailure ??= error.failure;
          }
        default:
          throw StateError('Unsupported update operation mapping.');
      }
    }
    if (await phase(SyncRunPhase.verifyOutcomes) case final interruption?) {
      return interruption;
    }
    if (await phase(SyncRunPhase.finalize) case final interruption?) {
      return interruption;
    }

    if (await interrupted(
          const SyncRunBoundary(kind: SyncRunBoundaryKind.beforeFinalization),
        )
        case final interruption?) {
      return interruption;
    }

    if (firstFailure case final failure?) {
      await store.finalizeReadFailure(
        accountId: request.accountId,
        runId: runId,
        failedAt: clock.now().toUtc(),
        failure: failure,
      );
      return report(SyncRunOutcome.failed, failure: failure);
    }

    final complete = await store.isPublicationComplete(
      accountId: request.accountId,
      runId: runId,
    );
    if (!complete) {
      final failure = _incompletePublicationFailure;
      await store.finalizeReadFailure(
        accountId: request.accountId,
        runId: runId,
        failedAt: clock.now().toUtc(),
        failure: failure,
      );
      return report(SyncRunOutcome.failed, failure: failure);
    }
    await store.finalizeReadSuccess(
      accountId: request.accountId,
      runId: runId,
      completedAt: clock.now().toUtc(),
    );
    return report(SyncRunOutcome.succeeded, complete: true);
  }

  Future<AccountSubject?> _usableSubject() async {
    switch (authorization.currentState) {
      case TasksAuthorized(:final subject):
        return subject;
      case AuthorizationExpired():
        return switch (await authorization.refreshTasksAuthorization()) {
          Success<AccountSubject>(:final value) => value,
          Failed<AccountSubject>() => null,
        };
      case NoTasksAuthorization() || AuthorizationRejected():
        return null;
      case AuthorizationConnecting() || AuthorizationRefreshPending():
        return null;
      case AuthorizationRequestFailed():
        return switch (await authorization.restoreTasksAuthorization()) {
          Success<AccountSubject>(:final value) => value,
          Failed<AccountSubject>() => null,
        };
    }
  }

  Future<Outcome<void>> _verifyTaskDelete(
    DeleteOperationClaim claim,
    GoogleTasksReadCancellation? cancellation,
    Duration runDeadline, {
    required AccountId accountId,
    required AccountSubject expectedSubject,
  }) async {
    PageToken? token;
    do {
      final result = await _retryRead(
        () => googleTasks.listTasks(
          RemoteTaskListId(claim.taskListRemoteId.value),
          pageToken: token,
          cancellation: cancellation,
        ),
        runDeadline,
        accountId: accountId,
        expectedSubject: expectedSubject,
      );
      switch (result) {
        case Failed<RemotePage<RemoteTask>>(:final failure):
          return Outcome<void>.failure(failure);
        case Success<RemotePage<RemoteTask>>(:final value):
          for (final task in value.items) {
            if (task.id.value != claim.taskRemoteId!.value) continue;
            return task is RemoteTaskTombstone
                ? const Outcome<void>.success(null)
                : const Outcome<void>.failure(_deleteVerificationFailure);
          }
          token = value.nextPageToken;
      }
    } while (token != null);
    return const Outcome<void>.failure(_deleteVerificationFailure);
  }

  Future<bool> _interrupted(SyncRunBoundary boundary) async =>
      await control.reach(boundary) == SyncRunControlDecision.interrupt;

  GoogleTasksReadCancellation? _readCancellation() {
    final SyncRunCancellationSignal currentControl;
    switch (control) {
      case final SyncRunCancellationSignal signal:
        currentControl = signal;
      default:
        return null;
    }
    final cancellation = GoogleTasksReadCancellation();
    if (currentControl.isCancellationRequested) {
      cancellation.cancel();
    } else {
      unawaited(
        currentControl.whenCancellationRequested.then((_) {
          cancellation.cancel();
        }),
      );
    }
    return cancellation;
  }

  SyncRunId _newRunId() {
    final bytes = random.nextBytes(16);
    final value = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return SyncRunId(value);
  }

  Future<Outcome<T>> _retryRead<T>(
    Future<Outcome<T>> Function() request,
    Duration runDeadline, {
    required AccountId accountId,
    required AccountSubject expectedSubject,
  }) async {
    var authorizationRefreshed = false;
    for (var attempt = 1; attempt <= syncRequestAttemptLimit; attempt += 1) {
      if (!_attemptFits(runDeadline)) {
        return Outcome<T>.failure(_requestBudgetFailure);
      }
      final result = await request();
      final failure = switch (result) {
        Failed<T>(:final failure) => failure,
        Success<T>() => null,
      };
      if (failure?.authorizationRecovery == AuthorizationRecovery.refreshOnce) {
        if (authorizationRefreshed) {
          await store.requireReauthorization(accountId);
          return result;
        }
        if (attempt == syncRequestAttemptLimit) return result;
        authorizationRefreshed = true;
        final refresh = await authorization.refreshTasksAuthorization();
        switch (refresh) {
          case Success<AccountSubject>(:final value):
            if (value != expectedSubject) {
              await store.requireReauthorization(accountId);
              return Outcome<T>.failure(_subjectMismatchFailure);
            }
          case Failed<AccountSubject>(:final failure):
            if (authorization.currentState is AuthorizationRejected) {
              await store.requireReauthorization(accountId);
            }
            return Outcome<T>.failure(failure);
        }
        continue;
      }
      if (failure == null ||
          !retryPolicy.isAutomaticallyRetryable(failure) ||
          attempt == syncRequestAttemptLimit) {
        return result;
      }
      final delay = retryPolicy.requestDelay(
        attempt,
        failure,
        clock.now().toUtc(),
      );
      if (!_attemptFits(runDeadline, delay: delay)) {
        return Outcome<T>.failure(_requestBudgetFailure);
      }
      retryObserver.retryStateChanged(
        SyncRequestRetryState.waiting,
        failure: failure,
        attempt: attempt + 1,
        delay: delay,
      );
      await _wait(delay);
      retryObserver.retryStateChanged(
        SyncRequestRetryState.executing,
        failure: failure,
        attempt: attempt + 1,
        delay: null,
      );
    }
    throw StateError('The bounded request loop did not return.');
  }

  Future<GoogleTasksMutationResult<T>> _retryMutation<T>(
    Future<GoogleTasksMutationResult<T>> Function() request,
    Duration runDeadline,
  ) async {
    for (var attempt = 1; attempt <= syncRequestAttemptLimit; attempt += 1) {
      if (!_attemptFits(runDeadline)) {
        return RejectedMutation<T>(_requestBudgetMutationError);
      }
      final result = await request();
      final failure = switch (result) {
        RejectedMutation<T>(:final error)
            when error.commitState == MutationCommitState.notCommitted =>
          error.failure,
        _ => null,
      };
      if (failure == null ||
          !retryPolicy.isAutomaticallyRetryable(failure) ||
          attempt == syncRequestAttemptLimit) {
        return result;
      }
      final delay = retryPolicy.requestDelay(
        attempt,
        failure,
        clock.now().toUtc(),
      );
      if (!_attemptFits(runDeadline, delay: delay)) {
        return RejectedMutation<T>(_requestBudgetMutationError);
      }
      retryObserver.retryStateChanged(
        SyncRequestRetryState.waiting,
        failure: failure,
        attempt: attempt + 1,
        delay: delay,
      );
      await _wait(delay);
      retryObserver.retryStateChanged(
        SyncRequestRetryState.executing,
        failure: failure,
        attempt: attempt + 1,
        delay: null,
      );
    }
    throw StateError('The bounded mutation request loop did not return.');
  }

  bool _attemptFits(Duration runDeadline, {Duration delay = Duration.zero}) =>
      clock.monotonicElapsed + delay + syncRequestAttemptTimeout <= runDeadline;

  Future<void> _wait(Duration delay) {
    if (delay == Duration.zero) return Future<void>.value();
    final completer = Completer<void>();
    scheduler.schedule(delay, completer.complete);
    return completer.future;
  }
}

MonotonicScheduler _schedulerFromClock(Clock clock) => switch (clock) {
  final MonotonicScheduler scheduler => scheduler,
  _ => throw ArgumentError.value(
    clock,
    'clock',
    'must also implement MonotonicScheduler when scheduler is omitted',
  ),
};

const Failure _incompletePublicationFailure = Failure(
  code: 'sync.read_publication_incomplete',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'The Google Tasks read did not publish every required page.',
  safeSummary: 'The read run ended without complete scope evidence.',
);

const Failure _requestBudgetFailure = Failure(
  code: 'sync.request_budget_exhausted',
  category: FailureCategory.remote,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.transient,
  impact: 'Synchronization could not safely start another request in this run.',
  action: FailureAction.retry,
  safeSummary: 'The remaining run budget could not contain another request.',
);

const GoogleTasksMutationError _requestBudgetMutationError =
    GoogleTasksMutationError(
      failure: _requestBudgetFailure,
      kind: GoogleTasksErrorKind.transient,
      commitState: MutationCommitState.notCommitted,
    );

const Failure _invalidCreateResponseFailure = Failure(
  code: 'sync.create_response_invalid',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'Google did not return a supported created task.',
  safeSummary: 'The create response did not match the claimed operation.',
);

const Failure _invalidUpdateResponseFailure = Failure(
  code: 'sync.update_response_invalid',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'Google did not return the expected updated resource.',
  safeSummary: 'The update response did not match the claimed operation.',
);

const Failure _invalidMoveResponseFailure = Failure(
  code: 'sync.move_response_mismatch',
  category: FailureCategory.remote,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task placement could not be confirmed.',
  safeSummary: 'The MOVE response did not match the claimed task placement.',
);

const Failure _moveAcknowledgementFailure = Failure(
  code: 'sync.move_acknowledgement_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The task placement may not have been recorded locally.',
  safeSummary: 'The MOVE acknowledgement transaction did not commit.',
);

const Failure _mutationAcknowledgementFailure = Failure(
  code: 'sync.create_acknowledgement_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'A Google create could not be confirmed locally.',
  safeSummary: 'The create acknowledgement transaction did not commit.',
);

const Failure _updateAcknowledgementFailure = Failure(
  code: 'sync.update_acknowledgement_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'A Google update could not be confirmed locally.',
  safeSummary: 'The update acknowledgement transaction did not commit.',
);

const Failure _deleteAcknowledgementFailure = Failure(
  code: 'sync.delete_acknowledgement_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'A Google deletion could not be confirmed locally.',
  safeSummary: 'The delete acknowledgement transaction did not commit.',
);

const Failure _deleteVerificationFailure = Failure(
  code: 'sync.task_delete_unverified',
  category: FailureCategory.remote,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'A task deletion could not yet be verified.',
  safeSummary: 'Positive task tombstone evidence was not available.',
);

const int _maximumConditionalReplans = 3;

const Failure _conditionalRefetchFailure = Failure(
  code: 'sync.task_precondition_refetch_interrupted',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.unknown,
  impact: 'A changed Google task could not be reconciled.',
  safeSummary: 'The conditional-conflict refetch did not complete.',
);

const Failure _subjectMismatchFailure = Failure(
  code: 'account.subject_mismatch',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'No Google Tasks data was read or changed.',
  safeSummary: 'The refreshed authorization subject did not match the account.',
);

TaskStatus _taskStatus(RemoteTaskStatus status) => switch (status) {
  RemoteTaskStatus.needsAction => TaskStatus.needsAction,
  RemoteTaskStatus.completed => TaskStatus.completed,
};

TaskDate? _taskDate(RemoteDate? value) =>
    value == null ? null : TaskDate(value.year, value.month, value.day);
