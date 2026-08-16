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
