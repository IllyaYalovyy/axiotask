import '../model/tasks.dart';

abstract interface class TasksRepository {
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query);
}
