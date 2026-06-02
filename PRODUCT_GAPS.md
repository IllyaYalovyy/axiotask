# Product Gaps — axiotask MVP

*Product Manager assessment: what's missing, broken, or incomplete.*

## Critical (Blocks daily use)

- [ ] **Sync writes disabled** — local changes never push to Google. User will lose work if they reinstall or use another device. Must re-enable with conflict handling.
- [ ] **No date picker** — only keyboard shortcuts (t/w/m/r) set dates. No way to pick a specific date (e.g., "June 15"). Need a calendar popover.
- [ ] **No task detail panel** — clicking a task should open a detail view showing all attributes (title, notes, due date, list, subtasks) in an editable form. Currently only inline title edit exists.
- [ ] **Rename list** — no UI to rename an existing list. Only create/delete.
- [ ] **Delete list** — no UI to delete a list.
- [ ] **No error feedback on failed operations** — if a command fails, user sees nothing. Need inline error states.

## High (Significantly degrades experience)

- [ ] **Completion animation** — completing a task should have visual feedback (fade/strikethrough transition) before it disappears from smart views. Currently instant removal is jarring.
- [ ] **Undo for all destructive actions** — undo only works for delete. Should also work for: complete (accidental), move-to-list, clear-completed.
- [ ] **Drag-and-drop reorder** — Alt+arrows work but mouse/touch drag is not implemented. Essential for mobile.
- [ ] **List exclusion UI** — the exclusion logic exists but there's no right-click menu on lists to toggle it. User can't access the feature.
- [ ] **Search** — `/` focuses quick-add but there's no actual search/filter mode. Need a search overlay that filters across all tasks.
- [ ] **Keyboard shortcut for move-to-list** — Ctrl+M should open a list picker. Currently only available via context menu.
- [ ] **Collapse/expand subtasks** — h/l keys exist in keyboard handler but the collapse state isn't wired to the new component architecture.

## Medium (Polish & completeness)

- [ ] **Date picker popover** — clicking the due date badge should open a mini calendar for specific date selection.
- [ ] **Bulk operations** — select multiple tasks (Shift+click or Ctrl+click) and apply actions (move, reschedule, delete) to all.
- [ ] **Task count badges** — sidebar lists should show task count (e.g., "Work (12)").
- [ ] **Smart view counts** — "★ Focus (5)" showing how many tasks need attention.
- [ ] **Empty quick-add hint** — when quick-add is empty, show which list the task will go to.
- [ ] **Confirm destructive actions** — deleting a list with tasks should confirm. Clear-completed should confirm.
- [ ] **Keyboard shortcut discoverability** — tooltips on buttons showing the keyboard shortcut.
- [ ] **Auto-sync on startup** — when authenticated, sync should run once on app launch (currently disabled).
- [ ] **Sync conflict UI** — when push is re-enabled, conflicts need user-facing resolution (toast with "keep local / keep remote").

## Low (Nice-to-have for MVP)

- [ ] **Dark/light theme toggle** — currently dark only.
- [ ] **Window state persistence** — remember size/position across restarts.
- [ ] **Notification/reminder** — system notification when a task is due.
- [ ] **Recurring task display** — show recurrence pattern (daily/weekly/monthly) in the widget.
- [ ] **Import/export** — export tasks as JSON/CSV for backup.
- [ ] **Multi-account** — support multiple Google accounts.
- [ ] **Offline indicator** — show when the app is offline vs. just not syncing.
- [ ] **Onboarding** — first-launch tutorial showing key shortcuts and features.

## Technical Debt

- [ ] **Push sync disabled** — re-enable with proper conflict resolution.
- [ ] **Svelte a11y warnings** — NotesPanel and Cheatsheet have accessibility issues (non-interactive elements with handlers).
- [ ] **Test coverage for new features** — context menu, sort dropdown, paste-to-create, subtask button all lack dedicated tests.
- [ ] **No E2E tests** — component tests pass but real WebView rendering has broken multiple times. Need at least one smoke test that launches the app and verifies DOM content.
- [ ] **Token refresh** — if access token expires mid-session, refresh logic exists but is untested in production.
- [ ] **Error boundaries** — a single failed invoke can leave the UI in a broken state. Need component-level error boundaries.
- [ ] **Performance** — loading all tasks from all lists on every action is O(n*lists). Should cache and update incrementally.

## Prioritized Next Steps

1. Task detail panel (click to open, edit all fields)
2. Date picker popover
3. List management (rename, delete, exclude via right-click)
4. Search overlay
5. Re-enable sync push with conflict handling
6. Drag-and-drop reorder
7. Completion animation
8. Bulk operations
