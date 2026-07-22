# axiotask — MVP UX Design & Development Plan

## Philosophy

Google Tasks is a powerful backend crippled by a lazy frontend. The official app treats tasks as a flat checklist buried in a sidebar. axiotask treats tasks as **the primary workspace** — a command center for your day.

**Design principles:**
1. **One-click for the most common action** — completing a task, deferring it to tomorrow, creating a new one
2. **Zero-click for awareness** — what's due today, what's overdue, what's next — visible at a glance without navigating
3. **Keyboard-first, mouse-friendly** — every action has a key binding, but clickable affordances exist for discoverability
4. **Context without switching** — see tasks across all lists in one view; never lose context by navigating away
5. **One level of subtasks, kept out of the way** — lists show top-level tasks only; a card's subtasks live in its detail panel, so the list never becomes clutter

---

## Google Tasks Feature Coverage (100% MVP)

| Google Tasks Feature | axiotask Coverage |
|---|---|
| Multiple task lists | ✅ Sidebar list selector + cross-list views |
| Create/edit/delete tasks | ✅ Inline creation, editing, deletion with undo |
| Task title + notes | ✅ Title inline, notes in side panel |
| Due dates | ✅ One-key date moves + date picker |
| Mark complete/incomplete | ✅ One-click/key toggle |
| Subtasks (one level) | ✅ Managed in the detail panel (add / check / date / detach) |
| Reorder tasks | ✅ Drag or Alt+Arrow |
| Move task between lists | ✅ Command palette or right-click |
| Show/hide completed | ✅ Toggle in toolbar |
| Delete completed tasks | ✅ Bulk action in toolbar |
| Star/important (via ordering) | ✅ Pin to top |

---

## Use Cases

### UC-1: Daily Overview (Home View)

**Scenario:** User opens the app in the morning. They need to see what demands attention today across ALL lists.

**UI:**
- Default view on launch: **"Today" smart view**
- Shows: all tasks due today + overdue tasks, grouped by list
- Each task shows: checkbox, title, list name (as a subtle tag), due indicator
- Overdue tasks highlighted in red at the top with "X days overdue" badge
- Section separator: "Overdue (3)" / "Due Today (5)" / "No date (assigned to today)"
- Empty state: "Nothing due today ✓" with motivational simplicity

**Interactions:**
- Click checkbox → complete (task fades out with brief animation)
- Click task title → inline edit
- Press `t` → defer to tomorrow (task disappears from today view)
- Press `w` → defer to next week
- Press `Enter` → create new task in the focused list section

---

### UC-2: Single List View

**Scenario:** User wants to focus on one project/context (e.g., "Work" list).

**UI:**
- Selected from sidebar or keyboard shortcut (1-9 for first 9 lists)
- Shows **top-level tasks only** — subtasks live in the detail panel, never as rows
- Toolbar: "+ New task" | "Show completed" toggle | Sort dropdown
- Tasks ordered by: position (manual), with completed at bottom (when shown)
- A parent card shows a subtask progress badge ("2/5"); no indent, connector, or collapse
- Opening a card (click / `Enter`) reveals its subtasks in the detail panel

**Interactions:**
- `Enter` → open / close the detail panel for the focused task
- `Alt+↑/↓` → reorder among siblings
- `Space` → toggle complete
- `e` → edit title inline
- `s` → add a subtask (opens it in the detail panel)
- `d` → delete (with undo toast)
- `t/w/m/r` → set due tomorrow/week/month/remove

---

### UC-3: Create a Task (One-Click)

**Scenario:** User has a thought and needs to capture it instantly.

**UI:**
- Persistent "quick add" input at the top of the content area (always visible, never scrolls away)
- Placeholder: "Add a task... (Enter)"
- Typing and pressing Enter creates the task in the currently selected list
- Smart parsing: "Buy milk tomorrow" → title "Buy milk", due tomorrow
- After creation: task appears in the list, input clears, ready for next

**Interactions:**
- Click the input or press `/` to focus it
- Type title → Enter → done
- Optional: `#listname` suffix to target a specific list
- Optional: natural language date at the end

---

### UC-4: Complete a Task (One-Click)

**Scenario:** User finished something.

**UI:**
- Checkbox on every task row
- Click checkbox OR press Space on focused task
- Task gets strikethrough + fades to 50% opacity
- After 2 seconds, task slides to "Completed" section (if visible) or disappears
- Undo available via Ctrl+Z or toast

