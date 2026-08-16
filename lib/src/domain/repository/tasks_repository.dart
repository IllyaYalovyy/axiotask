import '../../core/outcome.dart';
import '../commands/task_commands.dart';
import '../model/bulk_operations.dart';
import '../model/tasks.dart';

abstract interface class TasksRepository {
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query);

  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId);

  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  );

  Future<Outcome<TaskId>> createTask(CreateTaskCommand command);

  Future<Outcome<void>> apply(ExistingTaskCommand command);

  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(SetTaskDueCommand command);

  Future<Outcome<TaskDeleteReceipt>> deleteTask(DeleteTaskCommand command);

  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command);

  Future<Outcome<void>> undoTaskDueChange(UndoTaskDueChangeCommand command);
}

abstract interface class BulkTasksRepository {
  Future<Outcome<List<TaskId>>> createTasks(BulkCreateTasksCommand command);
}

abstract interface class BulkTaskOperationsRepository {
  Stream<BulkOperationSummary?> watchLatestBulkOperation(AccountId accountId);

  Future<Outcome<BulkOperationReceipt>> applyBulk(
    BulkExistingTaskCommand command,
  );
}

abstract interface class DestructiveTaskOperationsRepository {
  Stream<List<TaskDeleteGroupUndo>> watchUndoableTaskDeleteGroups(
    AccountId accountId,
  );

  Future<Outcome<BulkOperationReceipt>> clearCompleted(
    ClearCompletedTasksCommand command,
  );

  Future<Outcome<void>> undoTaskDeleteGroup(UndoTaskDeleteGroupCommand command);
}
