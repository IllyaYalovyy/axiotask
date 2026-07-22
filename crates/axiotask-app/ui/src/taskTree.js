// The task tree is STRICTLY two levels (invariant #1): a top-level task may
// have a flat list of subtasks, and a subtask may have none. There is no third
// level, ever. These pure predicates are the single source of truth for that
// rule so every mutation path — adding a subtask, reparenting/moving, the
// context menu — asks the same question instead of re-deriving it (and drifting).

export function isSubtask(task) {
  return !!task?.parent_id;
}

export function hasSubtasks(id, tasks) {
  return tasks.some((t) => t.parent_id === id);
}

// A task can gain a subtask only when it is itself top-level. A subtask can
// never gain one — that would create a third level.
export function canAddSubtask(parent) {
  return !!parent && !parent.parent_id;
}

// A task (`childId`) may be nested under `parent` only when:
//  - the parent exists and is itself top-level (nesting under a subtask would
//    be a third level), and
//  - the child has no subtasks of its own (a task with subtasks can't become a
//    subtask, or its children would become a third level), and
//  - it isn't being nested under itself.
export function canNestUnder(childId, parent, tasks) {
  if (!parent) return false;
  if (parent.id === childId) return false;
  if (isSubtask(parent)) return false;
  if (hasSubtasks(childId, tasks)) return false;
  return true;
}
