// Pure predicates enforcing the strict two-level tree (invariant #1) — the Dart
// port of `taskTree.js`. Single source of truth: every mutation path (adding a
// subtask, reparenting/moving, the context menu) asks the same question here
// instead of re-deriving it and drifting. A top-level task may have a flat list
// of subtasks; a subtask may have none. There is no third level, ever.

import 'task.dart';

/// A task is a subtask iff it has a parent.
bool isSubtask(Task? task) => task?.parent != null;

/// True iff some task in [tasks] points at [id] as its parent.
bool hasSubtasks(String id, Iterable<Task> tasks) =>
    tasks.any((t) => t.parent == id);

/// A task can gain a subtask only when it is itself top-level. A subtask can
/// never gain one — that would create a third level.
bool canAddSubtask(Task? parent) => parent != null && parent.parent == null;

/// A task ([childId]) may be nested under [parent] only when the parent exists
/// and is itself top-level (nesting under a subtask would be a third level),
/// the child has no subtasks of its own (a task with subtasks can't become a
/// subtask, or its children would become a third level), and it isn't being
/// nested under itself.
bool canNestUnder(String childId, Task? parent, Iterable<Task> tasks) {
  if (parent == null) return false;
  if (parent.id == childId) return false;
  if (isSubtask(parent)) return false;
  if (hasSubtasks(childId, tasks)) return false;
  return true;
}
