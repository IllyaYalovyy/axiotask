import '../../core/failure.dart';
import '../model/tasks.dart';
import '../policy/bulk_capture.dart';

sealed class TaskCommand {
  const TaskCommand({required this.accountId});

  final AccountId accountId;
}

final class CreateTaskCommand extends TaskCommand {
  const CreateTaskCommand({
    required super.accountId,
    required this.taskListId,
    required this.title,
    this.parentTaskId,
    this.notes,
    this.status = TaskStatus.needsAction,
    this.due,
  });

  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;
}

final class BulkCreateTasksCommand extends TaskCommand {
  const BulkCreateTasksCommand({
    required super.accountId,
    required this.taskListId,
    required this.entries,
  });

  final TaskListId taskListId;
  final List<BulkCaptureEntry> entries;
}

sealed class BulkExistingTaskCommand extends TaskCommand {
  const BulkExistingTaskCommand({
    required super.accountId,
    required this.taskIds,
  });

  final Set<TaskId> taskIds;
}

final class BulkCompleteTasksCommand extends BulkExistingTaskCommand {
  const BulkCompleteTasksCommand({
    required super.accountId,
    required super.taskIds,
  });
}

final class BulkRescheduleTasksCommand extends BulkExistingTaskCommand {
  const BulkRescheduleTasksCommand({
    required super.accountId,
    required super.taskIds,
    required this.due,
  });

  final TaskDate? due;
}

final class BulkMoveTasksCommand extends BulkExistingTaskCommand {
  const BulkMoveTasksCommand({
    required super.accountId,
    required super.taskIds,
    required this.destinationTaskListId,
  });

  final TaskListId destinationTaskListId;
}

final class BulkDeleteTasksCommand extends BulkExistingTaskCommand {
  const BulkDeleteTasksCommand({
    required super.accountId,
    required super.taskIds,
  });
}

final class ClearCompletedTasksCommand extends TaskCommand {
  const ClearCompletedTasksCommand({
    required super.accountId,
    required this.taskListId,
  });

  final TaskListId taskListId;
}

sealed class ExistingTaskCommand extends TaskCommand {
  const ExistingTaskCommand({required super.accountId, required this.taskId});

  final TaskId taskId;
}

final class SetTaskTitleCommand extends ExistingTaskCommand {
  const SetTaskTitleCommand({
    required super.accountId,
    required super.taskId,
    required this.title,
  });

  final String title;
}

final class SetTaskNotesCommand extends ExistingTaskCommand {
  const SetTaskNotesCommand({
    required super.accountId,
    required super.taskId,
    required this.notes,
  });

  final String? notes;
}

final class SetTaskDueCommand extends ExistingTaskCommand {
  const SetTaskDueCommand({
    required super.accountId,
    required super.taskId,
    required this.due,
  });

  final TaskDate? due;
}

final class UndoTaskDueChangeCommand extends TaskCommand {
  const UndoTaskDueChangeCommand({
    required super.accountId,
    required this.groupId,
  });

  final int groupId;
}

final class SetTaskCompletionCommand extends ExistingTaskCommand {
  const SetTaskCompletionCommand({
    required super.accountId,
    required super.taskId,
    required this.status,
  });

  final TaskStatus status;
}

/// Reverses one completion command identified by its receipt.
final class UndoTaskCompletionCommand extends TaskCommand {
  const UndoTaskCompletionCommand({
    required super.accountId,
    required this.operationId,
  });

  final int operationId;
}

/// The outcome of one completion or reopen command.
///
/// [changedTaskIds] are exactly the tasks whose status the command wrote, in
/// the order they were written. [undo] is present only when the command
/// completed at least one task.
final class TaskCompletionReceipt {
  TaskCompletionReceipt({required List<TaskId> changedTaskIds, this.undo})
    : changedTaskIds = List<TaskId>.unmodifiable(changedTaskIds);

  final List<TaskId> changedTaskIds;
  final TaskCompletionUndo? undo;
}

/// The offer to reverse one committed completion command.
///
/// The offer belongs to the running application: it is superseded by any
/// later status change committed through the same repository, and it expires
/// at [expiresAt]. [title] names the primary task, or is null for a bulk
/// completion of [completedCount] tasks.
final class TaskCompletionUndo {
  const TaskCompletionUndo({
    required this.operationId,
    required this.title,
    required this.completedCount,
    required this.cascadedCount,
    required this.createdAt,
    required this.expiresAt,
  });

  final int operationId;
  final String? title;
  final int completedCount;
  final int cascadedCount;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.toUtc().isBefore(expiresAt);
}

/// What an Undo of a completion restored.
///
/// [skippedTaskIds] were recorded by the completion but were deleted or had
/// their status changed afterwards, so Undo left them as they are.
/// [alreadyUndone] marks an idempotent retry of an Undo that already
/// committed; it changes nothing.
final class TaskCompletionUndoResult {
  TaskCompletionUndoResult({
    required List<TaskId> restoredTaskIds,
    required List<TaskId> skippedTaskIds,
    this.alreadyUndone = false,
  }) : restoredTaskIds = List<TaskId>.unmodifiable(restoredTaskIds),
       skippedTaskIds = List<TaskId>.unmodifiable(skippedTaskIds);

  final List<TaskId> restoredTaskIds;
  final List<TaskId> skippedTaskIds;
  final bool alreadyUndone;
}

final class PromoteTaskCommand extends ExistingTaskCommand {
  const PromoteTaskCommand({required super.accountId, required super.taskId});
}

