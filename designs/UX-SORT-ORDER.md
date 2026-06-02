# Manual Order & Custom Sort — UX Design

## Research: How Users Organize Tasks

### Mental Models

Users arrange tasks for three reasons:
1. **Priority** — most important at top (manual drag or explicit priority)
2. **Sequence** — tasks that must happen in order (step 1, step 2, step 3)
3. **Grouping** — related tasks near each other (all "calls" together)

Google Tasks uses a **manual position** field — a lex-sortable string that preserves user-defined order. This is the source of truth for "My order."

### The Problem

Most task apps offer sort options that **destroy** manual order. Once you sort by date, your careful arrangement is gone. Users need:
- A way to manually arrange (drag or keyboard)
- Sort options that are **temporary views** (not destructive)
- Clear indication of which mode they're in

---

## Use Cases

### UC-1: Manual Reorder (Primary)

**Scenario:** User wants "Call dentist" above "Buy groceries" because it's more urgent.

**Interactions:**
- **Mouse:** Drag task by a grip handle (⠿) on the left edge. Drop between other tasks. Visual drop indicator (blue line).
- **Keyboard:** Alt+↑ / Alt+↓ swaps position with adjacent sibling.
- **Touch:** Long-press to pick up, drag to new position, release to drop.

**Constraints:**
- Reorder only among siblings (same parent level)
- Cannot drag a subtask to become a root task (use outdent for that)
- Position persists to Google Tasks via the `move` API

**Visual:**
```
⠿ ☐ Call dentist          ← drag handle visible on hover/touch
⠿ ☐ Buy groceries
⠿ ☐ Send invoice
```

---

### UC-2: Temporary Sort (Non-Destructive)

**Scenario:** User wants to see tasks sorted by due date to plan their week, but doesn't want to lose their manual arrangement.

**UI:**
- Toolbar dropdown: "Sort: My order ▾"
- Options:
  - **My order** (default) — manual position from Google Tasks
  - **Due date** — earliest first, no-date at bottom
  - **Alphabetical** — A-Z by title
  - **Created** — newest first
  - **Completed last** — open tasks first, completed at bottom

**Behavior:**
- Selecting a sort mode is a **view filter** — it does NOT change the stored position
- When a non-default sort is active:
  - Drag-to-reorder is disabled (greyed out handles)
  - Alt+↑/↓ is disabled
  - A subtle indicator shows: "Sorted by due date · [Reset to my order]"
- Clicking "Reset to my order" returns to manual position

**Visual:**
```
┌─────────────────────────────────────────────────┐
│ Sort: Due date ▾    ⚠ Manual reorder disabled   │
└─────────────────────────────────────────────────┘
```

---

### UC-3: Sort Within Smart Views

**Scenario:** In Focus view, user wants overdue tasks sorted by date (oldest first) vs. by manual order.

**Behavior:**
- Smart views have their own default sort:
  - **Focus:** Manual order within each section (Overdue / Today / This Week)
  - **Upcoming:** Chronological (by due date) — always
  - **Missed:** Oldest first — always
  - **Unscheduled:** Manual order, grouped by list
- User can override with the sort dropdown
- Sort preference is per-view (stored in localStorage)

---

### UC-4: Pin to Top

**Scenario:** One task is critical — user wants it always at the top regardless of sort.

**Interaction:**
- Right-click → "Pin to top" or keyboard shortcut `!`
- Pinned tasks show a 📌 indicator and stay above all others
- Multiple pinned tasks maintain their relative manual order

**Implementation:**
- Pinned = position set to "00000000000000" (sorts before everything)
- Unpin restores previous position

---

## Sort Dropdown Component

```
┌─────────────────────────┐
│  Sort by                │
│  ─────────────────────  │
│  ● My order            │  ← default, enables drag
│  ○ Due date            │
│  ○ Alphabetical        │
│  ○ Recently created    │
│  ─────────────────────  │
│  ☑ Completed at bottom │  ← independent toggle
└─────────────────────────┘
```

---

## Drag-and-Drop Design

### Visual Feedback

1. **Idle:** Grip handle (⠿) appears on hover (desktop) or always visible (touch)
2. **Dragging:** Task lifts with shadow, original position shows a placeholder line
3. **Over target:** Blue insertion line between tasks shows where it will land
4. **Drop:** Task animates to new position, placeholder disappears

### Touch Behavior

- Long-press (300ms) initiates drag
- Haptic feedback on pickup (if available)
- Scroll zones at top/bottom of list for long lists
- Cancel by dragging back to original position

### Keyboard Behavior

- Alt+↑: swap with previous sibling
- Alt+↓: swap with next sibling
- Alt+Shift+↑: move to top of siblings
- Alt+Shift+↓: move to bottom of siblings

---

## Data Model

The `position` field from Google Tasks is a lex-sortable string. When reordering:
- Moving between tasks A (pos "00001") and B (pos "00002"): new pos = "000015" (midpoint)
- If no space between positions: re-index all siblings with evenly spaced values

Sort mode is purely client-side — it only affects display order, never modifies `position`.

---

## Preferences

```
localStorage:
  axiotask:sort:{viewId} = "manual" | "due" | "alpha" | "created"
  axiotask:completedBottom = true | false
```

---

## Test Plan

### Manual Reorder
- [ ] Alt+↓ swaps task with next sibling
- [ ] Alt+↑ swaps task with previous sibling
- [ ] Alt+↓ on last task is a no-op
- [ ] Alt+↑ on first task is a no-op
- [ ] Reorder calls backend `reorder_task` command
- [ ] Reorder is disabled when sort mode is not "manual"

### Sort Modes
- [ ] Default sort is "My order" (position field)
- [ ] "Due date" sort shows earliest-due first, no-date last
- [ ] "Alphabetical" sort shows A-Z
- [ ] Sort mode persists per view in localStorage
- [ ] Switching sort mode does not modify task positions
- [ ] "Completed at bottom" moves completed tasks below open ones

### Smart View Sort
- [ ] Upcoming view always sorts by due date
- [ ] Missed view always sorts oldest-first
- [ ] Focus view uses manual order within sections

### Drag and Drop (future)
- [ ] Drag handle visible on hover
- [ ] Dragging shows insertion indicator
- [ ] Drop updates position
- [ ] Drag disabled when sort is not "manual"

---

## Development Plan

| # | Task | Effort |
|---|---|---|
| 1 | Sort dropdown component (UI + localStorage persistence) | S |
| 2 | Sort logic: apply sort mode to visibleTasks() | M |
| 3 | "Completed at bottom" toggle (independent of sort) | S |
| 4 | Disable reorder when sort ≠ manual (visual + keyboard) | S |
| 5 | Alt+Shift+↑/↓ for move-to-top/bottom | S |
| 6 | Per-view sort preference storage | S |
| 7 | Drag handle (visual only, prep for drag-and-drop) | S |
| 8 | Tests for all sort modes and reorder constraints | M |

Drag-and-drop implementation deferred to post-MVP (requires pointer event handling, scroll zones, animation).
