# UX Decisions (FAQ)

The pivotal user-experience decisions — which use cases we support, why, and how.
A short FAQ, not a full spec. Implementation and architecture live in
`design_decisions.md`.

Every entry here is an **intentional decision — not a limitation, a gap, or a bug
to be fixed.** Do not "improve" or "fix" any of these without an explicit decision
to change direction.

**Q: What is the main list?**
A flat list of top-level tasks only — no tree, no indent, no expand/collapse.
This single-level list is a **deliberate decision, not a limitation or a gap**:
it is intentionally not a tree and not a nested list, and must not be "fixed" into
one. Why: a two-level tree in the list is cluttered and hard to scan, and Google
supports only two levels anyway. How: subtasks never appear as rows in any list or
smart view.

**Q: Where do subtasks live?**
Only in a task's detail (side) panel. The parent↔subtask bond is strong and
enforced — a subtask is never orphaned or mixed into the main list. Why: in
Google's UI subtasks get disconnected and lost among everything else; here the
relationship is the point. How: subtasks are viewed, added, dated, checked off,
reordered, and completed only through their parent.

**Q: How do I know a task has subtasks without opening it?**
The task widget shows subtask progress (how many are done). The widget keeps its
normal look; only the expand/collapse control is gone. Why: at-a-glance awareness
without cluttering the list.

**Q: How do I add a subtask?**
From the parent's detail panel, via an inline "add a subtask" field — type a
title, press Enter, keep adding. Why: fast, in-context entry with no navigation.
There is no add-subtask button on list rows.

**Q: Can I turn an existing top-level task into a subtask?**
Yes, but deliberately: you pick the target parent from a searchable picker (the
list can be long) — never a one-key gesture. Only a task that has no subtasks of
its own can be demoted, since that would otherwise create a third level.

**Q: Can a subtask become a top-level task again?**
Yes — "Detach from parent" in the detail panel promotes it to top-level. That is
the one intentional way to break the bond.

**Q: What happens to subtasks when I complete or delete a parent?**
Completing a parent completes all its subtasks. Un-completing a parent does not
reopen them automatically — there is an explicit "un-complete all subtasks"
action for that. Deleting a task deletes its whole subtree, with no confirmation
prompt (Undo is available).

**Q: Can I hide completed subtasks, or reorder them?**
Yes — an optional "hide completed" toggle in the panel, and drag-to-reorder
subtasks within the parent (which still works while completed ones are hidden).

**Q: Can a subtask live in a different list than its parent?**
No. A list is a property of the top-level task. A subtask always belongs to its
parent's list and moves only with the parent; moving a task to another list
carries its subtasks along.

**Q: How do tasks land in Focus / Upcoming / Missed?**
By their effective date — a task's own due date, or the earliest date among its
unfinished subtasks. A dated subtask surfaces its parent card in these views; the
subtask never appears as its own card. Why: you act on the parent, and its
subtasks' deadlines still pull it forward.

**Q: What are the smart views?**
Focus, Upcoming, Missed, Unscheduled, and All Tasks — top-level tasks grouped by
effective date, so the user sees what needs attention without scanning lists by
hand.

**Q: How does search work?**
It searches titles and notes, including subtasks. Opening a found subtask always
shows it within its parent's context — never as a loose, standalone item.

**Q: Is the app keyboard-driven?**
Yes, keyboard-first. j/k navigate; single keys act (complete, edit, delete, set
due today/tomorrow/next-week/next-month, select, search). A cheatsheet lists them.

**Q: How does quick-add behave?**
An always-visible input creates a task in the current view. It parses
natural-language dates with a live preview, and never creates an invisible task —
a task made in a dated view is given a matching date so it appears where it was
created.

**Q: How visible is sync?**
Background and quiet. Sync failures never hide local data — the list stays usable.
A dead session shows a clear "sign in again" action instead of failing silently.

**Q: Can I undo destructive actions?**
Yes — completing, deleting, and moving a task each surface an Undo toast.

**Q: Are there lists that don't sync?**
Yes — local-only lists live entirely on the device and are never pushed to
Google, for private or scratch tasks.
