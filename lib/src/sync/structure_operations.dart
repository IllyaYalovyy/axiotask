import '../core/failure.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../domain/model/tasks.dart';

enum StructureSupersessionKind { taskPlacement, deleteWon }

final class StructureSupersessionResult {
  const StructureSupersessionResult({required this.kind, required this.count})
    : assert(count > 0);

  final StructureSupersessionKind kind;
  final int count;
}

final class StructureReconciliationSummary {
  const StructureReconciliationSummary({
    this.confirmedReadBacks = 0,
    this.localMovesPending = 0,
    this.supersessions = const <StructureSupersessionResult>[],
    this.failure,
  });

  final int confirmedReadBacks;
  final int localMovesPending;
  final List<StructureSupersessionResult> supersessions;
  final Failure? failure;
}

final class MoveOperationClaim {
  const MoveOperationClaim({
    required this.attemptId,
    required this.generation,
    required this.taskId,
    required this.taskRemoteId,
    required this.sourceTaskListId,
    required this.sourceTaskListRemoteId,
    required this.destinationTaskListId,
    required this.destinationTaskListRemoteId,
    required this.parentTaskId,
    required this.parentRemoteId,
    required this.previousTaskId,
    required this.previousRemoteId,
    required this.etag,
  });

  final int attemptId;
  final int generation;
  final TaskId taskId;
  final RemoteTaskId taskRemoteId;
  final TaskListId sourceTaskListId;
  final RemoteTaskListId sourceTaskListRemoteId;
  final TaskListId destinationTaskListId;
  final RemoteTaskListId destinationTaskListRemoteId;
  final TaskId? parentTaskId;
  final RemoteTaskId? parentRemoteId;
  final TaskId? previousTaskId;
  final RemoteTaskId? previousRemoteId;
  final String etag;
}

final class MoveOperationMapper {
  const MoveOperationMapper();

  MoveTaskOperation map(MoveOperationClaim claim) => MoveTaskOperation(
    sourceTaskListId: claim.sourceTaskListRemoteId,
    destinationTaskListId: claim.destinationTaskListId == claim.sourceTaskListId
        ? null
        : claim.destinationTaskListRemoteId,
    taskId: claim.taskRemoteId,
    etag: claim.etag,
    pathFreshness: MutationPathFreshness.current,
    parentId: claim.parentRemoteId,
    previousId: claim.previousRemoteId,
  );
}

abstract interface class StructureSyncStore {
  Future<StructureReconciliationSummary> reconcileStructure({
    required AccountId accountId,
    required String runId,
    required DateTime reconciledAt,
  });

  Future<MoveOperationClaim?> claimNextMove({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  });

  Future<void> acknowledgeMove({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> prepareMoveReplan({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required DateTime replannedAt,
  });

  Future<void> resolveMoveFailure({
    required AccountId accountId,
    required MoveOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  });
}
