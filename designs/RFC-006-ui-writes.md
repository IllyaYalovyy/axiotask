# RFC-006: UI — Writes (Create / Edit / Complete / Delete)

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Turn the read-only viewer from [[RFC-005-ui-read-only]] into a real task
manager: create tasks, edit titles inline, toggle completion, edit notes,
delete (with undo). All writes are optimistic — they hit the local store
immediately and the sync engine reconciles asynchronously.

---

## Goals

- **G1** — Every CRUD action returns to the user in <50ms (optimistic update from local store).
- **G2** — Every action works offline; reconnect replays all of it.
- **G3** — Errors during background sync surface to the user without losing data — failed-sync state visible per row.
- **G4** — Single-step undo for `delete` (within 30s window).

## Non-Goals

- **NG1** — Reorder / indent / outdent — that's part of [[RFC-007-keyboard-navigation]].
- **NG2** — Drag-and-drop with the mouse (post-MVP).
- **NG3** — Multi-select bulk operations (post-MVP).

---

## Background & Motivation

A read-only client of someone else's API is not an MVP. Writes are where
"local-first" earns its keep: typing a new task while on a train must feel
identical to typing one online.

---

## Considered Options

### Option A — Optimistic + reconcile (the proposal)

Local store is the source of truth for the UI; sync engine catches up later.

**Pros**: Instant UX. Plays well with VISION's offline-first stance.
**Cons**: Must visibly reflect sync failures so the user knows when something didn't reach Google.

### Option B — Pessimistic (block on network)

Don't update UI until Google confirms.

**Pros**: No "drift" between UI and server.
**Cons**: Violates VISION offline goal. Awful UX on slow network.

---

## Decision

**Option A.**

---

## Design

### Tauri commands

```rust
#[tauri::command] async fn create_task(list_id: String, parent_id: Option<String>, title: String) -> Result<TaskView>;
#[tauri::command] async fn rename_task(id: String, title: String) -> Result<()>;
#[tauri::command] async fn set_notes(id: String, notes: String) -> Result<()>;
#[tauri::command] async fn toggle_complete(id: String) -> Result<()>;
#[tauri::command] async fn delete_task(id: String) -> Result<DeleteToken>;
#[tauri::command] async fn undo_delete(token: DeleteToken) -> Result<()>;
```

Each command:

1. Generates a local UUID for new rows.
2. Writes to SQLite, marks row `sync_state='dirty'` with appropriate `pending_op`.
3. Emits `tasks_changed { list_id }` so other UI views refresh.
4. Schedules a debounced sync run.

### Per-row sync indicator

Each `TaskView` carries a `sync` field: `clean | pending | error`. UI shows
a dot color or icon. Hovering an `error` row reveals the message and a
"retry" affordance.

### Undo

`delete_task` returns a `DeleteToken` (the row's prior state); UI keeps it
for 30s and exposes "Undo" in a toast. `undo_delete` re-inserts the row
(with the same id; `sync_state` reset to `dirty(create)` if the original
delete had already been pushed).

### Notes editor

Click (or `e`) opens a side panel; saves on blur with debounce. Plain text
only for MVP.

---

## Testing Strategy

- **Command-level**: each Tauri command unit-tested with `:memory:` store + `MockClient` — assert local row state + emitted events.
- **Optimistic round-trip**: create task → drain dirty → assert id remap → assert UI view reflects remote id.
- **Failure path**: `MockClient` set to fail next push → assert row stays `dirty`, UI shows `error`, retry succeeds.
- **Undo**: delete + undo → row restored byte-for-byte (proptest fixture).
- **Component tests**: inline editor save on Enter / discard on Esc, notes panel debounce.

---

## Development Plan

- [ ] **Step 1** — `create_task` command + tests *(prerequisite: RFC-005 Step 3)*
- [ ] **Step 2** — Inline title edit (Svelte) + `rename_task` command + tests *(prerequisite: Step 1)*
- [ ] **Step 3** — Checkbox + `toggle_complete` + tests *(prerequisite: Step 1)*
- [ ] **Step 4** — Notes side panel + `set_notes` command + tests *(prerequisite: Step 1)*
- [ ] **Step 5** — `delete_task` + 30s undo with toast + tests *(prerequisite: Step 1)*
- [ ] **Step 6** — Per-row sync indicator + retry affordance *(prerequisite: RFC-004 Step 7)*

---

## Open Questions

- [ ] **Q1** — Undo only for delete, or also for "completed by accident" within N seconds?
- [ ] **Q2** — Notes max length / formatting: plain text MVP, markdown later?
- [ ] **Q3** — Where do we draw the visual line for "completed task" — strikethrough only, or move to a fold-out "Completed" section per list?
