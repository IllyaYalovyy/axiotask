import '../domain/model/tasks.dart';

enum DesktopTaskDropPlacement { before, after }

final class DesktopTaskDragPayload {
  const DesktopTaskDragPayload({
    required this.taskId,
    required this.sourceTaskListId,
    required this.parentTaskId,
    required this.title,
  });

  factory DesktopTaskDragPayload.fromTask(CachedTask task) =>
      DesktopTaskDragPayload(
        taskId: task.id,
        sourceTaskListId: task.taskListId,
        parentTaskId: task.parentTaskId,
        title: task.title,
      );

  final TaskId taskId;
  final TaskListId sourceTaskListId;
  final TaskId? parentTaskId;
  final String title;
}

final class DesktopTaskDropIntent {
  const DesktopTaskDropIntent.reorder({
    required this.taskId,
    required this.destinationTaskListId,
    required this.parentTaskId,
    required this.previousTaskId,
  });

  final TaskId taskId;
  final TaskListId destinationTaskListId;
  final TaskId? parentTaskId;
  final TaskId? previousTaskId;

  @override
  bool operator ==(Object other) =>
      other is DesktopTaskDropIntent &&
      other.taskId == taskId &&
      other.destinationTaskListId == destinationTaskListId &&
      other.parentTaskId == parentTaskId &&
      other.previousTaskId == previousTaskId;

  @override
  int get hashCode =>
      Object.hash(taskId, destinationTaskListId, parentTaskId, previousTaskId);
}

/// Maps pointer geometry to the existing stable-ID MOVE command boundary.
/// Canonical sibling order remains owned by repository and sync projections.
abstract final class DesktopTaskDragAdapter {
  static DesktopTaskDropIntent? reorder({
    required DesktopTaskDragPayload payload,
    required CachedTask target,
    required DesktopTaskDropPlacement placement,
    required List<CachedTask> canonicalSiblings,
    required bool manualOrderEnabled,
  }) {
    if (reorderRejectionReason(
          payload: payload,
          target: target,
          placement: placement,
          canonicalSiblings: canonicalSiblings,
          manualOrderEnabled: manualOrderEnabled,
        ) !=
        null) {
      return null;
    }
    final sourceIndex = canonicalSiblings.indexWhere(
      (task) => task.id == payload.taskId,
    );

    final reordered = canonicalSiblings.toList(growable: true);
    final moved = reordered.removeAt(sourceIndex);
    final reducedTargetIndex = reordered.indexWhere(
      (task) => task.id == target.id,
    );
    final insertionIndex =
        reducedTargetIndex +
        (placement == DesktopTaskDropPlacement.after ? 1 : 0);
    reordered.insert(insertionIndex, moved);
    return DesktopTaskDropIntent.reorder(
      taskId: payload.taskId,
      destinationTaskListId: target.taskListId,
      parentTaskId: target.parentTaskId,
      previousTaskId: insertionIndex == 0
          ? null
          : reordered[insertionIndex - 1].id,
    );
  }

  static String? reorderRejectionReason({
    required DesktopTaskDragPayload payload,
    required CachedTask target,
    required DesktopTaskDropPlacement placement,
    required List<CachedTask> canonicalSiblings,
    required bool manualOrderEnabled,
  }) {
    if (!manualOrderEnabled) return 'Manual order is required here.';
    if (payload.taskId == target.id) {
      return 'A task cannot be dropped on itself.';
    }
    if (payload.sourceTaskListId != target.taskListId ||
        payload.parentTaskId != target.parentTaskId) {
      return 'Tasks can only be reordered with their siblings.';
    }
    if (canonicalSiblings.any(
      (task) =>
          task.taskListId != target.taskListId ||
          task.parentTaskId != target.parentTaskId,
    )) {
      return 'This drop target is not available.';
    }
    final sourceIndex = canonicalSiblings.indexWhere(
      (task) => task.id == payload.taskId,
    );
    final targetIndex = canonicalSiblings.indexWhere(
      (task) => task.id == target.id,
    );
    if (sourceIndex < 0 || targetIndex < 0) {
      return 'This drop target is not available.';
    }
    final reordered = canonicalSiblings.toList(growable: true);
    final moved = reordered.removeAt(sourceIndex);
    final reducedTargetIndex = reordered.indexWhere(
      (task) => task.id == target.id,
    );
    final insertionIndex =
        reducedTargetIndex +
        (placement == DesktopTaskDropPlacement.after ? 1 : 0);
    reordered.insert(insertionIndex, moved);
    return _sameOrder(canonicalSiblings, reordered)
        ? 'This drop keeps the current order.'
        : null;
  }

  static DesktopTaskDropIntent? moveToList({
    required DesktopTaskDragPayload payload,
    required TaskListId destinationTaskListId,
  }) {
    if (moveToListRejectionReason(
          payload: payload,
          destinationTaskListId: destinationTaskListId,
        ) !=
        null) {
      return null;
    }
    return DesktopTaskDropIntent.reorder(
      taskId: payload.taskId,
      destinationTaskListId: destinationTaskListId,
      parentTaskId: null,
      previousTaskId: null,
    );
  }

  static String? moveToListRejectionReason({
    required DesktopTaskDragPayload payload,
    required TaskListId destinationTaskListId,
  }) => payload.sourceTaskListId == destinationTaskListId
      ? 'This task is already in that list.'
      : null;

  static bool _sameOrder(List<CachedTask> left, List<CachedTask> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index].id != right[index].id) return false;
    }
    return true;
  }
}

abstract final class DesktopDragAutoscroll {
  static const double edgeExtent = 48;
  static const double step = 64;

  static double? targetOffset({
    required double currentOffset,
    required double minOffset,
    required double maxOffset,
    required double pointerY,
    required double viewportHeight,
  }) {
    final delta = pointerY < edgeExtent
        ? -step
        : pointerY > viewportHeight - edgeExtent
        ? step
        : 0;
    if (delta == 0) return null;
    final target = (currentOffset + delta).clamp(minOffset, maxOffset);
    return target == currentOffset ? null : target;
  }
}
