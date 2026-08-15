import 'dart:async';

import '../core/clock.dart';
import '../core/failure.dart';
import '../core/outcome.dart';
import '../core/randomness.dart';
import '../data/auth/authorization.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../data/google_tasks/request.dart';
import '../data/google_tasks/service.dart';
import 'create_operations.dart';
import 'phase.dart';
import 'read_plan.dart';
import 'run.dart';
import 'update_operations.dart';

final class SyncEngine {
  SyncEngine({
    required this.store,
    required this.googleTasks,
    required this.authorization,
    required this.clock,
    required this.random,
    this.observer = const NoopSyncRunObserver(),
    this.control = const NoopSyncRunControl(),
  });

  final SyncStore store;
  final GoogleTasksService googleTasks;
  final AuthorizationPort authorization;
  final Clock clock;
  final RandomSource random;
  final SyncRunObserver observer;
  final SyncRunControl control;

  Future<SyncRunReport> run(SyncRunRequest request) async {
    final readCancellation = _readCancellation();
    final runId = _newRunId();
    var taskListPages = 0;
    var taskPages = 0;
    var remoteTaskLists = 0;
    var remoteTasks = 0;
    var resourceProjectionWrites = 0;
    var createOperations = 0;
    var updateOperations = 0;
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
    );

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

    if (await phase(SyncRunPhase.authorize) case final interruption?) {
      return interruption;
    }
    final subject = await _usableSubject();
    if (subject == null) {
      return report(
        SyncRunOutcome.ineligible,
        ineligibleReason: SyncRunIneligibleReason.noAuthorization,
      );
    }
    if (subject.value != eligibility.googleSubject) {
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
      final result = await googleTasks.listTaskLists(
        pageToken: listToken,
        cancellation: readCancellation,
      );
      switch (result) {
        case Failed<RemotePage<RemoteTaskList>>(:final failure):
          firstFailure ??= failure;
          listToken = null;
        case Success<RemotePage<RemoteTaskList>>(:final value):
          try {
            listPlan.validatePage(value.items);
          } on ReadPlanException catch (error) {
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
          final result = await googleTasks.listTasks(
            taskList.remoteId,
            pageToken: taskToken,
            cancellation: readCancellation,
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
          final result = await googleTasks.createTaskList(operation);
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
          final result = await googleTasks.createTask(operation);
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
          final result = await googleTasks.patchTask(operation);
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
                await store.acknowledgeTaskUpdate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
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
          final result = await googleTasks.renameTaskList(operation);
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
                await store.acknowledgeTaskListUpdate(
                  accountId: request.accountId,
                  claim: claim,
                  remote: value,
                  observationId: 'mutation:${runId.value}:${claim.attemptId}',
                  acknowledgedAt: clock.now().toUtc(),
                );
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
}

const Failure _incompletePublicationFailure = Failure(
  code: 'sync.read_publication_incomplete',
  category: FailureCategory.internal,
  operation: FailureOperation.synchronize,
  retry: RetryClassification.permanent,
  impact: 'The Google Tasks read did not publish every required page.',
  safeSummary: 'The read run ended without complete scope evidence.',
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