final class DemoteTaskCommand extends ExistingTaskCommand {
  const DemoteTaskCommand({
    required super.accountId,
    required super.taskId,
    required this.parentTaskId,
  });

  final TaskId parentTaskId;
}

final class MoveTaskCommand extends ExistingTaskCommand {
  const MoveTaskCommand({
    required super.accountId,
    required super.taskId,
    required this.destinationTaskListId,
    this.parentTaskId,
    this.previousTaskId,
  });

  final TaskListId destinationTaskListId;
  final TaskId? parentTaskId;
  final TaskId? previousTaskId;
}

final class UpdateTaskContentCommand extends ExistingTaskCommand {
  const UpdateTaskContentCommand({
    required super.accountId,
    required super.taskId,
    required this.title,
    required this.notes,
    required this.status,
    required this.due,
  });

  final String title;
  final String? notes;
  final TaskStatus status;
  final TaskDate? due;
}

final class DeleteTaskCommand extends ExistingTaskCommand {
  const DeleteTaskCommand({required super.accountId, required super.taskId});
}

final class UndoTaskDeleteCommand extends ExistingTaskCommand {
  const UndoTaskDeleteCommand({
    required super.accountId,
    required super.taskId,
  });
}

final class UndoTaskDeleteGroupCommand extends TaskCommand {
  const UndoTaskDeleteGroupCommand({
    required super.accountId,
    required this.groupId,
  });

  final int groupId;
}

final class TaskDeleteReceipt {
  const TaskDeleteReceipt({required this.taskId, required this.notBefore});

  final TaskId taskId;
  final DateTime notBefore;
}

final class TaskDeleteUndo {
  const TaskDeleteUndo({
    required this.taskId,
    required this.title,
    required this.notBefore,
  });

  final TaskId taskId;
  final String title;
  final DateTime notBefore;
}

final class TaskDeleteGroupUndo {
  const TaskDeleteGroupUndo({
    required this.groupId,
    required this.selectedCount,
    required this.rootCount,
    required this.notBefore,
  });

  final int groupId;
  final int selectedCount;
  final int rootCount;
  final DateTime notBefore;
}

final class TaskDueChangeReceipt {
  const TaskDueChangeReceipt({required this.undo});

  final TaskDueChangeUndo? undo;
}

final class TaskDueChangeUndo {
  const TaskDueChangeUndo({
    required this.groupId,
    required this.editedTaskId,
    required this.editedTaskTitle,
    required this.cascadedCount,
    required this.cascadedParent,
    required this.createdAt,
  });

  final int groupId;
  final TaskId editedTaskId;
  final String editedTaskTitle;
  final int cascadedCount;
  final bool cascadedParent;
  final DateTime createdAt;
}

Failure? validateTaskCommand(TaskCommand command) {
  final title = switch (command) {
    CreateTaskCommand(:final title) ||
    SetTaskTitleCommand(:final title) ||
    UpdateTaskContentCommand(:final title) => title,
    _ => null,
  };
  if (title != null && title.length > 1024) {
    return const Failure(
      code: 'task.title_too_long',
      category: FailureCategory.internal,
      operation: FailureOperation.write,
      retry: RetryClassification.permanent,
      impact: 'The task was not saved.',
      safeSummary: 'The task title exceeds the supported field bound.',
    );
  }
  final notes = switch (command) {
    CreateTaskCommand(:final notes) ||
    SetTaskNotesCommand(:final notes) ||
    UpdateTaskContentCommand(:final notes) => notes,
    _ => null,
  };
  if (notes != null && notes.length > 8192) {
    return const Failure(
      code: 'task.notes_too_long',
      category: FailureCategory.internal,
      operation: FailureOperation.write,
      retry: RetryClassification.permanent,
      impact: 'The task was not saved.',
      safeSummary: 'The task notes exceed the supported field bound.',
    );
  }
  return null;
}

Failure? validateBulkCreateTasksCommand(BulkCreateTasksCommand command) {
  if (command.entries.isEmpty || command.entries.length > maxBulkCaptureTasks) {
    return const Failure(
      code: 'bulk_capture.invalid_count',
      category: FailureCategory.internal,
      operation: FailureOperation.write,
      retry: RetryClassification.permanent,
      impact: 'No tasks were saved.',
      safeSummary: 'The bulk task count is outside the supported bound.',
    );
  }
  for (final entry in command.entries) {
    if (entry.title.trim().isEmpty ||
        entry.title.length > maxBulkCaptureTitleCharacters ||
        (entry.notes?.length ?? 0) > maxBulkCaptureNotesCharacters ||
        containsUnsupportedBulkControlCharacters(entry.title) ||
        (entry.notes != null &&
            containsUnsupportedBulkControlCharacters(entry.notes!))) {
      return const Failure(
        code: 'bulk_capture.invalid_entry',
        category: FailureCategory.internal,
        operation: FailureOperation.write,
        retry: RetryClassification.permanent,
        impact: 'No tasks were saved.',
        safeSummary: 'At least one bulk task is invalid.',
      );
    }
  }
  return null;
}

Failure? validateBulkTaskCommand(BulkExistingTaskCommand command) {
  if (command.taskIds.isEmpty) {
    return const Failure(
      code: 'bulk_tasks.empty_selection',
      category: FailureCategory.internal,
      operation: FailureOperation.write,
      retry: RetryClassification.permanent,
      impact: 'No tasks were changed.',
      safeSummary: 'A bulk task command requires a non-empty selection.',
    );
  }
  return null;
}
