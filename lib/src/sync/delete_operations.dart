import '../core/failure.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../domain/model/tasks.dart';

enum DeleteOperationKind { taskList, task }

final class DeleteOperationClaim {
  const DeleteOperationClaim({
    required this.kind,
    required this.attemptId,
    required this.generation,
    required this.taskListId,
    required this.taskListRemoteId,
    required this.taskId,
    required this.taskRemoteId,
    required this.etag,
  });

  final DeleteOperationKind kind;
  final int attemptId;
  final int generation;
  final TaskListId taskListId;
  final TaskListRemoteId taskListRemoteId;
  final TaskId? taskId;
  final TaskRemoteId? taskRemoteId;
  final String? etag;
}

final class DeleteOperationMapper {
  const DeleteOperationMapper();

  GoogleTasksMutationOperation<void> map(DeleteOperationClaim claim) =>
      switch (claim.kind) {
        DeleteOperationKind.taskList => DeleteTaskListOperation(
          RemoteTaskListId(claim.taskListRemoteId.value),
        ),
        DeleteOperationKind.task => DeleteTaskOperation(
          taskListId: RemoteTaskListId(claim.taskListRemoteId.value),
          taskId: RemoteTaskId(claim.taskRemoteId!.value),
          etag: claim.etag!,
          pathFreshness: MutationPathFreshness.current,
        ),
      };
}

abstract interface class DeleteSyncStore {
  Future<void> recoverDeletes({
    required AccountId accountId,
    required DateTime recoveredAt,
  });

  Future<void> reconcileDeletes({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  });

  Future<DeleteOperationClaim?> claimNextDelete({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  });

  Future<void> acknowledgeTaskListDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> acknowledgeTaskDelete({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> resolveDeleteFailure({
    required AccountId accountId,
    required DeleteOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  });
}
