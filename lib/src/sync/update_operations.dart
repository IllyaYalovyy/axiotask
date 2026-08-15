import '../core/failure.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../domain/model/tasks.dart';

enum UpdateOperationKind { task, taskList }

enum ContentSupersessionKind { taskContent, taskListTitle, completionCascade }

final class ContentSupersessionResult {
  const ContentSupersessionResult({required this.kind, required this.count})
    : assert(count > 0);

  final ContentSupersessionKind kind;
  final int count;
}

final class ContentReconciliationSummary {
  const ContentReconciliationSummary({
    this.confirmedReadBacks = 0,
    this.localWritesPending = 0,
    this.supersessions = const <ContentSupersessionResult>[],
    this.failure,
  });

  final int confirmedReadBacks;
  final int localWritesPending;
  final List<ContentSupersessionResult> supersessions;
  final Failure? failure;

  int get googleWonReplacements =>
      supersessions.fold<int>(0, (total, result) => total + result.count);
}

final class UpdateOperationClaim {
  const UpdateOperationClaim.taskList({
    required this.attemptId,
    required this.generation,
    required this.taskListId,
    required this.taskListRemoteId,
    required this.title,
  }) : kind = UpdateOperationKind.taskList,
       taskId = null,
       taskRemoteId = null,
       parentTaskId = null,
       parentRemoteId = null,
       etag = null,
       notes = null,
       status = null,
       due = null;

  const UpdateOperationClaim.task({
    required this.attemptId,
    required this.generation,
    required this.taskListId,
    required this.taskListRemoteId,
    required this.taskId,
    required this.taskRemoteId,
    required this.parentTaskId,
    required this.parentRemoteId,
    required this.etag,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  }) : kind = UpdateOperationKind.task;

  final UpdateOperationKind kind;
  final int attemptId;
  final int generation;
  final TaskListId taskListId;
  final RemoteTaskListId taskListRemoteId;
  final TaskId? taskId;
  final RemoteTaskId? taskRemoteId;
  final TaskId? parentTaskId;
  final RemoteTaskId? parentRemoteId;
  final String? etag;
  final String title;
  final String? notes;
  final TaskStatus? status;
  final TaskDate? due;
}

final class UpdateOperationMapper {
  const UpdateOperationMapper();

  GoogleTasksMutationOperation<Object?> map(UpdateOperationClaim claim) =>
      switch (claim.kind) {
        UpdateOperationKind.task => PatchTaskOperation(
          taskListId: claim.taskListRemoteId,
          taskId: claim.taskRemoteId!,
          etag: claim.etag!,
          title: claim.title,
          notes: claim.notes == null
              ? const OptionalFieldWrite<String>.clear()
              : OptionalFieldWrite<String>.set(claim.notes!),
          status: switch (claim.status!) {
            TaskStatus.needsAction => RemoteTaskStatus.needsAction,
            TaskStatus.completed => RemoteTaskStatus.completed,
          },
          due: claim.due == null
              ? const OptionalFieldWrite<RemoteDate>.clear()
              : OptionalFieldWrite<RemoteDate>.set(
                  RemoteDate(claim.due!.year, claim.due!.month, claim.due!.day),
                ),
        ),
        UpdateOperationKind.taskList => RenameTaskListOperation(
          taskListId: claim.taskListRemoteId,
          title: claim.title,
        ),
      };
}

abstract interface class UpdateSyncStore {
  Future<void> recoverUpdateAttempts({
    required AccountId accountId,
    required DateTime recoveredAt,
  });

  Future<int> confirmNoOpUpdates({
    required AccountId accountId,
    required String runId,
    required DateTime confirmedAt,
  });

  Future<ContentReconciliationSummary> reconcileContent({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  });

  Future<void> prepareTaskUpdateReplan({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required DateTime replannedAt,
  });

  Future<UpdateOperationClaim?> claimNextUpdate({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  });

  Future<void> acknowledgeTaskListUpdate({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required RemoteTaskList remote,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> acknowledgeTaskUpdate({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> resolveUpdateFailure({
    required AccountId accountId,
    required UpdateOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  });
}
