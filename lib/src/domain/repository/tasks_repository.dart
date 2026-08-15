import '../../core/outcome.dart';
import '../commands/task_commands.dart';
import '../model/tasks.dart';

abstract interface class TasksRepository {
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query);

  Future<Outcome<TaskId>> createTask(CreateTaskCommand command);

  Future<Outcome<void>> apply(ExistingTaskCommand command);
}
