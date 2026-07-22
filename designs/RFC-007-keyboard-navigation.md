# RFC-007: Keyboard Navigation & Command Palette

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Make the app fully drivable from the keyboard, per VISION §2 ("Every action
is reachable without a mouse"). Define a keymap, the focus state machine
that backs it, and a Ctrl-K command palette as the discoverability surface
for everything that doesn't earn a one-key binding.

---

## Goals

- **G1** — Navigate, create, complete, edit, delete, reorder — all from the keyboard. (Subtask create/detach is a detail-panel action, not a list gesture.)
- **G2** — Bindings are testable as pure functions of focus state + key event.
- **G3** — Command palette (`Ctrl-K`) exposes every command with fuzzy search.
- **G4** — A discoverable "?" shortcut shows the cheatsheet.

## Non-Goals

- **NG1** — User-customizable keybindings (post-MVP; we ship a sensible default).
- **NG2** — Vim modes (post-MVP).
- **NG3** — Touch/gesture support.

---

## Background & Motivation

The frontends Google Tasks already has are mouse-first. The whole reason
axiotask exists is to be keyboard-first. Done well, this is the feature
power users will adopt the app for.

---

## Considered Options

### Option A — Custom focus state machine in Svelte + pure keymap functions

**Pros**: Testable, total control, no library lock-in.
**Cons**: We own focus-restore on modal close, scroll-into-view, etc.

### Option B — `@floating-ui/dom` + `tinykeys`

**Pros**: Off-the-shelf keymap.
**Cons**: Library still leaves focus-state to us; the easy part isn't the hard part.

---

## Decision

**Option A.**

---

## Design

### Focus state

```ts
type Focus =
  | { kind: "list_pane",  list_id?: string }
  | { kind: "tree",       task_id: string }
  | { kind: "editor",     task_id: string, field: "title" | "notes" }
  | { kind: "palette" }
  | { kind: "modal",      id: string };
```

Transitions are an exhaustive `match` — easy to unit-test.

### Default keymap (tree focus)

| Key | Action |
|---|---|
| `j` / `↓` | next task |
| `k` / `↑` | previous task |
| `Enter` | open / close the detail panel |
| `s` | add a subtask (opens it in the detail panel) |
| `Space` | toggle complete |
| `Alt-↑` / `Alt-↓` | reorder among siblings |
| `e` | edit title inline |
| `n` | open notes panel |
| `d` (then `d`) | delete (double-tap to confirm) |
| `t` / `w` / `m` / `r` | set due tomorrow / next week / next month / remove (see [[RFC-008-keystroke-date-moves]]) |
| `/` | focus search (in-list filter) |
| `Ctrl-K` | command palette |
| `?` | cheatsheet |
| `Esc` | exit current focus to next-outer |

### Reorder / detach semantics

These map to Google's `tasks.move` endpoint. The list is flat and top-level
only, with no tree-editing gestures: there is no `Tab` indent and no
`Shift+Tab` outdent. Subtasks are created and detached ("Detach from parent")
solely from the detail panel, because subtasks are never rows in the list or
smart views (they live only in the detail panel). Reorder (`Alt-↑/↓`) moves
among siblings.

### Command palette

Fuzzy-search over a static command registry — the same registry that powers
the cheatsheet generator, so they can never diverge.

---

## Testing Strategy

- **Pure keymap function tests** — given `(Focus, KeyEvent)` produce expected `Action`. Exhaustive table.
- **Focus state machine tests** — Esc unwinds correctly from every depth.
- **Integration** (Playwright): scripted sequence "create → complete → reorder → delete" via keyboard only; assert final order.
- **Acceptance** — VISION criterion: "create, complete, and reorganize tasks entirely from the keyboard."

---

## Development Plan

- [ ] **Step 1** — Focus state + transitions + tests *(prerequisite: RFC-006 Step 1)*
- [ ] **Step 2** — Command registry + dispatcher *(prerequisite: Step 1)*
- [ ] **Step 3** — Tree navigation keys (j/k/h/l/arrows) + tests *(prerequisite: Step 2)*
- [ ] **Step 4** — Mutation keys (Enter, Space, e, d) hooked to RFC-006 commands *(prerequisite: Step 3)*
- [ ] **Step 5** — Reorder via `tasks.move` *(prerequisite: Step 4)*
- [ ] **Step 6** — Command palette UI *(prerequisite: Step 2)*
- [ ] **Step 7** — Cheatsheet overlay + `?` binding *(prerequisite: Step 2)*

---

## Open Questions

- [ ] **Q1** — How do we surface keybindings on macOS where convention favors `Cmd`? Probably auto-swap `Ctrl`→`Cmd`.
- [ ] **Q2** — Should the in-list `/` search filter, or open a global search? MVP: filter the active list.
- [ ] **Q3** — `d` deletes immediately vs requires `dd` — power-user fast vs safer. Lean toward `dd` for MVP since undo exists.
