# MVP User Tasks

All user tasks axiotask must support for MVP release.

Each task defines:
- **Precondition** — what must be true before the user starts
- **Flow** — the sequence of interactions (keyboard primary, mouse alternative)
- **Outcome** — what the user sees when done
- **Interactions** — count of discrete user actions in the happy path

---

## Authentication & Sync

### UT-01: Sign in with Google

**Precondition:** App launched, not authenticated. Config has valid client_id/secret.

**Flow:**
1. Click "Sign in with Google" button in sidebar
2. Browser opens Google consent screen
3. User authorizes in browser
4. Browser shows "Login successful" — user returns to app

**Outcome:** Sidebar shows "Sync now" and "Fresh sync" buttons. Sync dot turns green. Auto-sync pulls tasks.

**Interactions:** 2 (click button + authorize in browser)

---

### UT-02: Sync tasks from Google (pull)

**Precondition:** Authenticated.

**Flow:**
1. Click "↻ Sync now" in sidebar

**Outcome:** Sync dot pulses orange during sync. Tasks update in the list. Status shows "Synced just now".

**Interactions:** 1

---

### UT-03: Fresh sync (drop local, re-pull)

**Precondition:** Authenticated.

**Flow:**
1. Click "⟳ Fresh sync" in sidebar
2. Confirm in dialog ("Drop all local data and re-download from Google?")

**Outcome:** All local tasks replaced with remote state. Lists and counts refresh.

**Interactions:** 2

---

### UT-04: Sign out

**Precondition:** Authenticated.

**Flow:** *Not yet implemented.*

**Outcome:** Tokens cleared. Sidebar returns to "Sign in with Google" state. Local data preserved.

---

## Task CRUD

### UT-05: Create a new task

**Precondition:** Any view active.

**Flow (keyboard):**
1. Press `n`

**Flow (mouse):**
1. Click "+ New task" button in toolbar

**Outcome:** Empty task appears at top of list, focused, in edit mode (cursor in title field). User types title and presses Enter to confirm.

**Interactions:** 1 (then typing + Enter to name it)

**Design note:** Task is created immediately in the store with empty title. If user presses Escape without typing, an empty "Untitled" task remains. This is intentional — no phantom states.

---

### UT-06: Edit task title

**Precondition:** Task visible in list.

**Flow (keyboard):**
1. Navigate to task with `j`/`k`
2. Press `e`
3. Edit text
4. Press Enter to confirm (or Escape to cancel)

**Flow (mouse):**
1. Double-click the task title

**Flow (detail panel):**
1. Open detail panel (Enter or click)
2. Edit title field
3. Auto-saves on navigation/close

**Outcome:** Title updated in list and store.

**Interactions:** 2 (focus + edit key) or 1 (double-click)

---

### UT-07: Edit task notes

**Precondition:** Task exists.

**Flow:**
1. Open detail panel (Enter on focused task, or click task)
2. Edit the Notes textarea
3. Auto-saves on close/navigation

**Outcome:** Notes stored. 📝 badge appears on task widget.

**Interactions:** 2 (open panel + type)

---

### UT-08: Set due date (today, tomorrow, next week, next month, specific date)

**Precondition:** Task visible in list.

**Flow (keyboard — relative):**
1. Focus task with `j`/`k`
2. Press `o` (today), `t` (tomorrow), `w` (next week), or `m` (next month)

**Flow (mouse — relative):**
1. Hover task to reveal action buttons
2. Click →o, →t, →w, or →m

**Flow (specific date):**
1. Open detail panel (Enter)
2. Click/edit the due date input field
3. Select date from native date picker

**Outcome:** Due date badge appears on task (e.g. "today", "tomorrow", "in 3d", "Jun 15"). Task appears in relevant smart views.

**Interactions:** 2 (focus + key) or 2 (hover + click) or 3 (open panel + click field + pick date)

---

### UT-09: Clear due date

**Precondition:** Task has a due date.

**Flow (keyboard):**
1. Focus task
2. Press `r`

**Flow (mouse):**
1. Hover task — ✕ button visible
2. Click ✕

**Flow (detail panel):**
1. Open detail panel
2. Click "Clear" button in due date section

**Outcome:** Due date badge replaced with "no date". Task moves to Unscheduled view.

**Interactions:** 2 (focus + key) or 2 (hover + click)

---

### UT-10: Complete a task

**Precondition:** Task is open (status: needsAction).

**Flow (keyboard):**
1. Focus task
2. Press Space

**Flow (mouse):**
1. Click the checkbox (☐)

**Outcome:** Checkbox becomes ☑. Task gets strikethrough + fade. After 300ms animation, task moves to "completed" section (if "Show completed" is on) or disappears. Undo toast appears for 10s.

