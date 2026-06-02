# Smart Views & List Exclusion — UX Design

## Research: How Power Users Triage Tasks

### The Problem with "Today"
A single "Today" view fails because:
- Tasks due tomorrow that need prep today are invisible
- Overdue tasks mix with today's tasks, creating anxiety without clarity
- Tasks with no date are orphaned — never surface unless you hunt for them
- Users with 5+ lists can't see their full picture without clicking each one

### Mental Models Observed in Task Management
Users operate in three temporal modes:
1. **Execution mode** — "What do I do RIGHT NOW?" (next 1-2 hours)
2. **Planning mode** — "What's my week look like?" (next 7-14 days)
3. **Review mode** — "What fell through the cracks?" (overdue + unscheduled)

Each mode needs its own view. Forcing all three into one creates cognitive overload.

---

## Smart Views Design

### Focus View (default on launch)

**Purpose:** Your working set. Everything that needs attention today or has already slipped.

**Content:**
- Section 1: **Overdue** — tasks past their due date, sorted newest-first (most recently missed = most urgent)
- Section 2: **Due Today** — tasks due today
- Section 3: **Due This Week** — tasks due in the next 6 days (Mon-Sun of current week)

**Behavior:**
- Completing a task removes it from view immediately (no animation delay — instant feedback)
- Pressing `t` on an overdue task reschedules to today (stays in view)
- Pressing `w` moves it to next week (disappears from Focus)
- Empty state: "All clear for this week ✓" — positive reinforcement

**Excluded lists:** Tasks from excluded lists do NOT appear here.

---

### Upcoming View

**Purpose:** Planning horizon. See what's coming so you can prepare.

**Content:**
- Tasks due in the next 14 days
- Grouped by day: "Tomorrow (Tue)", "Wednesday", "Thursday", etc.
- Days with no tasks are not shown (no empty rows)
- After 7 days, group by week: "Next week (3 tasks)"

**Behavior:**
- Click a day header to collapse/expand
- Creating a task here assigns it the due date of the focused day section
- Drag a task between day sections to reschedule (future enhancement)

**Excluded lists:** Respected.

---

### Missed View

**Purpose:** Accountability. What slipped and needs rescheduling or completion.

**Content:**
- Only overdue tasks (due date < today)
- Sorted by how overdue: oldest first (longest-neglected at top)
- Shows "X days overdue" badge prominently

**Behavior:**
- Bulk action: "Reschedule all to today" button at top
- Individual: `t`/`w`/`m` to reschedule, Space to complete
- When empty: "Nothing overdue 🎉" — celebration state

**Excluded lists:** Respected.

---

### Unscheduled View

**Purpose:** Inbox triage. Tasks that exist but have no commitment.

**Content:**
- All tasks with `due = null`, grouped by list
- Each list section collapsible

**Behavior:**
- This is the "assign a date" workflow
- `t`/`w`/`m` assigns a date and the task disappears from this view
- Bulk action: "Schedule all for today" (aggressive) or "Schedule all for next week" (gentle)
- When empty: "Everything is scheduled ✓"

**Excluded lists:** Respected — excluded list tasks don't appear here either.

---

## List Exclusion Design

### Configuration

**Where:** Right-click a list in the sidebar → "Exclude from smart views"

**Visual indicator:** Excluded lists show with a muted style (50% opacity, italic name) in the sidebar.

**Storage:** Preference stored locally in the SQLite database (new `preferences` table) or localStorage. Not synced to Google (Google Tasks has no concept of this).

**Scope:** Exclusion only affects smart views (Focus, Upcoming, Missed, Unscheduled). The list itself is still fully accessible when selected directly.

### User Flow

1. User has a "Someday/Maybe" list with 50 tasks, none with due dates
2. Every time they open Unscheduled view, these 50 tasks dominate
3. User right-clicks "Someday/Maybe" → "Exclude from smart views"
4. List name becomes italic/dimmed in sidebar
5. Those 50 tasks no longer appear in any smart view
6. User can still click the list directly to see/manage those tasks

### Undo

- Right-click excluded list → "Include in smart views" (toggle)
- No confirmation needed — it's instantly reversible

---

## User Preferences Model

```
preferences (stored in localStorage):
  - excludedLists: string[]        // list IDs excluded from smart views
  - defaultView: string            // "focus" | "upcoming" | "missed" | "unscheduled" | list_id
  - showCompleted: boolean         // global toggle
  - collapsedSections: string[]    // collapsed day/list sections in views
```

No new backend commands needed — this is purely frontend state.

---

## Interaction Summary

| Action | Focus | Upcoming | Missed | Unscheduled | List |
|---|---|---|---|---|---|
| Space (complete) | ✓ removes | ✓ removes | ✓ removes | ✓ removes | ✓ stays (if show completed) |
| t (tomorrow) | stays/moves | moves to tomorrow section | removes | removes | stays |
| w (next week) | removes | moves/stays | removes | removes | stays |
| d (delete) | removes | removes | removes | removes | removes |
| Enter (create) | creates due=today | creates due=focused day | creates due=today | creates no date | creates in list |

---

## Test Plan

### Smart View Filtering
- [ ] Focus shows overdue + today + this week only
- [ ] Focus excludes tasks from excluded lists
- [ ] Upcoming shows next 14 days grouped by day
- [ ] Upcoming excludes tasks from excluded lists
- [ ] Missed shows only overdue, sorted oldest-first
- [ ] Unscheduled shows only tasks with no due date
- [ ] Completing a task removes it from smart views immediately
- [ ] Date-move keys update the view correctly (task appears/disappears)

### List Exclusion
- [ ] Excluding a list removes its tasks from all smart views
- [ ] Excluded list is still accessible when clicked directly
- [ ] Excluded list shows dimmed in sidebar
- [ ] Including a list again restores its tasks in smart views
- [ ] Exclusion persists across app restarts (localStorage)

### Task Creation Context
- [ ] Creating from Focus sets due=today
- [ ] Creating from Upcoming sets due=focused day section
- [ ] Creating from Unscheduled sets no due date
- [ ] Creating from a list view creates in that list
- [ ] New task is always immediately visible after creation

### Edge Cases
- [ ] Task with due date in excluded list: not in Focus, visible in list view
- [ ] Task moved to excluded list: disappears from smart views
- [ ] All tasks completed in Focus: shows empty state
- [ ] No lists exist: smart views show "Create a list to get started"

---

## Development Plan

| # | Task | Effort |
|---|---|---|
| 1 | Add `excludedLists` to localStorage preferences | S |
| 2 | Sidebar: right-click context menu on lists (exclude/include toggle) | M |
| 3 | Sidebar: replace "Today" with Focus/Upcoming/Missed/Unscheduled | S |
| 4 | Focus view: filter logic (overdue + today + this week, minus excluded) | M |
| 5 | Upcoming view: group by day, 14-day window | M |
| 6 | Missed view: overdue only, oldest-first | S |
| 7 | Unscheduled view: no-date tasks grouped by list | S |
| 8 | Task creation: context-aware due date assignment | S |
| 9 | Write tests for all filtering/exclusion logic | M |
| 10 | Visual polish: empty states, section headers, dimmed excluded lists | S |

Total estimate: ~3 hours of implementation.
