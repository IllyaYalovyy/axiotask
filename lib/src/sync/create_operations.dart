import '../core/failure.dart';
import '../data/google_tasks/dto.dart';
import '../data/google_tasks/mutation.dart';
import '../domain/model/tasks.dart';

enum CreateOperationKind { taskList, task }

final class CreateOperationClaim {
  const CreateOperationClaim.taskList({
    required this.attemptId,
    required this.generation,
    required this.taskListId,
    required this.title,
  }) : kind = CreateOperationKind.taskList,
       taskId = null,
       parentTaskId = null,
       taskListRemoteId = null,
       parentRemoteId = null,
       previousTaskId = null,
       previousRemoteId = null,
       notes = null,
       status = null,
       due = null;

  const CreateOperationClaim.task({
    required this.attemptId,
    required this.generation,
    required this.taskListId,
    required this.taskId,
    required this.parentTaskId,
    required this.taskListRemoteId,
    required this.parentRemoteId,
    required this.previousTaskId,
    required this.previousRemoteId,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  }) : kind = CreateOperationKind.task;

  final CreateOperationKind kind;
  final int attemptId;
  final int generation;
  final TaskListId taskListId;
  final TaskId? taskId;
  final TaskId? parentTaskId;
  final RemoteTaskListId? taskListRemoteId;
  final RemoteTaskId? parentRemoteId;
  final TaskId? previousTaskId;
  final RemoteTaskId? previousRemoteId;
  final String title;
  final String? notes;
  final TaskStatus? status;
  final TaskDate? due;
}

final class CreateOperationMapper {
  const CreateOperationMapper();

  GoogleTasksMutationOperation<Object?> map(
    CreateOperationClaim claim,
  ) => switch (claim.kind) {
    CreateOperationKind.taskList => CreateTaskListOperation(title: claim.title),
    CreateOperationKind.task => CreateTaskOperation(
      taskListId: claim.taskListRemoteId!,
      title: claim.title,
      notes: claim.notes,
      status: switch (claim.status!) {
        TaskStatus.needsAction => RemoteTaskStatus.needsAction,
        TaskStatus.completed => RemoteTaskStatus.completed,
      },
      due: switch (claim.due) {
        final TaskDate value => RemoteDate(value.year, value.month, value.day),
        null => null,
      },
      parentId: claim.parentRemoteId,
      previousId: claim.previousRemoteId,
    ),
  };
}

abstract interface class CreateSyncStore {
  Future<void> recoverCreateAttempts({
    required AccountId accountId,
    required DateTime recoveredAt,
  });

  Future<CreateOperationClaim?> claimNextCreate({
    required AccountId accountId,
    required String runId,
    required DateTime claimedAt,
  });

  Future<void> acknowledgeTaskListCreate({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required RemoteTaskList remote,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> acknowledgeTaskCreate({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required RemoteLiveTask remote,
    required String observationId,
    required DateTime acknowledgedAt,
  });

  Future<void> resolveCreateFailure({
    required AccountId accountId,
    required CreateOperationClaim claim,
    required Failure failure,
    required bool uncertain,
    required DateTime resolvedAt,
  });
}