**Interactions:** 1 (click) or 2 (focus + Space)

---

### UT-11: Uncomplete a task

**Precondition:** "Show completed" is on. Completed task visible.

**Flow:**
1. Click ☑ checkbox on the completed task (or focus + Space)

**Outcome:** Task returns to active list. Strikethrough removed.

**Interactions:** 1

---

### UT-12: Delete a task

**Precondition:** Task visible.

**Flow (keyboard):**
1. Focus task
2. Press `d`

**Flow (context menu):**
1. Right-click task
2. Click "Delete"

**Outcome:** Task disappears. Undo toast appears for 10s.

**Interactions:** 2 (focus + key) or 2 (right-click + click)

---

### UT-13: Undo delete

**Precondition:** Delete undo toast visible (within 10s of deletion).

**Flow:**
1. Click "Undo" on the toast

**Outcome:** Task restored to its original position and state.

**Interactions:** 1

---

## Subtasks

### UT-14: Create a subtask

**Precondition:** Parent task exists.

**Flow (from detail panel):**
1. Open detail panel for parent (Enter or click)
2. Click `+` button in Subtasks section

**Flow (from task row):**
1. Hover parent task
2. Click `+` button in action row

**Outcome:** Empty subtask created. Detail panel shows it in edit mode.

**Interactions:** 2

---

### UT-15: Edit a subtask (title, notes, due date)

**Precondition:** Parent task's detail panel is open, subtasks listed.

**Flow:**
1. Click subtask title in the Subtasks list
2. Panel switches to subtask view (header shows "Subtask", breadcrumb shows parent)
3. Edit title/notes/due date
4. Auto-saves on any navigation

**Outcome:** Subtask updated. Click "← Parent title" breadcrumb to go back.

**Interactions:** 1 (click subtask) + editing

---

### UT-16: Complete/uncomplete a subtask

**Precondition:** Detail panel open for parent, subtask listed.

**Flow:**
1. Click ☐/☑ next to subtask title

**Outcome:** Subtask toggles. Progress bar updates (e.g. "1/3").

**Interactions:** 1

---

### UT-17: Delete a subtask

**Precondition:** Subtask detail panel open.

**Flow:**
1. Click subtask to open its detail
2. Click "🗑️ Delete task" button

**Outcome:** Subtask removed. Panel returns to parent.

**Interactions:** 2

---

### UT-18: Navigate between subtasks

**Precondition:** Subtask detail panel open, parent has multiple subtasks.

**Flow:**
1. Click `›` (next) or `‹` (prev) arrows in panel header
2. Or press Ctrl+→ / Ctrl+←

**Outcome:** Panel shows next/prev sibling subtask. Auto-saves current before switching.

**Interactions:** 1

---

## Organization

### UT-19: View tasks in a specific list

**Precondition:** Lists loaded in sidebar.

**Flow:**
1. Click list name in sidebar

**Outcome:** Main area shows tasks from that list only. List highlighted in sidebar.

**Interactions:** 1

---

### UT-20: Move a task to a different list

**Precondition:** Task focused or selected, multiple lists exist.

**Flow (keyboard):**
1. Focus task
2. Press Ctrl+M
3. Arrow keys to target list
4. Press Enter

**Flow (detail panel):**
1. Open detail panel
2. Change the List dropdown
3. Auto-saves on close

**Outcome:** Task moves to new list. Toast confirms move.

**Interactions:** 3 (focus + Ctrl+M + Enter) or 2 (open panel + select)

---

### UT-21: Reorder tasks (manual drag or keyboard)

**Precondition:** Sort mode is "My order". Task visible.

**Flow (keyboard):**
1. Focus task
2. Alt+↑ or Alt+↓

**Flow (mouse):**
1. Drag the ⠿ handle to new position

**Outcome:** Task moves up/down in the list.

**Interactions:** 2 (focus + Alt+arrow) or 1 (drag)

---

### UT-22: Create a new list

**Precondition:** App loaded.

**Flow:**
1. Click `+` button next to "LISTS" header in sidebar
2. Type list name in prompt
3. Press OK/Enter

**Outcome:** New list appears in sidebar. Selected automatically.

**Interactions:** 3

---

### UT-23: Rename a list

**Precondition:** List exists.

**Flow:**
1. Right-click list in sidebar
2. Click "Rename"
3. Type new name in prompt
4. Press OK/Enter

**Outcome:** List name updated in sidebar.

**Interactions:** 4

---

### UT-24: Delete a list

**Precondition:** List exists.

**Flow:**
1. Right-click list in sidebar
2. Click "Delete"
3. Confirm in dialog

**Outcome:** List and its tasks removed.

**Interactions:** 3

---

