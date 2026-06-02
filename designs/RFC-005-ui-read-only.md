# RFC-005: UI — Read-Only Tree

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

First user-visible milestone: open the app and **see** all task lists and
their tasks as a clear, hierarchical tree. No editing yet — this RFC proves
the data path from SQLite → Tauri IPC → Svelte renders correctly and meets
the "<2s to first paint" success criterion from VISION.

---

## Goals

- **G1** — On launch, lists appear in the sidebar within 2s (cold-cache OK; warm-cache much faster).
- **G2** — Selecting a list renders its full task tree, with subtasks visibly nested under parents.
- **G3** — Collapse / expand subtree state persists across launches.
- **G4** — A `tasks_changed` Tauri event pushes diffs from the backend so the UI updates live when sync pulls remote changes.

## Non-Goals

- **NG1** — Any form of mutation. CRUD is [[RFC-006-ui-writes]].
- **NG2** — Keyboard navigation. That is [[RFC-007-keyboard-navigation]].
- **NG3** — Multi-list combined views.

---

## Background & Motivation

VISION §3: "Hierarchy is visible — Subtasks are never separated from parent.
No visual orphans." Google's own UIs fail this; we must not.

Also VISION success criterion: launch and see all tasks in under 2s. That
implies first paint reads from the local store, not the API.

---

## Considered Options

### Option A — Flat virtual list with indent indicator

Render all tasks of a list as a flat list; indent visually by `depth`.

**Pros**: Trivial virtualization (lots of tasks per list).
**Cons**: Loses the visceral sense of structure for deep trees.

### Option B — Native nested DOM tree

Real nested `<ul>`/`<li>` (or Svelte recursive component).

**Pros**: Structure is structural, not cosmetic; CSS for collapse is trivial.
**Cons**: Slow if a list has thousands of tasks (Google caps subtasks but parent count can be high).

### Option C — Hybrid: nested DOM with virtualization on the top-level siblings

**Pros**: Performance + structure.
**Cons**: More code.

---

## Decision

**Start with Option B**, measure with a fixture of 1,000 tasks; move to
Option C only if perf demands it. Google Tasks API limits a list to ~10k
tasks, but typical lists are under 200.

---

## Design

### Tauri commands

```rust
#[tauri::command] async fn list_tasklists(state: ...) -> Result<Vec<TaskListView>>;
#[tauri::command] async fn list_tasks(state: ..., list_id: String) -> Result<Vec<TaskView>>;
```

`TaskListView` / `TaskView` are pure DTOs — separate from the core domain
types so the IPC contract is explicit. Conversions live in
`axiotask-app::view`.

### Tauri events

```text
tasks_changed { list_id }      — emitted whenever sync writes to the store
sync_status   { state, error } — for the status indicator
```

The Svelte side subscribes once on mount and refetches the affected list on
event.

### Persistence of UI state

Collapse state stored in `localStorage` (per list_id, per parent task id) —
acceptable because it's purely cosmetic; loss is no big deal.

### Layout

```
┌─────────────┬─────────────────────────────────────────────┐
│  Lists      │  Selected list                              │
│  ● Inbox    │  ▾ Buy groceries        [ ] due tomorrow    │
│    Work     │       Milk              [ ]                 │
│    Errands  │       Eggs              [x]                 │
│             │  ▸ Plan trip                                │
│             │    Renew passport       [ ]                 │
└─────────────┴─────────────────────────────────────────────┘
```

---

## Testing Strategy

- **Backend command tests** — wire `MockClient` + `:memory:` store; assert IPC commands return correct shapes.
- **Svelte component tests** (Vitest + Testing Library) — recursive tree component renders correct nesting; collapse toggles class.
- **Snapshot tests** — render a fixture list, snapshot the DOM tree; catches regressions in structure.
- **E2E** (Playwright driving Tauri) — launch app with a seeded SQLite file → assert "Buy groceries → Milk" is visible.
- **Performance** — render-1000-tasks benchmark in CI; budget 100ms to first paint after data arrives.

---

## Development Plan

- [ ] **Step 1** — Svelte 5 frontend skeleton (router-free; two-pane layout) *(prerequisite: RFC-001 Step 1)*
- [ ] **Step 2** — `TaskListView`/`TaskView` DTOs + conversions *(prerequisite: RFC-003)*
- [ ] **Step 3** — `list_tasklists` + `list_tasks` Tauri commands + tests *(prerequisite: Step 2)*
- [ ] **Step 4** — Recursive `<TaskNode>` Svelte component + Vitest tests *(prerequisite: Step 3)*
- [ ] **Step 5** — Sidebar list selector *(prerequisite: Step 4)*
- [ ] **Step 6** — `tasks_changed` event subscription *(prerequisite: RFC-004 Step 7)*
- [ ] **Step 7** — Collapse state persistence *(prerequisite: Step 4)*
- [ ] **Step 8** — Performance benchmark (1k tasks) *(prerequisite: Step 4)*

---

## Open Questions

- [ ] **Q1** — Empty-state UI for "no lists yet" and "list is empty" — copy + visual?
- [ ] **Q2** — Show completed tasks inline grayed-out, or hidden behind a toggle? Default behavior?
- [ ] **Q3** — Sidebar order: alphabetical, Google's order, or user-customized? MVP: Google's order.
