import '../../domain/model/search.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/search_repository.dart';
import '../../domain/repository/tasks_repository.dart';

/// Searches only the account-scoped, supported projection exposed by the task
/// repository. Raw, deleted, unsupported, and cross-account cache rows never
/// enter this boundary.
final class SupportedTaskSearchRepository implements SearchRepository {
  const SupportedTaskSearchRepository(this._tasks);

  final TasksRepository _tasks;

  @override
  Stream<List<TaskSearchResult>> watchSearch(TaskSearchQuery query) {
    if (query.isEmpty) return Stream.value(const <TaskSearchResult>[]);
    final needle = query.normalizedText;
    return _tasks
        .watchTasks(TasksQuery(accountId: query.accountId))
        .map((snapshot) => _search(snapshot, needle));
  }
}

List<TaskSearchResult> _search(CachedTasksSnapshot snapshot, String needle) {
  final lists = <TaskListId, String>{
    for (final list in snapshot.taskLists) list.id: list.title,
  };
  final tasks = <TaskId, CachedTask>{
    for (final task in snapshot.tasks) task.id: task,
  };
  final results = <TaskSearchResult>[];
  for (final task in snapshot.tasks) {
    final fields = <TaskSearchField>{};
    if (task.title.toLowerCase().contains(needle)) {
      fields.add(TaskSearchField.title);
    }
    if (task.notes?.toLowerCase().contains(needle) ?? false) {
      fields.add(TaskSearchField.notes);
    }
    if (fields.isEmpty) continue;
    final parent = task.parentTaskId == null ? task : tasks[task.parentTaskId];
    final listTitle = lists[task.taskListId];
    if (parent == null || listTitle == null) continue;
    results.add(
      TaskSearchResult(
        parent: parent,
        match: task,
        taskListTitle: listTitle,
        matchedFields: fields,
      ),
    );
  }
  return List<TaskSearchResult>.unmodifiable(results);
}
