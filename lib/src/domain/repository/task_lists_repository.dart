import '../../core/outcome.dart';
import '../commands/task_list_commands.dart';
import '../model/tasks.dart';

abstract interface class TaskListsRepository {
  Future<Outcome<TaskListId>> createTaskList(CreateTaskListCommand command);

  Future<Outcome<void>> renameTaskList(RenameTaskListCommand command);

  Future<Outcome<void>> deleteTaskList(DeleteTaskListCommand command);
}
