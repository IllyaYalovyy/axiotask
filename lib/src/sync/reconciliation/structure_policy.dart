import '../../domain/model/tasks.dart';

enum StructureWinner { local, google, confirmed }

final class TaskPlacement {
  const TaskPlacement({
    required this.taskListId,
    required this.parentTaskId,
    required this.previousTaskId,
  });

  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final TaskId? previousTaskId;

  @override
  bool operator ==(Object other) =>
      other is TaskPlacement &&
      taskListId == other.taskListId &&
      parentTaskId == other.parentTaskId &&
      previousTaskId == other.previousTaskId;

  @override
  int get hashCode => Object.hash(taskListId, parentTaskId, previousTaskId);
}

final class TaskStructureSnapshot extends TaskPlacement {
  const TaskStructureSnapshot({
    required super.taskListId,
    required super.parentTaskId,
    required super.previousTaskId,
    required this.siblingOrderFingerprint,
  });

  final String siblingOrderFingerprint;
}

StructureWinner reconcileTaskStructure({
  required TaskStructureSnapshot base,
  required TaskPlacement local,
  required TaskStructureSnapshot remote,
}) {
  final remoteChanged =
      remote.taskListId != base.taskListId ||
      remote.parentTaskId != base.parentTaskId ||
      remote.previousTaskId != base.previousTaskId ||
      remote.siblingOrderFingerprint != base.siblingOrderFingerprint;
  if (remoteChanged) return StructureWinner.google;
  return local == remote ? StructureWinner.confirmed : StructureWinner.local;
}
