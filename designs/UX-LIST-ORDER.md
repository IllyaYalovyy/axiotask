# List Ordering & New Item Placement — UX Design

## Problem Statement

Three issues:
1. New tasks appear at the bottom — user can't see them without scrolling
2. Subtasks have no creation/editing affordance beyond keyboard
3. Links in tasks don't open when clicked

## Principle: New Items Are Always Immediately Visible

**Rule:** When a user creates a task, it MUST appear:
1. At the top of the visible list (not bottom)
2. In edit mode (cursor ready to type)
3. Scrolled into view (if somehow off-screen)

This is non-negotiable. The user's attention is at the top. New = top.

---

## List Order Abstraction

### Insertion Point

| Context | New task appears at |
|---|---|
| Quick-add input | Top of current list |
| Enter key (no selection) | Top of current list |
| Enter key (task focused) | Directly below focused task (sibling) |
| Shift+Enter (task focused) | First child of focused task |
| Context menu → "Add subtask" | First child of that task |

### Sort Interaction with New Items

When sort mode is active (not "My order"):
- New task still appears at the **top** visually (temporary pin)
- It gets a "just created" flag that keeps it at top for 5 seconds
- After 5 seconds (or after editing is done), it settles into its sorted position
- This prevents the jarring "I created it and it vanished" experience

When sort is "My order":
- New task is inserted at the top (position = before first sibling)
- This becomes its permanent manual position

---

## Subtask UX

### Creating Subtasks

| Method | How |
|---|---|
| Keyboard | Shift+Enter on parent → new subtask in edit mode |
| Mouse | Click "+" button that appears on hover next to parent tasks |
| Context menu | Right-click → "Add subtask" |
| Indent | Tab on a task → becomes child of task above |

### Editing Subtasks

Subtasks are full tasks — same widget, same interactions. They just render indented. No special editing mode needed.

### Visual

```
☐ Plan vacation                    [2/4 ████░░░░]
  └ ☐ Book flights                 tomorrow
  └ ☐ Reserve hotel                in 3d
  └ ☑ Research destinations        
  └ ☑ Set budget                   
```

The "+" button for adding subtasks:
```
☐ Plan vacation                    [2/4] [+]
  └ ☐ Book flights
```

The [+] appears on hover/focus next to any task, creates a subtask.

---

## Link Opening

### Current Bug
The 🔗 badge has `<a href>` but Tauri's WebView may block navigation. 

### Fix
Use Tauri's `shell.open()` API to open URLs in the system browser instead of navigating the WebView.

```js
import { open } from "@tauri-apps/plugin-shell";
// or fallback:
window.__TAURI_INTERNALS__?.invoke("plugin:shell|open", { path: url });
```

If the shell plugin isn't available, fall back to `window.open(url, "_blank")`.

---

## Implementation Plan

| # | Task | Fix |
|---|---|---|
| 1 | New task at top (position before first sibling) | Change create_task to prepend |
| 2 | Focus new task immediately after creation | Already done, but ensure scroll-to-top |
| 3 | Subtask "+" button on hover | Add to TaskRow |
| 4 | Link badge opens URL in system browser | Use shell.open or window.open |
| 5 | Sort mode: new items pinned to top briefly | Add "justCreated" transient flag |
