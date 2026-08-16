import '../model/tasks.dart';

final class DirectChildProgress {
  const DirectChildProgress({required this.completed, required this.total})
    : assert(completed >= 0),
      assert(total >= 0),
      assert(completed <= total);

  final int completed;
  final int total;

  double? get fraction => total == 0 ? null : completed / total;

  String get label => total == 0
      ? 'No subtasks'
      : '$completed of $total ${total == 1 ? 'subtask' : 'subtasks'} complete';

  @override
  bool operator ==(Object other) =>
      other is DirectChildProgress &&
      completed == other.completed &&
      total == other.total;

  @override
  int get hashCode => Object.hash(completed, total);
}

DirectChildProgress projectDirectChildProgress({
  required TaskId parentTaskId,
  required Iterable<CachedTask> tasks,
}) {
  var completed = 0;
  var total = 0;
  for (final task in tasks) {
    if (task.parentTaskId != parentTaskId) continue;
    total += 1;
    if (task.status == TaskStatus.completed) completed += 1;
  }
  return DirectChildProgress(completed: completed, total: total);
}
