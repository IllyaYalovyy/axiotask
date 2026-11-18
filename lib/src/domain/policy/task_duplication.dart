import '../commands/task_commands.dart';
import '../model/tasks.dart';

/// The suffix that marks a duplicate's title.
const duplicateTitleSuffix = ' (copy)';

/// What Duplicate creates for one source task.
///
/// This is the v1.5.3 rule (`duplicateTask` in `lib/src/ui/task_actions.dart`,
/// shared there by the detail overflow, desktop context menu and bulk bar):
///
/// * the copy is ONE new task titled "`<title>` (copy)";
/// * it is created in the source's list and under the source's parent, so a
///   duplicated subtask stays a subtask and the one-level hierarchy holds;
/// * notes and the due date are not copied, and the copy starts open
///   (needs action) even when the source is completed;
/// * subtasks are not copied: duplicating a parent creates a childless task;
/// * the copy is an ordinary create with no predecessor, so Google places it
///   first among its siblings, as v1.5.3's insert without `previous` did.
///
/// The copy never shares the source's identity: it receives a new local ID
/// and no remote ID, ETag, link or base, and nothing about the source changes.
final class TaskDuplicatePlan {
  const TaskDuplicatePlan({
    required this.sourceTaskId,
    required this.taskListId,
    required this.parentTaskId,
    required this.title,
  });

  final TaskId sourceTaskId;
  final TaskListId taskListId;
  final TaskId? parentTaskId;
  final String title;

  String? get notes => null;
  TaskStatus get status => TaskStatus.needsAction;
  TaskDate? get due => null;

  /// The ordinary create command that publishes the copy.
  CreateTaskCommand toCreateCommand(AccountId accountId) => CreateTaskCommand(
    accountId: accountId,
    taskListId: taskListId,
    parentTaskId: parentTaskId,
    title: title,
    notes: notes,
    status: status,
    due: due,
  );
}

/// Plans the duplicate of [source] according to [TaskDuplicatePlan].
TaskDuplicatePlan planTaskDuplicate(CachedTask source) => TaskDuplicatePlan(
  sourceTaskId: source.id,
  taskListId: source.taskListId,
  parentTaskId: source.parentTaskId,
  title: '${source.title}$duplicateTitleSuffix',
);
