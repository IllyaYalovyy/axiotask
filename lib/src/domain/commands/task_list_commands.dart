import '../../core/failure.dart';
import '../model/tasks.dart';

sealed class TaskListCommand {
  const TaskListCommand({required this.accountId, required this.title});

  final AccountId accountId;
  final String title;
}

final class CreateTaskListCommand extends TaskListCommand {
  const CreateTaskListCommand({required super.accountId, required super.title});
}

final class RenameTaskListCommand extends TaskListCommand {
  const RenameTaskListCommand({
    required super.accountId,
    required this.taskListId,
    required super.title,
  });

  final TaskListId taskListId;
}

Failure? validateTaskListCommand(TaskListCommand command) {
  if (command.title.length <= 1024) return null;
  return const Failure(
    code: 'task_list.title_too_long',
    category: FailureCategory.internal,
    operation: FailureOperation.write,
    retry: RetryClassification.permanent,
    impact: 'The task list title was not saved.',
    safeSummary: 'The task list title exceeds the supported field bound.',
  );
}
