# Rich Task Widget & Context Menu — UX Design

## Task Widget Design

The task row evolves from a single-line item into a **rich card** that reveals detail on focus/hover without requiring a separate panel.

### Layout (Multi-line)

```
┌─────────────────────────────────────────────────────────────────────┐
│ ☐  Buy groceries for the party                    →t →w →m    [Work]│
│    ├ 2/5 subtasks done ████░░░░░░  │  📝 notes  │  🔗 link  │ today│
└─────────────────────────────────────────────────────────────────────┘
```

**Collapsed (default):** Single line — checkbox, title, action chips, list tag
**Expanded (on focus/click):** Second line appears with metadata row

### Second Line (Metadata Row)

Shows only what's relevant (no empty placeholders):

| Element | When shown | Content |
|---|---|---|
| Subtask progress | Task has children | "2/5 ████░░░░" — count + mini progress bar |
| Notes indicator | Task has notes | "📝 notes" — clickable, opens notes panel |
| Link badge | Title or notes contain a URL | "🔗" — clickable, opens URL in browser |
| Due date | Always | Relative date with color coding |
| List tag | In smart views | Pill with list name |

### Subtask Progress Bar

```
├ 2/5 ████████░░░░░░░░░░
```

- Shows `completed / total` count
- Mini horizontal bar (CSS only, no canvas)
- Green fill for progress
- Clicking the card (including the badge) opens the detail panel, where the
  subtasks live — subtasks are never rows in the list itself (#82, one level only)
- Only visible on parent tasks

### Quick Access Links

- Scans `task.title` and `task.notes` for URLs (regex: `https?://[^\s]+`)
- Shows 🔗 badge with count if multiple
- Click opens first URL in system browser
- Hover shows tooltip with the URL domain
- Multiple links: click shows a small dropdown

### Quick Actions (visible on hover/focus)

```
[→t] [→w] [→m] [✕] [📝] [↗] [⋮]
```

| Button | Action | Tooltip |
|---|---|---|
| →t | Set due tomorrow | "Tomorrow" |
| →w | Set due next week | "Next week" |
| →m | Set due next month | "Next month" |
| ✕ | Clear due date | "Remove date" |
| 📝 | Open notes panel | "Notes" |
| ↗ | Move to list (opens picker) | "Move to..." |
| ⋮ | Open context menu | "More..." |

---

## Context Menu Design

Right-click on a task shows a custom context menu (replaces browser default):

```
┌──────────────────────────┐
│  ✏️  Edit title           │
│  📝  Edit notes           │
│  ─────────────────────── │
│  📅  Set due date    ▸   │
│      → Today             │
│      → Tomorrow          │
│      → Next week         │
│      → Next month        │
│      → Pick date...      │
│      → Clear             │
│  ─────────────────────── │
│  ↗️  Move to list    ▸   │
│      → Work              │
│      → Personal          │
│      → Shopping          │
│  ─────────────────────── │
│  ⬆️  Add subtask         │
│  📋  Duplicate           │
│  🔗  Copy link           │
│  ─────────────────────── │
│  🗑️  Delete              │
└──────────────────────────┘
```

**Behavior:**
- Appears at cursor position
- Dismisses on click outside, Escape, or selecting an item
- Submenus expand on hover (no click needed)
- Keyboard navigable: arrow keys + Enter

### Context Menu on Lists (sidebar)

```
┌──────────────────────────┐
│  ✏️  Rename               │
│  🚫  Exclude from views  │  ← toggle
│  🗑️  Delete list          │
└──────────────────────────┘
```

---

## Ctrl+V — Paste to Create

**Behavior:**
- When focus is NOT in an input/textarea
- Ctrl+V reads clipboard text
- Creates a new task with clipboard content as title
- If clipboard contains a URL, title = URL (user can rename)
- If clipboard is multi-line, creates one task per line (bulk create)
- Toast: "Created N tasks from clipboard"

**Edge cases:**
- Empty clipboard: no-op
- Very long text (>500 chars): truncate title, put full text in notes
- HTML clipboard: strip tags, use plain text

---

## QOL Features Summary

| Feature | Trigger | Behavior |
|---|---|---|
| Ctrl+V paste-create | Ctrl+V (not in input) | Create task(s) from clipboard |
| Ctrl+D duplicate | Ctrl+D on focused task | Clone task with "(copy)" suffix |
| Ctrl+Z undo | Ctrl+Z after delete | Restore last deleted task |
| Ctrl+/ search | Ctrl+/ or / | Focus search/quick-add |
| Ctrl+N new task | Ctrl+N | Focus quick-add input |
| Ctrl+L new list | Ctrl+L | Create new list prompt |

---

## Development Plan

| # | Task | Effort |
|---|---|---|
| 1 | Custom context menu component (position, dismiss, keyboard nav) | M |
| 2 | Context menu items: edit, notes, due date submenu, move submenu, delete | M |
| 3 | Rich task widget: second metadata line on focus | S |
| 4 | Subtask progress bar (count + CSS bar) | S |
| 5 | URL detection in title/notes, link badge | S |
| 6 | Ctrl+V paste-to-create | S |
| 7 | Context menu on sidebar lists (rename, exclude, delete) | S |
| 8 | Ctrl+D duplicate task | S |
| 9 | Tests for all new interactions | M |

---

## Test Plan

- [ ] Right-click task shows context menu at cursor position
- [ ] Context menu: "Edit title" enters edit mode
- [ ] Context menu: "Set due date → Tomorrow" calls setDue
- [ ] Context menu: "Move to → Work" calls moveToList
- [ ] Context menu: "Delete" deletes with undo
- [ ] Context menu dismisses on Escape / click outside
- [ ] Ctrl+V with text creates a task
- [ ] Ctrl+V with multi-line creates multiple tasks
- [ ] Ctrl+V with URL creates task with URL as title
- [ ] Subtask progress shows correct count
- [ ] URL in title shows link badge
- [ ] Link badge click opens URL
- [ ] Right-click list shows list context menu
- [ ] "Exclude from views" toggles exclusion