---

### UC-5: Defer/Reschedule (One-Click)

**Scenario:** "Not today" — the most common triage action.

**UI:**
- Hover a task → date chip buttons appear: "→ tmrw" "→ next wk" "→ next mo" "✕ clear"
- Keyboard: `t` / `w` / `m` / `r` on focused task
- Visual feedback: due date badge updates immediately
- In Today view: task disappears (it's no longer due today)

---

### UC-6: Edit Task Details

**Scenario:** User needs to add notes, change title, or set a specific date.

**UI:**
- Click title or press `e` → title becomes editable inline
- Press `n` → notes panel slides in from the right (300px)
  - Textarea with placeholder "Add notes..."
  - Auto-saves on blur or after 1s of inactivity
  - Escape closes panel
- Due date: click the date badge → date picker popover
  - Quick options: Today, Tomorrow, Next Week, Next Month, Pick date...
  - Calendar widget for specific date selection

---

### UC-7: Organize with Subtasks

**Scenario:** User breaks a task into steps.

**UI:**
- Open a task's detail panel, then use the Subtasks section: "+" adds a subtask, the
  checklist checks them off, each subtask has its own due date, and "Detach from parent"
  promotes one back to top level
- `s` on a focused list task → adds a subtask and opens it in the detail panel
- `Tab` on a focused list task → makes it a subtask of the task above it
- A parent card shows a subtask progress badge ("2/5"); subtasks are not rows in the list

**Constraints:**
- Google Tasks supports one level of nesting only — this is permanent
- Subtasks are only ever shown in the detail panel, never as list/smart-view rows
- Tab only ever nests a top-level task under another top-level task; there is no second level

---

### UC-8: Move Task Between Lists

**Scenario:** "This belongs in my Work list, not Personal."

**UI:**
- Right-click task → context menu with "Move to..." → list picker
- Or: `Ctrl+M` → command palette filtered to lists
- Task disappears from current view, appears in target list
- Toast: "Moved to Work" with Undo

---

### UC-9: Manage Lists

**Scenario:** Create, rename, delete task lists.

**UI:**
- Sidebar shows all lists
- "+" button creates a new list (inline rename)
- Right-click list → Rename / Delete
- Delete confirmation: "Delete 'Work' and all its tasks?"
- Drag to reorder lists in sidebar

---

### UC-10: Show/Hide Completed Tasks

**Scenario:** User wants a clean view, or wants to review what they've done.

**UI:**
- Toolbar toggle: "Show completed" (eye icon)
- When shown: completed tasks appear at the bottom with strikethrough, 50% opacity
- Bulk action: "Clear completed" removes all completed tasks from the list

---

### UC-11: Search / Filter

**Scenario:** "Where did I put that task about the dentist?"

**UI:**
- `/` key or click search icon → search bar appears at top
- Searches across ALL lists, title + notes
- Results show as a flat list with list-name tags
- Selecting a result navigates to that task in its list

---

### UC-12: Cross-List View ("All Tasks")

**Scenario:** User wants to see everything in one place.

**UI:**
- Sidebar item: "All Tasks" (above individual lists)
- Shows all tasks from all lists, grouped by list
- Each group is collapsible
- Same interactions as single-list view
- Useful for bulk triage

---

### UC-13: Keyboard Cheatsheet

**Scenario:** New user learning the app.

**UI:**
- `?` key shows overlay with all bindings
- Organized by category: Navigation, Actions, Dates, Organization
- Dismisses on any key press or click outside

---

## Layout

```
┌──────────────────────────────────────────────────────────────────────┐
│  axiotask                                              [—] [□] [✕]   │
├────────────┬─────────────────────────────────────────────────────────┤
│            │  ┌─────────────────────────────────────────────────┐    │
│  ★ Today   │  │  Add a task...                          (Enter) │    │
│  ☰ All     │  └─────────────────────────────────────────────────┘    │
│            │                                                         │
│  LISTS     │  ☐ Show completed          Sort: Manual ▾              │
│  ● Inbox   │                                                         │
│  ● Work    │  ── Overdue ──────────────────────────────────────────  │
│  ● Personal│  ☐ Call dentist              2d overdue  [Personal]     │
│  ● Shopping│                                                         │
│            │  ── Due Today ────────────────────────────────────────  │
│            │  ☐ Review PR #423            today       [Work]         │
│            │  ☐ Buy groceries             today       [Shopping]     │
│  ───────── │    ☐ Milk                                               │
│  + New list│    ☐ Eggs                                               │
│            │    ☑ Bread                                              │
│            │  ☐ Send invoice              today       [Work]         │
│            │                                                         │
│ ↻ Sync now │  ── No date ─────────────────────────────────────────  │
│ ● Synced   │  ☐ Research vacation spots               [Personal]     │
│   2m ago   │                                                         │
└────────────┴─────────────────────────────────────────────────────────┘
```

---

## Development Plan

### Phase 1: Core Views (foundation)

| # | Task | Depends on |
|---|---|---|
| 1.1 | Quick-add input (always visible, creates task in selected list) | — |
| 1.2 | Today smart view (overdue + due today, grouped by list) | 1.1 |
| 1.3 | Single list view with full task tree | 1.1 |
| 1.4 | All Tasks cross-list view | 1.3 |
| 1.5 | Sidebar: Today / All / individual lists | 1.2, 1.4 |
| 1.6 | Show/hide completed toggle | 1.3 |

### Phase 2: Task Lifecycle

| # | Task | Depends on |
|---|---|---|
| 2.1 | Inline title editing (click or `e`) | 1.3 |
| 2.2 | Complete/uncomplete (click checkbox or Space) | 1.3 |
| 2.3 | Delete with 30s undo toast | 1.3 |
| 2.4 | Due date one-key moves (t/w/m/r) | 1.3 |
| 2.5 | Due date picker (click date badge) | 2.4 |
| 2.6 | Notes panel (n key, side panel) | 1.3 |
| 2.7 | Create subtask (`s` / detail panel "+") | 1.3 |
| 2.8 | Detach subtask in detail panel ("Detach from parent") | 2.7 |
| 2.9 | Reorder (Alt+↑/↓) | 1.3 |

### Phase 3: Organization

| # | Task | Depends on |
|---|---|---|
| 3.1 | Move task between lists (Ctrl+M) | 1.3 |
| 3.2 | Create/rename/delete lists | 1.5 |
| 3.3 | Clear completed tasks (bulk) | 1.6 |
| 3.4 | Search across all lists (/) | 1.4 |

### Phase 4: Polish

| # | Task | Depends on |
|---|---|---|
| 4.1 | Keyboard cheatsheet (?) | — |
| 4.2 | Hover date-move chips (mouse affordance) | 2.4 |
| 4.3 | Drag-and-drop reorder (mouse) | 2.9 |
| 4.4 | Context menu (right-click) | 3.1 |
| 4.5 | Completion animation (fade + slide) | 2.2 |
| 4.6 | Persist UI state (selected list, scroll position) | 1.5 |

### Phase 5: Sync & Reliability

| # | Task | Depends on |
|---|---|---|
| 5.1 | On-demand sync (button) | — |
| 5.2 | Auto-sync on focus (configurable) | 5.1 |
| 5.3 | Sync status indicator | 5.1 |
| 5.4 | Conflict resolution UI (toast with "keep local / keep remote") | 5.1 |
| 5.5 | Offline indicator | 5.1 |

---

## UI Requirements for Framework

The chosen UI framework must support:

1. **Reactive data binding** — task list updates reflect instantly without manual DOM manipulation
2. **Component composition** — sidebar, toolbar, task tree, notes panel, toast, modal as independent components
3. **Keyboard event handling** — global keydown listener with focus-state-aware dispatch
4. **CSS scoping** — component-level styles that don't leak
5. **Conditional rendering** — show/hide sections based on state (completed toggle, empty states, panels)
6. **List virtualization** (nice-to-have) — for lists with 500+ tasks
7. **Animation** — CSS transitions for completion fade, panel slide, toast appear/dismiss
8. **Accessibility** — ARIA roles, focus management, screen reader support
9. **Testability** — components renderable in a test environment with DOM assertions

---

## Success Metrics

The MVP succeeds when:

1. User opens app → sees today's tasks in <2 seconds
2. Creating a task takes exactly 1 action (click input + type + Enter)
3. Completing a task takes exactly 1 action (click or Space)
4. Deferring a task takes exactly 1 action (t/w/m key)
5. User can work entirely offline; sync is invisible when online
6. No task is ever lost — local-first with reliable sync
7. The app feels faster than the Google Tasks web UI in every operation