## Smart Views

### UT-25: View Focus (due this week + overdue)

**Flow:** Click "★ Focus" in sidebar.

**Outcome:** Shows all tasks due within 7 days + all overdue tasks. Sorted by due date.

**Interactions:** 1

---

### UT-26: View Upcoming (due in 14 days)

**Flow:** Click "⏳ Upcoming" in sidebar.

**Outcome:** Shows tasks due between tomorrow and 14 days from now.

**Interactions:** 1

---

### UT-27: View Missed (overdue)

**Flow:** Click "△ Missed" in sidebar.

**Outcome:** Shows all tasks past their due date, oldest first.

**Interactions:** 1

---

### UT-28: View Unscheduled (no due date)

**Flow:** Click "○ Unscheduled" in sidebar.

**Outcome:** Shows all tasks without a due date.

**Interactions:** 1

---

### UT-29: View All Tasks

**Flow:** Click "▤ All Tasks" in sidebar.

**Outcome:** Shows every task across all lists (not excluded).

**Interactions:** 1

---

## Sort & Filter

### UT-30: Change sort order

**Precondition:** Any list or smart view active.

**Flow:**
1. Click "Sort: My order ▾" dropdown in toolbar
2. Click desired option (My order / Due date / Alphabetical / Recently created)

**Outcome:** Tasks reorder. Choice remembered per-view.

**Interactions:** 2

---

### UT-31: Show/hide completed tasks

**Flow:**
1. Click "Show completed" checkbox in toolbar

**Outcome:** Completed tasks appear at bottom (checked) or disappear (unchecked).

**Interactions:** 1

---

### UT-32: Clear completed tasks from a list

**Precondition:** "Show completed" is on, completed tasks exist.

**Flow:**
1. Click "Clear completed" button in toolbar
2. Confirm in dialog

**Outcome:** All completed tasks in current list permanently deleted.

**Interactions:** 2

---

## Search

### UT-33: Search across all tasks by title

**Flow (keyboard):**
1. Press `/`
2. Type search query
3. Results filter live
4. Press Enter or click to select

**Outcome:** Matching tasks shown. Selecting a task navigates to it.

**Interactions:** 1 (open) + typing + 1 (select)

---

## Navigation

### UT-34: Keyboard navigation through task list

**Flow:**
- `j` / `↓` — move focus down
- `k` / `↑` — move focus up

**Outcome:** Focus highlight moves. Focused task is the target for all keyboard actions.

**Interactions:** 1 per move

---

### UT-35: Open task detail panel

**Flow (keyboard):**
1. Focus task
2. Press Enter

**Flow (mouse):**
1. Click task row

**Outcome:** Detail panel opens on the right with title, due date, list, notes, subtasks.

**Interactions:** 1 (click) or 2 (focus + Enter)

---

### UT-36: Close task detail panel

**Flow:**
- Press Escape
- Or click ✕ button

**Outcome:** Panel closes. Auto-saves any edits.

**Interactions:** 1

---

### UT-37: Navigate to next/previous task from detail panel

**Flow:**
- Click `‹` / `›` arrows in panel header
- Or Ctrl+← / Ctrl+→

**Outcome:** Panel switches to prev/next sibling. Auto-saves current.

**Interactions:** 1

---

## Reschedule

### UT-38: Reschedule to today

**Keyboard:** Focus task + press `o`
**Mouse:** Hover task → click →o button

**Interactions:** 2 (keyboard) or 2 (mouse)

---

### UT-39: Reschedule to tomorrow

**Keyboard:** Focus task + press `t`
**Mouse:** Hover task → click →t button

**Interactions:** 2

---

### UT-40: Reschedule to next week

**Keyboard:** Focus task + press `w`
**Mouse:** Hover task → click →w button

**Interactions:** 2

---

### UT-41: Reschedule to next month

**Keyboard:** Focus task + press `m`
**Mouse:** Hover task → click →m button

**Interactions:** 2

---

### UT-42: Set a specific date (date picker)

**Flow:**
1. Open detail panel (Enter or click)
2. Click/edit the due date input
3. Select date from native picker or type YYYY-MM-DD

**Outcome:** Due date set to specific date.

**Interactions:** 3

---

## List Exclusion

### UT-43: Exclude a list from smart views

**Flow:**
1. Right-click list in sidebar
2. Click "Exclude from smart views"

**Outcome:** List's tasks no longer appear in Focus/Upcoming/Missed/Unscheduled. List remains accessible via direct click.

**Interactions:** 2

---

### UT-44: Include a list in smart views

**Flow:**
1. Right-click previously-excluded list in sidebar
2. Click "Include in smart views"

**Outcome:** List's tasks appear in smart views again.

**Interactions:** 2
