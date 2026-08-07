# UI Migration Inventory — crates/axiotask-app/ui/src

Target: Flutter rewrite with FRESH visual design. This captures BEHAVIOR CONTRACTS, not markup.
Totals: 18 .svelte components, 8 .js modules (+theme.css, test-setup.js), 69 test files, 557 test cases (source `it(...)` lines; ThemeContrast runs its 2 inner cases twice via a parametrized describe over both themes).

Cross-cutting ratified contracts (encoded in CSS but load-bearing — must survive the redesign):
- Safe-area insets (#160): toolbar, FAB, drawer, full-screen detail panel all pad past notch/status bar/gesture pill, with explicit fallbacks for un-notched devices.
- 44px minimum touch targets on coarse pointers everywhere (buttons, checkboxes, rows, pickers). Checkbox specifically (#167): glyph stays small (~1.3rem), the HIT AREA pads out to 44px — never blow up the glyph.
- Reveal-without-reflow (#168): desktop hover action strip must not change row height (out-of-flow reveal). Mobile keeps swipe-reveal instead.
- Toast stack z-order (#172): toasts sit ABOVE every modal/overlay (error raised inside a dialog/panel/picker is visible immediately).
- Coarse-pointer vs fine-pointer split: swipe/long-press/tap-target behaviors on touch; hover/drag/dblclick on mouse.
- Theme: light/dark/system; both themes must keep text/background contrast (never use border tokens as text colors, #81).

---

## App.svelte (1848)
ROLE: Application shell — owns all state, data loading, view routing, keyboard dispatch, undo, toasts, and wires every child component.

### View-routing states (`selectedView`)
- "focus": effective due < today+7d (includes overdue). Renders Overdue section first (counted heading), then rest.
- "upcoming": today < effective due <= today+14d.
- "missed": effective due < today, sorted oldest-first.
- "unscheduled": no effective due (a parent with a dated subtask is EXCLUDED — it belongs to dated views).
- "all": every top-level task across lists.
- <list id>: that list's top-level tasks.
- ALL views render TOP-LEVEL tasks only (#82); subtasks live solely in the detail panel, never as rows.
- Smart views filter out excluded lists and (unless showCompleted) completed tasks.
- Selected view persists to localStorage and restores on start; window title = "<View> — axiotask".

### Global state owned by App
- lists, allTasks (flat array; each task decorated with listTitle/listId), loading.
- authenticated, needsReauth (dead session), needsAttention (stuck backed-off sync, #136 — derived live from sync-updated, never persisted), syncStatus (idle/syncing/error), lastSynced, lastSyncError.
- selectedView, sortMode (per view, persisted "sort:<view>"), showCompleted (persisted), completedBottom (always true), newestTaskId (transient pin-to-top), focusIndex, editingId (inline rename), detailId + detailFocusRequest (open panel + field-focus request), selectedIds (multi-select), completingIds (completion animation).
- Overlay/dialog state: showCheatsheet, showOnboarding, showProperties+settings+propsBusy, confirmDialog {title,message,confirmLabel,danger,onconfirm}, bulkAdd, showSearch, contextMenu {items,x,y}, movePickerTask, demoteTask, datePickerTask, bulkMovePicker, showMobileDrawer, renamingListId.
- undoItem (one at a time; variants below), errorToast, infoToast.
- themePref (dark/light/system), excludedLists (persisted), listOrder (persisted custom sidebar order).
- quickAddTitle, quickAddDateIgnoredFor, pull-to-refresh state (pullArmed/pullRefreshing).
- localStorage keys (all instance-namespaced): view, sort:<view>, showCompleted, excludedLists, listOrder, onboardingSeen, windowGeometry, theme, hideCompletedSubtasks (TaskDetail).

### Event subscriptions
- Tauri `listen("sync-updated")`: every background sync run reports → set needsReauth/needsAttention; on error set syncStatus=error and toast ONLY a new/changed message (no 60s spam); on success clear error, set lastSynced, info-toast conflict count ("kept as (conflicted copy)"); refresh data scoped by payload (lists_changed → full reload; changed_list_ids → only those lists; else full reload) — but SKIP refresh while an inline edit is in progress (would unmount the editor).
- `set_editing` IPC: continuously tells backend the ONE held task id (inline editor's row ?? open detail task) so its create-push id remap can't invalidate the id being edited.
- window keydown (global shortcut dispatch), window paste (Ctrl+V create), window beforeunload (save window geometry — restore intentionally DISABLED, WebKitGTK freeze), window popstate (Android back).

### Quick-add home (toolbar input + parser)
- Always-visible input; "+ New task"/FAB/`n`/Enter-on-empty all just FOCUS it (never create an empty task).
- Placeholder names the target list ("Add a task to <list>..."); smart views target the first list.
- Natural-language trailing due parsing: "YYYY-MM-DD" (optional "on"), "today", "tomorrow", "next week", "next month" (each with optional "due" prefix); month adds clamp to last day. Stripping the phrase must leave a non-empty title or no date parses.
- Live preview chip shows friendly relative date; chip's × keeps the phrase as literal title text (quickAddDateIgnoredFor) and re-focuses input.
- Creating from a smart view auto-assigns a due so the task is VISIBLE in that view without switching (#8): focus→today, upcoming→+7d, missed→today (can't be born overdue) + info toast "Added ... to Focus", unscheduled/all/lists→undated. Explicit parsed date wins.
- New task pinned to top (newestTaskId, cleared on view switch), focusIndex=0; if detail panel is OPEN it follows to the new task, if closed it stays closed.

### Selection / bulk-ops home
- toggleSelect via `x` key, Ctrl/Cmd-click on row, or long-press (touch). Esc clears. View switch clears.
- Bulk bar (n selected): Complete, Today/Tomorrow/Next week/Clear date, Move (list picker), Delete, clear-selection button; date keys (o/t/w/m/r) and Space/d/Ctrl+M apply to whole selection; each op clears selection, refreshes source lists, shows count toast ("N tasks completed/deleted/rescheduled/cleared/moved").

### Other behavior contracts
- Effective-due propagation: each task's effective date = min(own due, earliest effective date among UNFINISHED direct subtasks, recursive; completed subtask cuts off its subtree). Read-only "inherited" date drives smart-view membership, sorting, badges; memoized linear computation; dates compared as YYYY-MM-DD strings.
- Sidebar badges count OPEN TOP-LEVEL tasks per view/list — always equals visible cards.
- Sorting: manual (backend position) | due (earliest first, no-date last) | alpha | created (reverse position); persisted per view; completed always moved to bottom; newestTaskId overrides to top; reorder (drag/Alt+arrows) only in manual mode, with "Reorder disabled" notice otherwise.
- Focus view: overdue-by-effective-date cards grouped first; keyboard j/k order matches visual order.
- Complete: completing an open parent cascades to open descendants (mirrors Google); records reopenIds so a 10s undo restores parent AND cascade-closed children; un-completing never cascades (needs no undo); top-level completion animates ~300ms before the row leaves.
- Un-complete-all-subtasks: explicit action reopening every completed child of a parent (#89).
- Delete: any task; 30s undo via backend delete token; focusIndex clamped.
- Rename inline: empty title ⇒ deletes the task.
- Due set (set_due mv: Today/Tomorrow/NextWeek/NextMonth/Clear/raw:YYYY-MM-DD): if the backend cascaded parent/subtask dates to stay consistent (#164), show an undoable toast ("Parent date moved to match" / "N subtask dates moved") whose Undo reverts the WHOLE cascade via undo_set_due entries.
- Move to list: via picker (Ctrl+M), context submenu, or detail dropdown; if the open detail shows the moved task it follows the remapped id; 5s info toast (no undo).
- Two-level tree enforcement (invariant #1) at every mutation door: no subtask under a subtask, no parenting a task that has children; demotion ("Make subtask of…") offered only for childless top-level tasks with ≥1 legal parent in the SAME list; detach (promote) always allowed.
- Duplicate: creates "<title> (copy)" in same list/parent.
- Paste (Ctrl+V outside inputs): 1 line → create immediately in current/first list and switch to it; >1 line → open BulkAdd dialog prefilled; empty → nothing.
- Sync: manual doSync sets syncing, on failure NEVER hides local task list (toast + status only) and re-checks auth; fresh sync (destructive re-download) only via Properties behind styled confirmation; login outcome verified by re-querying auth_status (#45 — never inferred from invoke result), successful login triggers sync; logout re-checks auth and resets sync UI.
- Export/import backup: info toast with counts + path; import is non-destructive and reloads.
- Lists: create (normal or local-only), rename inline (Enter/blur commit, Esc cancel), delete behind styled confirm ("and all its tasks", falls back to focus view if current), exclude/include from smart views, custom drag order persisted locally (unknown lists append in backend order).
- Clear completed: only on a concrete list view when showCompleted on; styled confirm with count; not undoable.
- Search select: a found subtask is anchored THROUGH its parent — navigate to parent's list, focus parent row, open subtask's detail in parent context (#92).
- Empty-workspace onboarding shown once (onboardingSeen).
- Error toasts auto-dismiss 5–6s; info toasts 4–8s; all dismissible; friendlyError redaction (see ipc.js).
- Confirm dialog: generic styled alert-dialog (danger or primary), Esc/any-key cancels via global keydown.
- Startup: check auth → load all lists+tasks; cached data shows immediately without waiting for sync (offline-first); app fully usable unauthenticated (create/edit locally, never calls sync_now).
- Android back button (#159): while ANY dismissible surface is open a history sentinel intercepts back; one back closes the single topmost surface in precedence order onboarding > cheatsheet > drawer > context menu > date picker > confirm > properties > bulk-add > search > move picker > demote picker > bulk-move picker > detail panel > selection; nothing open ⇒ back backgrounds the app. (Mechanism is web-history-specific; the PRECEDENCE contract ports to Flutter's back handling.)
- Esc key mirrors that precedence on desktop.
MOBILE/POINTER NOTES: <700px sidebar becomes slide-in drawer with backdrop (open via hamburger, closes on select/backdrop/Esc/back); FAB (new task) replaces "+ New task" button; pull-to-refresh on task area (≥70px mostly-vertical drag from unscrolled top; runs sync when authed else reload; ignores pulls starting on inputs/buttons); safe-area insets on toolbar/FAB/drawer; 44px targets on toggles/buttons.

## AppBoundary.svelte (63)
ROLE: Top-level error boundary wrapping App.
BEHAVIOR CONTRACT:
- A render error shows "axiotask hit a UI error" screen with message + Retry (reset).
- Error rendered as text, never injected HTML.
- Logs the error to console with scope.

## BulkAdd.svelte (156)
ROLE: Modal dialog creating many tasks from pasted/typed multi-line text.
BEHAVIOR CONTRACT:
- Textarea prefilled with pasted text; auto-focused.
- Two modes: one task per non-empty line (default) | first line = title, rest = notes (single task).
- Live count preview: "Nothing to add" / "Creates N task(s)"; Add disabled at 0.
- List selector (defaults to current/first list); created tasks land there and the view switches to that list.
- Ctrl/Cmd+Enter submits from textarea; Esc/backdrop/×/Cancel closes without creating.
- After creation: "Added N task(s)" toast.

## Cheatsheet.svelte (75)
ROLE: Keyboard-shortcut overlay; doubles as first-launch onboarding.
BEHAVIOR CONTRACT:
- Renders SHORTCUT_CATEGORIES registry (single source of truth) in two columns.
- Normal mode: any key or click closes.
- Onboarding mode (empty workspace, once): welcome title, intro explaining quick-add + trailing dates, "Start using axiotask" button.
NOTE: Keyboard layer dies in Flutter ⇒ cheatsheet content dies with it; the ONBOARDING moment (first-launch intro to quick-add and natural dates) is worth keeping in some form.

## ContextMenu.svelte (115)
ROLE: Generic right-click menu with submenus (used for task rows and sidebar lists).
BEHAVIOR CONTRACT:
- Items: icon + label + optional shortcut hint + optional submenu; separators.
- Submenu opens on CLICK (or Enter/ArrowRight), NOT on hover; ArrowLeft closes it.
- Arrow keys move focus (wrap-around); Enter activates; mouse hover moves focus.
- Selecting an action closes the menu; Esc closes; click outside closes.
- Position clamped to viewport.
- Task menu items (built in App): Edit title, Edit notes (opens detail focused on notes), Set due date submenu (Today/Tomorrow/Next week/Next month/Pick a date…/Clear), Move to list submenu (all lists), Detach subtask (only for subtasks), Make subtask of… (only when demotable), Duplicate, Details, Open in Google Tasks (only with web_view_link), Delete. NO "Add subtask" (#91).
- List menu items: Rename, Exclude/Include in smart views (label flips), Delete list (confirmed).
MOBILE/POINTER NOTES: right-click only today (long-press on rows is selection, not menu) — Flutter needs an explicit affordance for these actions on touch.

## DatePicker.svelte (136)
ROLE: Custom calendar popover for picking a due date (replaces native date input — WebKitGTK popup didn't close on pick or theme).
BEHAVIOR CONTRACT:
- Opens on the month of the current value (or today); 6-week Sunday-first grid; prev/next month nav.
- Marks today (outline), selected value, focused day; days outside month dimmed.
- Click a day ⇒ emits "YYYY-MM-DD" (local, never UTC); footer Today emits today; Clear emits null.
- Arrows move focus by day/week (crossing months follows), PageUp/PageDown change month, Enter picks focused, Esc/backdrop closes.

## Icon.svelte (214)
ROLE: Inline SVG icon set (~40 named stroke icons; unknown name falls back to circle; optional aria-label).
BEHAVIOR CONTRACT: none beyond rendering — replace with Flutter icon set.

## ListView.svelte (79)
ROLE: Scrollable flat list of TaskRows for a concrete list / All Tasks.
BEHAVIOR CONTRACT:
- Renders rows in given order; empty state "No tasks / Use quick add or press n".
- Cross-list mode ("all") shows each row's list tag.
- Drag-reorder (manual sort only): drop indicator between rows; on drop computes direction + STEP COUNT counting only same-list, same-parent siblings between source and target (cross-list cards in "all" are skipped), emits onreorder(id, direction, steps).

## MoveToListPicker.svelte (68)
ROLE: Modal picker of destination lists (single move and bulk move).
BEHAVIOR CONTRACT:
- Shows all lists EXCEPT the task's current one (bulk mode shows all).
- Click selects; arrows move highlight (wrap), Enter selects; Esc/backdrop closes without moving.

## ParentPicker.svelte (104)
ROLE: Searchable modal to choose the parent when demoting a task to a subtask (#88).
BEHAVIOR CONTRACT:
- Candidates pre-filtered to legal parents (other childless-rule-satisfying top-level tasks in the same list).
- Type-to-filter by title (case-insensitive); highlight resets to first on every result change (can't point past end).
- Arrows/Enter select; click selects; Esc/backdrop cancels; "No matching task" empty state.
MOBILE/POINTER NOTES: larger input/row padding on coarse pointers.

## Properties.svelte (427)
ROLE: Settings dialog with Sync / Appearance / Account / Shortcuts / About tabs.
BEHAVIOR CONTRACT:
- Sync tab: Read-write sync toggle — turning ON requires inline confirmation ("Enable push" / Cancel; checkbox reverts until confirmed); turning OFF is immediate. Auto-sync-on-startup toggle. Status block: needs-attention error (distinct wording: "automatic retries have slowed down") vs plain last-error; stats: last synced (relative), pending pushes, last run ↓pulled ↑pushed · conflicts · removed, total syncs. Sync now / Fresh sync buttons (disabled unless authenticated; fresh sync confirmed by App's styled dialog). Backup: Export backup… / Restore latest… (restore is non-destructive).
- Appearance tab: theme radio Light / Dark / Follow system.
- Account tab: status dot + text (Signed in / Not signed in / Session expired — sign in again with explanation that local changes are kept and sync after re-auth); OAuth scopes listed with friendly labels; multiple-accounts hint (isolated instances); actions: Sign in with Google / Sign in again + Sign out / Sign out.
- Shortcuts tab: full shortcut registry (dies with keyboard layer).
- About tab: version, instance name (badge in header too; "default (production)" when none), repository link, DB path, config path, license.
- Esc / × / backdrop closes; controls disabled while busy.
MOBILE/POINTER NOTES: <700px tabs become a horizontal scrollable row.

## SearchOverlay.svelte (136)
ROLE: Global search modal over all tasks (title + notes).
BEHAVIOR CONTRACT:
- Auto-focused input; live results (max 20) once query non-empty; "No tasks found" empty state.
- Matches title OR notes, case-insensitive; open tasks ranked before completed; completed titles struck through.
- Result rows show: title, "Subtask" tag + parent title when applicable, list tag, due date (parsed as LOCAL date — no negative-UTC off-by-one, #76).
- Arrows navigate (selected row scrolls into view, #77); selection resets to first when results change (#narrowing safety); Enter or click selects and closes; Esc/backdrop closes.
- Selecting hands the task to App (subtask anchors through parent, #92) without reloading every list.
- Does not open from `/` while an input is focused; toolbar Search button opens it for touch users.
MOBILE/POINTER NOTES: bigger input/rows on coarse pointers.

## Sidebar.svelte (332)
ROLE: Navigation column — smart views, lists, sync/auth status, footer actions.
BEHAVIOR CONTRACT:
- Smart views: Focus, Upcoming, Missed, Unscheduled, All Tasks with open-count badges (badge hidden at 0); active view highlighted.
- Lists section: every list with count badge, active highlight, excluded lists dimmed+italic; "local" badge on local-only lists; right-click fires list context menu (rename/exclude/delete); empty state "No lists yet".
- New list: `+` button and `+◍` (local-only) button open an inline input; Enter/blur commits (trimmed, non-empty), Esc cancels.
- Inline rename triggered externally (renamingListId): input prefilled, Enter/blur commits, Esc cancels.
- Drag-to-reorder lists by dedicated grip handle (drop-above-target semantics, emits the full new id order); clicking a list (not the handle) still selects it.
- Footer, in priority order: needs-attention danger button ("Sync needs attention" → opens Properties; shown only when NOT needsReauth — re-auth wins); Sign in with Google / "Sign in again" (dead session) when unauthenticated or needsReauth — never a Sync button that can only fail; otherwise Sync now (disabled + "Syncing..." while syncing).
- Status line: colored dot (ok/offline/syncing-pulse/error) + text: Session expired | Needs attention | Sync error | "Synced Xm ago" (self-refreshes every 30s while open) | Ready | Offline; inline Sign out link when authenticated.
- Footer row: Properties button, theme toggle button (sun/moon flips with theme).
- No Fresh sync in the sidebar (Properties only).
MOBILE/POINTER NOTES: rendered inside the slide-in drawer <700px; 44px targets for view/list/action buttons on coarse pointers.

## SortDropdown.svelte (50)
ROLE: Toolbar dropdown choosing the view's sort mode.
BEHAVIOR CONTRACT:
- Shows "Sort: <label>" (My order default); click toggles menu; options My order / Due date / Alphabetical / Reverse my order with active marker; selecting fires onchange and closes.
MOBILE/POINTER NOTES: bigger targets on coarse pointers.

## TaskDetail.svelte (591)
ROLE: Detail/edit panel (side panel desktop, full-screen overlay mobile) for one task; the ONLY home of subtasks.
BEHAVIOR CONTRACT:
- Header: ‹ › prev/next through siblings (list order for top-level, parent's subtasks for a subtask; disabled at ends; Ctrl+←/→); title "Task Details" or "Subtask"; ✕ closes.
- Subtask context: breadcrumb "← <parent>" navigates to parent; "Detach from parent" promotes it.
- Fields: Title, Due date (button opens own DatePicker; quick buttons Today/Tomorrow/+1 week/+1 month/Clear — LOCAL dates, never UTC), List dropdown (HIDDEN for subtasks — a subtask always lives in its parent's list, #93; changing list keeps the panel open on the moved/remapped task), Notes textarea.
- Save model: auto-save per field on blur; save-on-close/navigate; ONLY fields that differ from loaded values are saved (no spurious pushes/412s, #4); Ctrl+S saves; NO Save button.
- Live-tracking: panel reads the task live from the store — an inline rename or sync pull updates the open panel; refreshed values adopt only into fields the user has NOT edited (typing is never clobbered).
- Auto-focus title when opened on an untitled task; focusRequest can target the notes field (context-menu "Edit notes").
- "From subtasks" read-only inherited date shown only when a propagated date exists, with explanation.
- Open in Google Tasks button only when web_view_link exists.
- Links: URLs auto-detected in title+notes (deduped, live) rendered as chips that open via open_url; no section when none.
- Subtasks (top-level tasks only): checklist rows with real checkboxes (toggle completes/reopens), clickable title opens the subtask's own panel, per-subtask due button opens DatePicker with friendly relative display; inline "Add a subtask" input — Enter or + creates named subtask under the parent and KEEPS focus for rapid entry (empty/whitespace creates nothing); "Hide completed" toggle (only when ≥1 completed; persisted across panels/sessions; UX-only — never touches data); "Un-complete all subtasks" button (only when ≥1 completed, #89); drag-reorder by grip with drop indicator — steps computed against the FULL subtask list so hidden completed rows between visible rows still reorder correctly; up/down move buttons as the touch path (move past nearest VISIBLE neighbor).
- No way to add a subtask to a subtask (two-level invariant).
- Delete task button (danger zone) deletes and closes.
- Esc closes (saving); closing an EMPTY subtask (no title/notes/due, not completed, no children) auto-deletes it — but NEVER one that has children (silent subtree loss).
MOBILE/POINTER NOTES: full-screen fixed overlay <700px with safe-area padding (#166); 44px fields/buttons/rows; drag grip hidden on coarse pointers, replaced by up/down buttons.

## TaskRow.svelte (444)
ROLE: One task card in any list/smart view — checkbox, title, quick date actions, metadata row.
BEHAVIOR CONTRACT:
- Checkbox toggles completion (never selects/opens the row); accessible label flips with state.
- Title; "Untitled" fallback; row click opens detail (focus); double-click title enters inline edit.
- Inline edit: input auto-focused + text selected; Enter/Tab commit, Esc cancels, blur commits.
- Pending-sync dot for sync_state=dirty ("Not synced to Google yet").
- Quick actions (hover/focus reveal on desktop; swipe-reveal on touch): →o Today, →t Tomorrow, →w Next week, →m Next month, ✕ Clear (✕ only when dated); clicks never propagate to the row; titles carry shortcut hints.
- Metadata row (always visible, no hover-to-reveal): notes icon when notes exist; link badge opening first URL (count shown when >1); scheduled calendar marker + friendly relative due (overdue red/bold, today amber; year shown only for non-current year) — clicking due/no-date/inherited opens the date picker; inherited (↳) date styled italic/dim as borrowed; subtask progress bar + done/total (click bubbles to row = opens detail); list tag in cross-list views.
- Completed rows: struck-through, dimmed; completing animation (~300ms shrink/fade).
- Focused row highlighted and scrolled into view (block nearest).
- Ctrl/Cmd-click toggles bulk selection (left accent bar when selected).
- Right-click opens context menu at pointer.
- Drag (manual sort only): dedicated ⠿ handle starts HTML5 drag; row is drop target; dragging dims row.
- No expand toggle / indent / connector — rows are always top-level (#82); no add-subtask affordance on the row (#91).
MOBILE/POINTER NOTES: long-press (450ms, no movement >10px) toggles selection and suppresses the synthetic click; swipe right ≥80px (mostly-horizontal) completes; swipe left reveals action strip (follows finger while peeking, opens at rest; tap elsewhere closes; a revealed strip's buttons still work); touch long-press 300ms on the drag handle arms touch-drag; 44px action buttons and checkbox hit area (glyph stays 1.3rem, #167); row min-height 44px; desktop reveal must not reflow (#168).

## Toast.svelte (30)
ROLE: Single toast row: message, optional Undo, dismiss ✕; error variant (alert role, red).
BEHAVIOR CONTRACT:
- Undo button only when an undo handler exists; dismiss always.
- Stacked by App: undo + error + info can coexist (Undo stays reachable under an error, GH#70).

## TodayView.svelte (169)
ROLE: Smart-view list (focus/upcoming/missed/unscheduled) — TaskRows with per-view empty states and Focus's Overdue section.
BEHAVIOR CONTRACT:
- Focus only: partitions cards into "Overdue (N)" section (by effective date incl. inherited) above the rest; count counts cards.
- Rows always show list tag (cross-list views).
- Same drag-reorder step semantics as ListView (same-list same-parent siblings only).
- Empty states per view: Focus "All clear for this week", Upcoming "Nothing upcoming (14 days)", Missed "Nothing overdue / You're all caught up!", Unscheduled "Everything is scheduled".

---

## JS modules

## ipc.js (93)
PURPOSE: Tauri invoke wrapper with per-command watchdog timeouts and error-message redaction (#135).
- timeoutFor(name): 12s default; overrides — auth_login 10min (user-paced OAuth), sync_now/fresh_sync 5min, import/export_backup 60s.
- invokeWithTimeout(name, args, ms): races invoke vs timeout, throws InvokeTimeoutError.
- friendlyError(name, e): auth signals verbatim ("Not signed in…", "session expired…"); timeout → "taking too long, app still responsive"; ALLOWLIST of app-authored validation fragments (invalid due date, cannot nest…, no backup file, etc.) + exact "task X not found" pass verbatim; EVERYTHING else redacted to "Couldn't <family action> — a local error occurred" (families: lists/sync/sign-in/settings/backup/default "save your change"). Raw SQL/reqwest/URL-bearing errors must never reach the user.
PORT NOTE: mechanism is Tauri-specific but the timeout budgets and the redaction-allowlist contract must survive in whatever bridge Flutter uses.

## dateFormat.js (38)
PURPOSE: Friendly relative due-date formatting, LOCAL-date parsing (no UTC off-by-one).
- parseLocalDate(due): parse YYYY-MM-DD prefix into local Date.
- formatDue(due): "Nd overdue"/yesterday/today/tomorrow/"in Nd"/short date; year only when not current year.
- dueClass(due): overdue | due-today | "" (styling hooks).

## taskTree.js (33)
PURPOSE: Pure predicates enforcing the strict two-level tree (invariant #1) — single source of truth.
- isSubtask(task): has parent_id.
- hasSubtasks(id, tasks): any task points at id.
- canAddSubtask(parent): parent exists and is top-level.
- canNestUnder(childId, parent, tasks): parent exists, top-level, not self, child has no children.

## storage.js (27)
PURPOSE: Per-instance localStorage key namespacing (multi-instance isolation).
- storageKey(name): "axiotask:<prefix>:<name>" (bare "axiotask:<name>" for default instance); prefix injected by Rust as window.__AXIOTASK_PREFIX__ before scripts run.
PORT NOTE: contract = two instances' UI prefs never collide; default instance keeps legacy keys.

## theme.js (26)
PURPOSE: Theme preference persistence + application (#46).
- getThemePref(): "dark" (default) | "light" | "system".
- applyTheme(pref): resolve system via prefers-color-scheme; set data-theme.
- setThemePref(pref): persist + apply. Applied pre-render (no flash).

## errorBoundary.js (42)
PURPOSE: Fatal-error rendering + backend startup-failure surfacing.
- formatError(e): stringify message safely.
- renderFatalError(target, title, error): text-only (no HTML injection) full-window error with stack.
- logBoundaryError(scope, error): console log.
- bootStartupError(win, target): if window.__STARTUP_ERROR__ set by shell, show "axiotask couldn't start" and SKIP mounting the app (no IPC against uninitialized state); returns whether it took over.

## main.js (32)
PURPOSE: Boot — apply theme first, handle startup error, install window.onerror/onunhandledrejection fatal handlers, dynamically mount AppBoundary.

## shortcuts.js (77) — NOT PORTED (keyboard layer dies)
PURPOSE: Declarative shortcut registry backing the cheatsheet + Properties Shortcuts tab (docs can't drift).
- SHORTCUT_CATEGORIES: Navigation j/k; Tasks n/Enter/e/Space/d/x; Due dates o/t/w/m/r; Organize Alt+↑↓/Ctrl+M; App / , ? Esc.
- formatKeys(keys): join alternatives.
Non-keyboard behavior hidden inside: NONE — it is pure data + a formatter. But it is the authoritative map of which ACTIONS exist (toggle complete, delete, quick dates, reorder, move-to-list, search, select) — every action listed must have a touch/pointer affordance in Flutter even though the keys die.

---

# Test inventory (behavior specs to re-cover in Flutter)

Legend: [PORT] = behavior must be re-covered in Flutter tests; [DIES] = mechanism-specific (Svelte/CSS-source/Tauri/keyboard), dies with the web app — though bracketed contracts noted below still need a Flutter-native equivalent.

## AndroidBackButton.test.js — [DIES as mechanism, PORT as contract] (history-sentinel is web-specific; back-precedence must be re-tested via Flutter back handling)
- "arms a history sentinel while a surface is open so back is intercepted, not backgrounded"
- "closes the drawer before it clears an active selection (drawer > selection)"
- "closes dialog, then panel, then selection in that order"
- "closes an open surface in a smart view (selection with no list view)"
- "with nothing open, back leaves the app untouched (it will background)"

## AppBoundary.test.js — [DIES as Svelte boundary; PORT as Flutter ErrorWidget contract]
- "renders a recoverable app-level failure screen when a child component throws"
- "renders startup and global failures without injecting raw HTML"

## AttentionIndicator.test.js — [PORT]
- "surfaces a stuck (needs-attention) sync as a persistent main-window indicator"
- "does not show the indicator for a merely transient failure"
- "clears the indicator once a later sync recovers"

## AuthRecovery.test.js — [PORT]
- "dead session: sidebar swaps Sync now for a Sign in again action"
- "#45: a successful login flips the UI to signed-in without a restart"
- "a failed manual sync never hides the task list"
- "recovered session: sync-updated clears the re-auth state"

## AutoSync.test.js — [PORT]
- "does not call sync_now on launch when authenticated" (backend owns startup sync)
- "shows synced state after backend startup sync event"
- "does not auto-sync when not authenticated"
- "shows toast on backend startup sync failure but app remains usable"
- "app loads cached data immediately without waiting for sync"

## BackgroundSync.test.js — [PORT]
- "surfaces a failed background sync as an error toast"
- "does not repeat the toast for the same persistent error"
- "explains a conflicted copy when a sync reports conflicts"
- "refreshes data when a background sync succeeds without scoped list data"
- "refreshes only changed task lists when sync reports affected lists"

## BulkAdd.test.js — [PORT]
- "defaults to one-task-per-line and shows a live count"
- "one-task-per-line creates a task for each non-empty line"
- "first-line-title mode creates one task with the rest as notes"
- "shows a confirmation toast after creating"
- "Cancel closes the dialog without creating anything"

## BulkOps.test.js — [PORT] (replace `x`-key/Esc triggers with touch/tap equivalents)
- "pressing x selects a task and shows the bulk bar with a count"
- "Ctrl/Cmd-click on a row selects it"
- "Esc clears the selection"
- "bulk Complete marks all selected tasks complete"
- "bulk Delete deletes all selected tasks"
- "the 't' key reschedules the whole selection to tomorrow"
- "bulk Move sends all selected to the chosen list"

## Cheatsheet.test.js — [DIES: keyboard cheatsheet; PORT only the onboarding case]
- "opens on `?` and renders shortcut content"
- "renders as a dialog overlay"
- "closes on Escape"
- "closes on any other key too"
- "shows first-launch onboarding once when the workspace is empty"  ← PORT

## CheckboxTapTarget.test.js — [DIES: CSS-source assertions; PORT contract: small glyph + 44px hit area]
- "has a dedicated pointer:coarse media block"
- "keeps the visual glyph at 1.3rem on coarse pointers"
- "does NOT blow the glyph up to 44px via min-width/min-height"
- "pads OUT to a 44px hit area around the 1.3rem glyph (content box)"

## ClearCompleted.test.js — [PORT]
- "Clear completed button is hidden when showCompleted is off"
- "Clear completed button appears when showCompleted is on and viewing a list"
- "Clear completed button is hidden on smart views"
- "shows confirmation dialog when clicking Clear completed"
- "canceling confirmation does not delete tasks"
- "confirming deletes completed tasks"
- "Escape closes confirmation dialog"

## CompleteUndo.test.js — [PORT]
- "clicking the checkbox completes the task, so its row leaves the open list"
- "Space on a completed task reopens it (row loses its completed state)"
- "shows undo toast after completing a task"
- "undo toast disappears after 10 seconds"
- "clicking Undo calls toggle_complete to restore task"
- "undo of a parent completion reopens the subtasks the cascade closed"
- "completing a subtask offers an undo toast"
- "undo of a mid-level subtask completion reopens it and its cascaded children"
- "dismiss button removes undo toast immediately"
- "completed tasks appear after open tasks"
- "completed tasks are hidden by default"
- "show completed toggle reveals completed tasks"
- "toggling show completed off hides completed tasks again"

## ContextMenu.test.js — [PORT actions; keyboard-navigation sub-suite DIES]
- "shows every action item on right-click"
- "offers no Add subtask option (#91) — subtasks added only in the detail panel"
- "expands due submenu showing date options"
- "does not auto-expand the submenu on hover — only on click"
- "clicking Tomorrow calls set_due"
- "expands move submenu showing available lists"
- "clicking a list in Move submenu calls move_task"
- "detaches a subtask from its parent via the detail panel"
- "does not show detach for top-level tasks"
- "clicking Duplicate creates a copy of the task"
- "clicking Details opens the task detail panel"
- "Details closes the context menu"
- "shows the item and opens the link when the task has a webViewLink"
- "hides the item for a task with no webViewLink (e.g. not yet synced)"
- [DIES] "ArrowDown moves focus to next item"
- [DIES] "ArrowUp wraps to last item from first"
- [DIES] "Enter triggers focused action"
- [DIES] "ArrowRight opens submenu"
- [DIES] "ArrowLeft closes submenu"
- "Escape closes the context menu" [DIES as key; PORT as dismiss]
- "clicking outside closes the context menu"
- "selecting an action closes the menu"
- "clicking Edit title enters edit mode on the task"
- "opens the detail panel with the Notes field focused in a smart view"
- "clicking Delete removes the task"

## dateFormat.test.js — [PORT]
- "omits the year for a far-out date in the current year"
- "shows the year for a far-out date in a different (future) year"
- "keeps the relative label across a year boundary (no year leak)"

## DatePicker.test.js — [PORT; Enter/Escape case dies with keyboard]
- "opens on the month of the given value"
- "emits the chosen day as YYYY-MM-DD"
- "navigates months"
- "Clear emits null"
- [DIES] "Enter picks the focused day; Escape closes"

## DeleteUndo.test.js — [PORT; `d`-key trigger dies, delete affordance stays]
- "pressing d on focused task calls delete_task"
- "task disappears from list after pressing d"
- "context menu has Delete option"
- "clicking Delete in context menu removes the task"
- "shows undo toast after deleting a task"
- "undo toast disappears after 30 seconds"
- "clicking Undo calls undo_delete with the token"
- "task reappears after clicking Undo"
- "dismiss button removes undo toast immediately"

## DemoteToSubtask.test.js — [PORT]
- "offers 'Make subtask of…' on a childless top-level task and demotes it via the searchable picker"
- "does NOT offer demotion for a task that already has subtasks of its own"
- "does NOT offer demotion when there is no other top-level task to nest under"

## DetailWorkflow.test.js — [PORT]
- "typing a subtask title and pressing Enter creates it named under the parent"
- "the + button adds the typed subtask"
- "an empty or whitespace-only field creates nothing (no Untitled debris)"
- "the list row exposes no add-subtask affordance (#91)"
- "never auto-discards an untitled subtask that has children of its own"
- "closing panel with Escape saves edited title"
- "auto-saves edited title on blur without pressing Save"
- "renaming a task inline updates the title in the open panel"
- "a refresh of the shown task does not clobber what the user is typing"
- "panel ‹ › navigation moves the focused row in the list"
- "pressing o on focused task calls set_due with Today" [key dies; quick-date affordance stays]
- "clicking Sign out calls auth_logout and shows Sign in button"
- "clicking Fresh sync calls fresh_sync after confirmation"
- "does not call fresh_sync if user cancels confirmation"

## DragAndDrop.test.js — [PORT semantics via Flutter reorderables; HTML5-drag mechanics die]
- "renders drag handles on task rows when sort is manual"
- "does not render drag handles when sort is not manual"
- "adds dragging class when drag starts on handle"
- "shows insertion indicator on dragover between tasks"
- "calls reorder_task on drop"
- "does not count other lists' smart-view cards as reorder siblings"
- "removes dragging class and indicator on drag end"
- "initiates drag state after 300ms touch hold"
- "cancels long-press if touch moves before 300ms"
- "only allows drop among same-level siblings (top-level only in flat view)"

## DueConsistency.test.js — [PORT]
- "cascading a parent date up shows an undoable toast, updates the row and the panel, and Undo reverts the whole cascade"
- "no toast when a date edit changes nothing else (cascaded = 0)"

## ErrorToast.test.js — [PORT — redaction contract is critical]
- "shows red error toast when a command fails"
- "redacts an unrecognized backend error to a calm family message (#135)"
- "auto-dismisses error toast after 5 seconds"
- "shows dismiss button that removes error toast on click"
- "shows a calm redacted toast for a delete_task failure (#135)"
- "hides a raw SQL/sqlx error from the toast, showing a human message (#128)"
- "never renders a synthetic no-marker error raw in the toast (#135)"
- "never renders raw reqwest network text (with a URL) in the toast (#135)"
- "still shows a deliberate validation message verbatim (#128)"
- "times out a hung startup command and returns control to the UI"

## Export.test.js — [PORT]
- "invokes export_backup from the Properties button"
- "shows a confirmation toast with counts and path after export"
- "surfaces a calm redacted error toast when the export command fails (#135)"

## FlatList.test.js — [PORT]
- "never renders a subtask as a row — only its top-level parent"
- "renders every row flush at the top level with no indent"
- "shows no expand/collapse toggle on a parent row"
- "shows subtask progress badge (completed/total) on parent"
- "does not show badge on tasks without subtasks"
- "shows subtask checklist when detail panel opens for a parent task"
- "subtask checklist shows completed state"
- "Enter opens detail panel for focused task" [key dies; tap-opens-detail stays]
- "Focus: a subtask never renders as a row, but its parent card does"
- "reorders a top-level task without any subtask rows in the way"

## HoverActionsNoReflow.test.js — [DIES: CSS-source assertions; PORT contract: hover reveal must not change row height]
- "scopes the no-reflow reveal to a fine (mouse) pointer so mobile swipe is untouched"
- "takes the action strip OUT OF FLOW on desktop so its box can't grow the row"
- "reveals the strip with visibility, NOT by toggling display into a box"
- "keeps the mobile swipe-reveal path (coarse pointer) intact and in-flow"

## Import.test.js — [PORT]
- "invokes import_backup from the Properties button"
- "shows a confirmation toast with counts and path after restore"
- "surfaces a calm redacted error toast when the import command fails (#135)"
- "reloads tasks after a successful restore"

## IncrementalRefresh.test.js — [PORT]
- "a single-list mutation refetches only that list, not all lists"

## IpcTimeouts.test.js — [DIES as Tauri-invoke tests; PORT budgets to the new bridge]
- "gives auth_login minutes, not the 12s default"
- "sync commands get a long network budget"
- "ordinary commands still fail fast at the default"

## KeyboardNav.test.js — [DIES: keyboard layer not ported. Bracketed contracts that survive: flat-list/no-nesting invariants, visual order = navigation order]
- "j moves focus down" / "k moves focus up" / "j does not go past the last item" / "k does not go above the first item"
- "Focus j follows the visual overdue-first order (top-level cards only)" [order contract PORTs]
- "pressing Space completes the focused task (it leaves the open list)"
- "pressing Enter opens detail panel for focused task"
- "pressing e enters edit mode for focused task"
- "pressing d removes the focused task's row from the list"
- "pressing n focuses quick-add without creating an empty task"
- "pressing s over the focused task adds no new row"
- "t re-dates the focused row to tomorrow" / "w re-dates the focused row a week out" / "m re-dates the focused row a month out" / "r clears the focused row's date (row shows 'no date')"
- "Tab leaves every task a top-level row (no indent, no nesting)" [invariant PORTs]
- "Shift+Tab leaves the flat list unchanged too" [invariant PORTs]
- "Ctrl+M opens the move-to-list picker"
- "Alt+Down moves the focused card below its neighbor" / "Alt+Up moves the focused card above its neighbor"
- "pressing / opens the search overlay"
- "pressing ? shows the keyboard cheatsheet"
- "does not trigger shortcuts when editing a task title"

## ListExclusion.test.js — [PORT]
- "right-click on list shows 'Exclude from smart views' option"
- "right-click on excluded list shows 'Include in smart views' option"
- "excluding a list hides its tasks from Focus view"
- "including a list restores its tasks in smart views"
- "excluded list has 'excluded' class in sidebar" (visual dim/italic marker)
- "non-excluded list does not have 'excluded' class"
- "toggling exclusion updates the class"
- "exclusion is saved to localStorage" (→ local prefs persistence)
- "inclusion removes from localStorage"
- "excluded list tasks visible when list selected directly"
- "excluded list tasks hidden from all smart views"

## ListManagement.test.js — [PORT]
- "renders + button with 'New list' title"
- "calls oncreateList with trimmed title from prompt"
- "does not call oncreateList when input is empty"
- "does not call oncreateList when prompt is cancelled"
- "fires onlistaction with list object and coordinates on right-click"
- "right-click on different list passes correct list object"
- "right-click triggers onlistaction enabling delete flow"
- "preventDefault is called on contextmenu event" [DIES: browser-specific]
- "creates a new list via + button and shows it in sidebar"
- "renames a list after right-click → Rename"
- "deletes a list after right-click → Delete with styled confirmation"
- "does not delete list if styled confirmation is cancelled"

## ListReorder.test.js — [PORT]
- "renders lists in backend order by default"
- "applies a saved custom order"
- "each list has a dedicated drag handle"
- "dragging by the handle onto another row reorders and persists"
- "clicking a list (not the handle) still selects it"
- "a new list (absent from saved order) appears at the end"

## ListView.test.js — [PORT]
- "shows empty state when no tasks"
- "renders tasks when provided"
- "does not show empty state when tasks exist"

## MobileDrawer.test.js — [PORT]
- "opens the sidebar drawer with sync and Properties actions, then closes after navigation"
- "keeps sign-in reachable from the mobile drawer when offline"
- "opens Properties from the drawer without leaving the drawer over the dialog"

## MoveToListPicker.test.js — [PORT; arrow/Enter case dies]
- "renders all lists except current"
- "calls onselect when a list is clicked"
- "calls onclose on Escape" [key dies; dismiss stays]
- [DIES] "navigates with arrow keys and selects with Enter"
- "calls onclose when overlay is clicked"

## MoveToList.test.js — [PORT; Ctrl+M trigger dies, picker + toast contracts stay]
- "opens move-to-list picker when Ctrl+M is pressed with a focused task"
- "picker shows all available lists except the current one"
- "selecting a list calls move_to_list and closes picker"
- "Escape closes the picker without moving"
- "shows toast after moving task via Ctrl+M"
- "shows toast after moving task via context menu"
- "context menu has Move to list submenu with available lists"
- "clicking a list in submenu calls move_to_list"

## NewTaskDetailFollow.test.js — [PORT]
- "switches the open sidebar to the newly created task"
- "leaves the sidebar closed when it was closed before creating (non-happy path)"
- "switches even when the panel was showing a different task"

## NewTaskPrepend.test.js — [PORT]
- "+ New task button focuses the quick-add input without creating an empty task"
- "n key focuses the quick-add input without creating an empty task" [key dies]
- "submitting quick-add creates a titled task at the top"
- "submitting in a smart view creates in the target list without switching views"

## OfflineFirst.test.js — [PORT]
- "shows sign-in button when not authenticated"
- "does not show sync button when not authenticated"
- "shows Offline status when not authenticated"
- "can create tasks without authentication (the new row appears in the list)"
- "never calls sync_now when not authenticated"
- "displays tasks from local store without authentication"

## OpenInGoogle.test.js — [PORT]
- "is shown when the task has a webViewLink"
- "is hidden for a task without a webViewLink (e.g. not yet synced)"
- "opens the task's Google URL via the open_url command"
- "shows a clickable chip for a URL in the notes"
- "detects a URL in the title too"
- "lists multiple distinct links"
- "shows no Links section when there are no URLs"

## PasteCreate.test.js — [DIES as Ctrl+V global paste (desktop-web gesture); PORT the bulk-split behavior via BulkAdd entry point]
- "single line paste creates one task immediately (no dialog)"
- "multi-line paste opens the bulk-add dialog prefilled (does not create yet)"
- "does not intercept paste when an input/textarea is focused"
- "does nothing when paste text is empty"

## Properties.test.js — [PORT; Shortcuts-tab and ','-key cases die]
- "has a Properties trigger in the sidebar"
- "opens from the sidebar button"
- [DIES] "opens with the ',' keyboard shortcut"
- "shows the sync mode toggle and reflects read-only by default"
- "enabling read-write sync requires confirmation before pushing"
- "canceling the confirmation leaves sync read-only"
- "shows sync status stats"
- "surfaces the last sync error when present"
- "surfaces a stuck (needs-attention) failure distinctly from a one-off blip"
- "Account tab shows signed-in status and scope"
- "Account tab surfaces an expired session with a Sign in again action"
- [DIES] "Shortcuts tab lists key bindings"
- "About tab shows version and repository (folded-in About)"
- "About tab labels the default instance"
- "shows the instance name when an isolated instance is active"
- "exposes Export and Restore backup buttons in the Sync tab"
- "Export backup confirms with a toast naming the counts and file"
- "Restore latest confirms with a toast naming the counts and file"
- "Fresh sync uses a styled confirmation inside Properties"
- "canceling the Fresh sync confirmation keeps local data untouched"
- "closes on Escape" [key dies; dismiss stays]
- "closes when the close button is clicked"

## QuickAdd.test.js — [PORT]
- "is always visible and creates a titled task without switching away from the current smart view"
- "a task quick-added from Focus is VISIBLE in Focus (due date pre-filled, no view switch)"
- "toasts that a task quick-added from Missed was added to Focus"
- "does not create an empty task when submitted blank"
- "previews a trailing natural-language due date and preserves the typed title"
- "can keep the parsed date phrase as title text without applying a due date"
- "previews and applies explicit YYYY-MM-DD quick-add dates without rewriting the title"
- "renders the preview chip as a friendly relative date, never the raw ISO (#78b)"

## Reschedule.test.js — [PORT]
- "renders →t, →w, →m buttons on every task row"
- "renders ✕ (clear) button when task has a due date"
- "does not render ✕ button when task has no due date"
- "shows actions when focused"
- "clicking →t calls onsetdue with Tomorrow"
- "clicking →o calls onsetdue with Today"
- "clicking →w calls onsetdue with NextWeek"
- "clicking →m calls onsetdue with NextMonth"
- "clicking ✕ calls onsetdue with Clear"
- "→t has title 'Tomorrow (t)'" / "→w has title 'Next week (w)'" / "→m has title 'Next month (m)'" / "✕ has title 'Remove date (r)'" [shortcut-hint titles die; accessible labels stay]
- "clicking reschedule button does not trigger row onclick"
- "clicking →w on overdue task calls set_due and task disappears from Focus"

## SafeAreaInsets.test.js — [DIES: CSS-source assertions; PORT contract via SafeArea/MediaQuery padding]
- "declares viewport-fit=cover so the webview draws edge to edge"
- "pads the toolbar past the status bar / notch (top + side insets)"
- "lifts the FAB above the bottom gesture pill and off the right edge"
- "insets the slide-in drawer from the top, bottom, and left edges"
- "insets the full-screen TaskDetail panel so its header clears the status bar"
- "gives every safe-area-inset an explicit fallback for un-notched/legacy webviews"

## SearchOverlay.test.js — [PORT; key-driven cases become touch/tap]
- "opens when / key is pressed" [key dies]
- "opens from the toolbar search button for touch users"
- "closes on Escape" [key dies; dismiss stays]
- "filters tasks by title"
- "filters tasks by notes content"
- "shows list tag for each result"
- "shows due date for each result"
- "GH#76: shows the correct due date in negative-UTC zones"
- [DIES] "supports arrow key navigation"
- "GH#77: scrolls the keyboard-selected result into view" [DIES with keyboard]
- "resets selection to the first result when the query narrows results"
- "selects the sole narrowed result on Enter after selection was out of range"
- "ranks open results before completed results"
- "strikes through completed search result titles"
- "marks subtask search results"
- "shows parent title for subtask search results"
- "GH#92: opening a found subtask anchors it to its parent, never loose"
- "selects task on Enter and closes overlay" [Enter dies; select-closes stays]
- "selecting a search result opens it without reloading every list"
- "shows 'No tasks found' when no matches"
- "closes when clicking overlay backdrop"
- "does not open when input field is focused" [DIES with keyboard]

## Sidebar.test.js — [PORT]
- "renders all smart view buttons"
- "highlights the active view"
- "calls onselect when a smart view is clicked"
- "shows count badge next to smart views with tasks"
- "does not show badge when count is 0 or absent"
- "shows count badge next to list items"
- "renders the + button for new list"
- "calls oncreateList with entered title"
- "does not call oncreateList if Escape pressed"
- "renders the local-only new-list button"
- "creates a local-only list with the local-only flag"
- "badges lists that are local-only"
- "shows Sync now button when authenticated"
- "shows Syncing... when sync is in progress"
- "disables sync button while syncing"
- "calls onsync when sync button is clicked"
- "does not expose Fresh sync from the sidebar"
- "shows last synced time"
- "updates the last synced age while the sidebar stays open"
- "shows sync error status"
- "does not show the needs-attention indicator when sync is healthy"
- "shows a persistent needs-attention indicator when sync is stuck"
- "keeps the indicator visible even when the transient status reads idle"
- "opens Properties when the needs-attention indicator is clicked"
- "does not show needs-attention when the session is dead (re-auth wins)"
- "shows Sign in button when not authenticated"
- "does not show Sign in button when authenticated"
- "calls onlogin when sign in is clicked"
- "dims excluded lists with excluded class"
- "non-excluded lists are not dimmed"
- "renders all task lists"
- "highlights the selected list"
- "shows empty state when no lists exist"

## SmartViewCounts.test.js — [PORT]
- "shows task count badge for Focus view"
- "shows task count badge for Missed view"
- "shows task count badge for Unscheduled view"
- "does not count completed tasks in badges"
- "excludes tasks from excluded lists in counts"
- "sorts overdue tasks oldest-first" (Missed sort order)

## SmartViews.test.js — [PORT]
- Focus: "shows overdue tasks" / "shows tasks due today" / "shows tasks due this week" / "does NOT show tasks due beyond this week" / "excludes tasks from excluded lists" / "a subtask due soon pulls its parent in as one card, count matches (#3)"
- Upcoming: "shows tasks due in next 14 days" / "does NOT show tasks due beyond 14 days"
- Missed: "shows only overdue tasks" / "shows empty state when nothing overdue"
- Unscheduled: "shows only tasks with no due date" / "shows empty state when everything is scheduled"

## SortDropdown.test.js — [PORT]
- "displays current sort mode label"
- "shows My order as default label"
- "opens menu on click and shows all options"
- "calls onchange when option selected"
- "closes menu after selection"

## Sort.test.js — [PORT; Alt+↓ case dies with keyboard but "no reorder outside manual" contract stays]
- "defaults to 'My order' sort"
- "shows sort options when dropdown is clicked"
- "sorts by due date — earliest first, no-date last"
- "sorts alphabetically A-Z"
- "sorts by reverse manual order — highest position first"
- "moves completed tasks below open tasks regardless of sort"
- "persists sort mode per view in localStorage"
- "restores sort mode from localStorage on view switch"
- "shows reorder disabled notice when sort is not manual"
- "does not show reorder disabled notice in manual mode"
- "Alt+↓ does not reorder when sort is not manual"

## StartupError.test.js — [DIES as __STARTUP_ERROR__ web injection; PORT contract: backend startup failure must be shown, never a blank/dead app]
- "shows the backend startup failure to the user instead of a blank window"
- "does not take over the window when there is no startup error (normal boot)"
- "renders a message containing markup as text, never as HTML"

## storage.test.js — [DIES as localStorage; PORT contract: per-instance prefs isolation]
- "uses bare axiotask: keys for the default instance"
- "treats an empty/null prefix as the default instance"
- "namespaces keys under the active instance prefix"
- "keeps two instances' keys disjoint"

## SubtaskDatePropagation.test.js — [PORT — core domain logic]
- "a parent with no date but an unfinished subtask due soon lands in Focus (count matches)"
- "the parent row shows the inherited date, marked with ↳"
- "a completed subtask's date does NOT propagate — parent stays unscheduled"
- "an explicit parent date LATER than the subtask still filters by the earlier effective date"
- "unscheduled view excludes a parent whose subtask is dated"
- "the detail panel shows the read-only 'From subtasks' date only when it exists"
- "recursion: a grandchild's date propagates up through an unfinished middle"
- "recursion: a COMPLETED middle cuts off its subtree"

## SubtaskReorder.test.js — [PORT]
- "dragging a subtask above another reorders it in the panel"
- "reorders correctly across a hidden completed subtask (hide-completed on)"
- "move-down button (touch path) reorders the subtask"

## SvelteWarnings.test.js — [DIES: Svelte compiler lint]
- "keeps known accessibility and local-state warnings fixed"

## Sync.test.js — [PORT]
- "shows Sync Now button when authenticated"
- "shows Ready status when authenticated and not yet synced"
- "shows Syncing... state during sync"
- "shows Synced timestamp after successful sync"
- "shows Sync error on failure"
- "disables Sync Now button while syncing"
- "reloads tasks after sync completes"

## TaskDetail.test.js — [PORT]
- "clicking a task opens detail panel"
- "panel shows task title in input"
- "panel shows task notes"
- "panel shows due date"
- "panel shows list dropdown with current list selected"
- "shows subtasks in detail panel"
- "completed subtasks show check mark"
- "uses real checkboxes for subtask completion"
- "lets a parent detail panel edit subtask due dates inline"
- "renders subtask due dates in the friendly relative format, not raw ISO"
- "hides completed subtasks when 'Hide completed' is toggled on"
- "does not show the 'Hide completed' toggle when no subtask is completed"
- "un-completes every completed subtask from the parent's explicit action"
- "does not show the 'Un-complete all subtasks' action when no subtask is completed"
- "remembers the 'Hide completed' preference across panel reopen"
- "lets a subtask detach from its parent in the detail panel"
- "Ctrl+S saves and closes panel" [key dies; save-on-close stays]
- "does not show a redundant Save button"
- "Escape closes detail panel" [key dies; dismiss stays]
- "close button (✕) closes panel"
- "delete button removes task and closes panel"
- "Today button sets due date to today"
- "Today uses the LOCAL date, not UTC — no off-by-one west of UTC in the evening"
- "Clear button removes due date"
- "the Due date field opens our calendar popover, which closes on pick"
- "changing list keeps the detail panel open on the moved task"
- "hides the List dropdown for a subtask (a subtask always lives in its parent's list, #93)"
- "opening and closing a task without edits writes nothing"

## taskTree.test.js — [PORT — pure domain rules]
- "isSubtask: only tasks with a parent_id are subtasks"
- "hasSubtasks: true only when some task points at the id"
- "allows adding under a top-level task"
- "refuses adding under a subtask (would be a 3rd level)"
- "refuses when the parent is missing"
- "allows nesting a childless top-level task under another top-level task"
- "refuses nesting a task that already has subtasks (its kids would be 3rd level)"
- "refuses nesting under a subtask (would be a 3rd level)"
- "refuses nesting under a missing parent"
- "refuses nesting a task under itself"

## TaskWidget.test.js — [PORT]
- "renders a real checkbox in unchecked state"
- "renders a real checked checkbox for completed tasks"
- "toggling the checkbox does not select the row"
- "renders task title"
- "meta-row is rendered without focus or hover"
- "shows notes icon when task has notes"
- "does not show notes icon when task has no notes"
- "shows link icon when title contains URL"
- "shows link badge 🔗 when notes contain URL"
- "shows link count when multiple URLs found"
- "does not show link badge when no URLs present"
- "shows relative due date"
- "shows 'today' for tasks due today"
- "shows overdue styling for past due tasks"
- "shows the year on the row when the due date is not the current year"
- "omits the year on the row for a current-year date"
- "shows 'no date' when task has no due date"
- "shows list tag in smart views"
- "hides list tag when showList is false"
- "shows progress bar and count when subtaskProgress is provided"
- "progress bar width reflects completion percentage"
- "does not show progress when subtaskProgress is null"
- "clicking progress opens the row's detail (bubbles to the row)"
- "renders no expand/collapse toggle even for a task with children"
- "renders no subtask connector or indent for a task with a parent"
- "offers no add-subtask affordance on the row (#91) — subtasks live in the panel"
- "shows a scheduled marker when the task has a due date"
- "does not show a scheduled marker when the task has no due date"
- "marks overdue scheduled tasks with the scheduled marker too"
- "exposes the marker for accessibility via title/aria-label"
- "renders action buttons that are accessible for touch"
- "shows a pending-sync marker for a dirty (unsynced) task"
- "shows no pending marker for a clean (synced) task"
- "clicking the due badge requests the date picker"
- "clicking 'no date' requests the date picker for an undated task"
- Touch (#50) sub-suite [PORT — gesture contracts]:
- "long-pressing the row toggles bulk selection"
- "does not let a long-press without a generated click suppress the next tap"
- "cancels long-press selection when the touch moves"
- "swiping right completes the task"
- "swiping left reveals the action strip without rescheduling"
- "swiping left on coarse pointers follows the drag and reveals the hidden action strip"
- "keeps the action strip hidden by default on coarse pointers"
- "a revealed action strip still lets the user choose Tomorrow explicitly"

## ThemeContrast.test.js — [DIES: CSS-token source assertions; PORT contract: readable text in BOTH themes] (inner cases run per theme: light + dark)
- "does not use a border token as a text color"
- "'no date' placeholder is readable on the row background"
- "focused-row action button is readable on --bg-elevated"

## theme.test.js — [PORT contract: default dark, persisted choice, applied on boot]
- "defaults to dark"
- "persists and applies a chosen theme"
- "applyTheme reflects the saved preference"

## ToastStack.test.js — [PORT]
- "stacks a sync error toast with an undo toast so Undo remains reachable"

## ToastZIndex.test.js — [DIES: z-index CSS assertions; PORT contract: toasts overlay every modal]
- "declares a toast-stack z-index above 3000"
- "out-stacks App's own confirm-overlay and mobile drawer"
- "out-stacks the highest z-index of every modal overlay component"
- "shows the error toast alert AND keeps the detail panel open" [PORT]

## TodayView.test.js — [PORT]
- "shows Focus empty state"
- "shows Upcoming empty state"
- "shows Missed empty state"
- "shows Unscheduled empty state"
- "renders tasks when provided"
- "groups overdue Focus tasks under a counted section header"
- "a parent overdue via an inherited subtask date groups under Overdue"
- "an expanded overdue parent keeps its subtree rows in its own section"

## TouchInteractions.test.js — [PORT]
- "mobile FAB focuses the quick-add input"
- "pulling down from the top runs a refresh sync"
- "does not refresh when pulling inside a scrolled task list"

## TwoLevelTree.test.js — [PORT]
- "a subtask's detail panel offers no way to add a sub-subtask"
- "a top-level task that has subtasks can still gain more (add field in the panel)"
- "adding a subtask from the parent panel keeps it exactly one level deep"

## UiStatePersistence.test.js — [PORT showCompleted persistence; window-geometry cases DIE (Tauri window API; restore already disabled due to WebKitGTK freeze)]
- "defaults showCompleted to false when no saved value"
- "restores showCompleted=true from localStorage"
- "persists showCompleted to localStorage when toggled"
- "persists showCompleted=false when unchecked"
- [DIES] "saves window geometry to localStorage on beforeunload"
- [DIES] "does NOT resize/move the window on mount, even with a saved geometry"

## UrlDetection.test.js — [PORT]
- "detects https URL in title"
- "detects http URL in notes"
- "detects URLs in both title and notes"
- "does not detect non-URL text"
- "handles URLs with query params and fragments"
- "shows an accessible link icon without count for single URL"
- "shows link count for multiple URLs"
- "badge has title attribute with first URL"
- "calls open_url command on badge click"
- "opens first URL when multiple exist"
- "does not propagate click to row handler"

## WindowTitle.test.js — [DIES as Tauri setTitle; contract trivial to re-honor on desktop targets]
- "uses the smart-view name (Focus on load)"
- "uses the list name when a task list is selected"

---
Suites that die wholesale (mechanism-bound): SvelteWarnings, IpcTimeouts, StartupError (injection mechanism), storage (localStorage), WindowTitle, UiStatePersistence (geometry half), HoverActionsNoReflow / CheckboxTapTarget / SafeAreaInsets / ThemeContrast / ToastZIndex (CSS-source inspection), KeyboardNav + Cheatsheet (keyboard layer), plus every individual [DIES]-marked key-triggered case. Their bracketed CONTRACTS (back precedence, tap targets, safe areas, no-reflow, toast stacking, contrast, instance isolation, startup-error surfacing, per-command timeout budgets) still need Flutter-native re-verification.
