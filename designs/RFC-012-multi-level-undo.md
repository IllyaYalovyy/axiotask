# RFC-012: Multi-level undo

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Today every reversible action offers an Undo for the lifetime of one toast (30 s, one action at a time). This RFC proposes a session-scoped undo history: the last N mutations can be undone in order (and redone), from an app-bar action on the phone and Ctrl+Z / Ctrl+Shift+Z on the desktop, independent of the toast. It matters because a wrong bulk action, a mis-swipe, or a fat-finger delete is discovered later than 30 seconds more often than not, and today that means manual repair.

---

## Goals

- **G1** — Undo the last N (default 20) local mutations in reverse order within the running session; redo what was undone.
- **G2** — One vocabulary: the toast's Undo and the history are the SAME stack — a toast Undo pops the same entry the history would.
- **G3** — Every mutation that already has an inverse (`toggleComplete`/`undoToggleComplete`, `setDue`/`undoSetDue`, `deleteTask`/`undoDelete`, `moveTaskToList`/`undoMoveToList`, bulk variants) joins without new store primitives; rename/notes/reorder/create gain inverses.
- **G4** — Undo stays correct across a sync: an entry whose target was changed remotely since is skipped with a one-line notice, never applied blindly.

## Non-Goals

- **NG1** — Persistence across restarts (a session stack only; the store's own history is not a journal).
- **NG2** — Undoing sync outcomes (a pull is not a user action).
- **NG3** — Undoing list deletion (cascades; stays confirm-dialog protected — a later RFC if ever).

---

## Background & Motivation

`Commands` returns undo tokens (`CompleteToken`, `DeleteToken`, `MoveToListToken`, `List<DueUndoEntry>`) that the UI hands to `ToastController.showUndo`. The token dies with the toast. Bulk operations collect tokens into one toast (#205). There is no redo, no history, and no keyboard path. #271 (Commands refactor) is landing transactional multi-row writes, which is the moment to give every mutation a typed inverse.

---

## Considered Options

### Option A — Command pattern: every mutation returns an `UndoEntry` (label, `undo()`, `redo()`), pushed on an `UndoHistory` notifier owned by the app layer

**Pros**: reuses the existing tokens; the toast becomes a view over the stack's head; bulk = one composite entry; testable without widgets.
**Cons**: rename/notes/reorder/create need inverses written (create → delete-with-tombstone; rename → previous title; reorder → previous `previousId`).

### Option B — Store-level journal (before-images per write, replayed backwards)

**Pros**: nothing per command; covers everything automatically.
**Cons**: interacts badly with sync (before-images go stale as pulls land), duplicates the sync engine's base-snapshot machinery, large blast radius in `store.dart`.

### Option C — Keep per-toast undo, only extend the toast lifetime

**Pros**: trivial.
**Cons**: does not solve "noticed a minute later", still one action deep.

---

## Decision

**Chosen option: — (Draft; the user decides)**
Recommendation: Option A. It is the smallest change that gives depth and redo, it composes with #271's split (each unit returns its own entries), and G4 is enforceable per entry (each entry records the `local_updated` it expects; a mismatch = skipped).

---

## Design

- `UndoEntry { String label; DateTime at; Future<UndoResult> undo(); Future<void> redo(); Set<String> taskIds; }` in `lib/src/app/undo_history.dart`; `UndoHistory extends ChangeNotifier` with `push`, `undo()`, `redo()`, `canUndo/canRedo`, capacity 20, cleared on account reset (#215).
- `Commands` (post-#271) returns `UndoEntry` from every mutation; bulk paths wrap N entries in one `CompositeUndoEntry` (label "3 tasks deleted").
- Stale guard (G4): an entry stores each target row's `local_updated` at push time; `undo()` re-reads and skips rows whose `local_updated` or `remote_id` changed since (returns `UndoResult.partial(skipped: [...])`), and the UI says "2 of 3 restored — 1 changed since".
- Surfaces: the existing Undo toast calls `history.undo()` for its own entry only if it is still the head; phone app-bar ⋮ gains "Undo <label>" / "Redo"; desktop Ctrl+Z / Ctrl+Shift+Z via `Shortcuts` at the shell (the first app-level shortcuts — keep them to these two).
- Sync trigger: an undo is a mutation and notifies the scheduler like any other (#209).

---

## Testing Strategy

- Unit: `UndoHistory` push/undo/redo/capacity; composite entries; stale-guard skip with a store fake whose row changed.
- Commands tests: each mutation's entry round-trips state exactly (before == after undo), red-checked by stubbing `undo()`.
- Widget: toast Undo pops the head; app-bar Undo label; Ctrl+Z on desktop.
- Property suite: random mutation sequences + full undo restore the initial store byte-for-byte (excluding `local_updated`).
- Cannot test: user perception of "how far back is enough" — start at 20.

---

## Development Plan

- [ ] **Step 1** — `UndoHistory` + `UndoEntry`, toast wired as a view over the head *(prerequisite: #271 merged)*
- [ ] **Step 2** — inverses for rename / notes / reorder / create; composite bulk entries *(prerequisite: Step 1)*
- [ ] **Step 3** — stale guard + partial result UI *(prerequisite: Step 2)*
- [ ] **Step 4** — phone app-bar Undo/Redo, desktop Ctrl+Z / Ctrl+Shift+Z *(prerequisite: Step 1)*

---

## Open Questions

- [ ] **Q1** — Depth: 20 entries, or time-bound (this session, unbounded)?
- [ ] **Q2** — Should redo exist at all in v1, or only undo (halves the inverse surface)?
- [ ] **Q3** — Does an undo of a create that already synced delete the remote task (tombstone) or only hide it locally? (Recommendation: tombstone — it is what "undo" means.)
