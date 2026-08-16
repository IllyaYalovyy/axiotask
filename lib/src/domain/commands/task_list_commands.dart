import '../../core/failure.dart';
import '../model/tasks.dart';

sealed class TaskListCommand {
  const TaskListCommand({required this.accountId});

  final AccountId accountId;
}

final class CreateTaskListCommand extends TaskListCommand {
  const CreateTaskListCommand({required super.accountId, required this.title});

  final String title;
}

final class RenameTaskListCommand extends TaskListCommand {
  const RenameTaskListCommand({
    required super.accountId,
    required this.taskListId,
    required this.title,
  });

  final TaskListId taskListId;
  final String title;
}

final class DeleteTaskListCommand extends TaskListCommand {
  const DeleteTaskListCommand({
    required super.accountId,
    required this.taskListId,
  });

  final TaskListId taskListId;
}

Failure? validateTaskListCommand(TaskListCommand command) {
  if (command is DeleteTaskListCommand) return null;
  final title = switch (command) {
    CreateTaskListCommand(:final title) => title,
    RenameTaskListCommand(:final title) => title,
    DeleteTaskListCommand() => throw StateError('unreachable'),
  };
  if (title.length <= 1024) return null;
  return const Failure(
    code: 'task_list.title_too_long',
    category: FailureCategory.internal,
    operation: FailureOperation.write,
    retry: RetryClassification.permanent,
    impact: 'The task list title was not saved.',
    safeSummary: 'The task list title exceeds the supported field bound.',
  );
}
