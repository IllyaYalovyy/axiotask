import '../../core/outcome.dart';
import '../commands/task_commands.dart';
import '../model/tasks.dart';

abstract interface class TasksRepository {
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query);

  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId);

  Future<Outcome<TaskId>> createTask(CreateTaskCommand command);

  Future<Outcome<void>> apply(ExistingTaskCommand command);

  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command);

  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command);
}
