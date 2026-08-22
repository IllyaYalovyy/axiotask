# UX direction

## Trust before decoration

The most important UX correction is truthful synchronization feedback. Cached
tasks render quickly, but the interface never implies that cached state has
been verified merely because it loaded successfully.

### Sync health vocabulary

| Outcome | Meaning | Required presentation |
|---|---|---|
| Inactive | Sync was stopped, or usable Tasks authorization is absent | “Sync stopped” with Resume, or “No authorization” with Connect for an unconfigured account and Reauthorize for a durable terminal rejection; never green |
| Good | The latest forced or scheduled required sync succeeded less than five minutes ago and no work, failure, or uncertainty is newer | Green icon, “Synced,” and exact last-success time; this reports successful synchronization rather than claiming an atomic Google snapshot |
| Failed | A failure was detected, retry backoff/exhaustion is waiting, a run timed out, or last success reached five minutes without active verification | Persistent concrete reason—no connection, remote failure, application failure, or stale—plus last-success time/age, pending count, and any available action |
| Pending | A nonfailed verification/run is active or immediately queued, a retry request is executing, or durable work awaits its eligible immediate run | Yellow icon, precise activity/reason, and pending count; never green |

Color is never the only signal. A small status icon can summarize health, but
hover/tap and an accessible label expose the outcome, detailed reason, last
success, pending count, and next action. Offline, stale, unauthorized, uncertain,
and checking are reasons contributing to the four outcomes, not additional
competing top-level statuses. The account being connected is not itself evidence
of sync health.

Desktop places health in the always-visible application header and exposes
details without leaving the current work. A healthy desktop status is a calm
`Synced` label with a relative age; its exact completion time and diagnostics
route are in Sync details. Zero unresolved work stays out of the header.
Pending, failed, stopped, and unauthorized states expand with their reason,
nonzero unresolved count, and recovery action. Android uses the top app bar plus a
persistent banner for failed states. Neither platform hides
an expired token in a settings screen or transient toast.

## Information architecture

Shared concepts:

- smart views and Google task lists;
- task collection, task details, search, and bulk selection;
- account/sync health and application preferences;
- top-level tasks with subtasks in details.

Desktop starts with a navigation/list/detail composition when width permits.
The detail pane may become a dialog or route at narrower desktop widths. Android
uses a task-list route, full-screen details, platform navigation/drawer patterns,
and a reachable primary add action. Breakpoints are driven by available space
and input capability, not a hard-coded platform switch.

## Interaction principles

- Common create, complete, and date actions take one or two interactions.
- Destructive actions are unmistakable and undoable where the remote semantics
  allow a reliable undo; confirmation is reserved for high-cost/non-recoverable
  actions.
- Task and bulk-task deletion use the durable 30-second pre-dispatch Undo
  contract. List deletion and Clear completed instead require confirmation and
  provide no Undo.
- Optimistic changes appear only after their local transaction commits.
- Pending remote confirmation is globally visible without making every task row
  noisy.
- Mouse hover and context menus accelerate desktop use but never hide the only
  route to an action.
- Android touch targets meet Material accessibility guidance; swipe actions have
  visible alternatives.
- Keyboard shortcuts have discoverable menu/button equivalents and never become
  the sole workflow.
- Focus, selection, and system-back behavior are explicit state-machine tests.

Fedora presents navigation, collection, and detail panes together at 1024
logical pixels and wider, with narrower widths retaining the routed collection/
detail composition. `Ctrl+1`/`Ctrl+2`/`Ctrl+3` move focus between those visible
regions; `Ctrl+N`, `Ctrl+F`, and `Ctrl+Shift+V` accelerate visible capture,
search, and paste routes. Focused task rows support Enter, Space, E, D, M, and
Delete for their matching visible actions. F1 and the always-visible keyboard
button open the complete reference. Unmodified task commands are suppressed
while an editable text control has focus.

The Fedora workspace uses visible 12px resize splitters between navigation,
collection, and an open detail inspector. Pointer drag, resize cursor, focus,
Left/Right keys, and semantic increase/decrease actions are equivalent ways to
adjust the two side panes. Standard navigation/detail limits are 180–360px and
240–480px; Compact limits are 160–320px and 224–440px. A selected detail keeps
at least 320px of collection width (up to 400px at large text); an empty detail
inspector collapses completely. The device/profile-local presentation preference
restores requested widths on restart but clamps stale values to those limits;
it never belongs to task, account, or sync state.

Desktop quick capture is one compact title-field row with an Add button and
Enter submission. In a concrete Google-list collection that list is the
destination, so it is not repeated as an always-open selector. Smart views show
the destination because the target is otherwise ambiguous. Destination, due
date, and Paste multiple tasks are compact progressive options; a parsed or
explicit due date remains visible before acknowledgement, and parsing can still
be dismissed to retain literal title text. After a durable local acknowledgement
the capture reports that Google confirmation is pending and returns keyboard
focus to the title field. `Ctrl+N` and `Ctrl+Shift+V` remain discoverable
accelerators for the visible capture and paste routes.

In a Google-list collection using manual order, pointer drag shows an overlay
row plus a before/after insertion marker without moving the canonical rows until
the shared structure command commits. Dropping on another Google list uses the
same stable-ID move command. Sorted, same-position, smart-view, and other invalid
targets do not commit; cancel or failure removes the preview and exposes the
canonical projection. Detail Move up/down and Move to list controls remain the
focusable non-pointer equivalents.

Collection headers use two distinct command modes. Normal mode keeps the
collection title, a compact visible sort/order control, Select, and one labeled
collection-actions overflow; infrequent creation, list management, completed
visibility, and destructive clear commands live in that overflow with text
labels. Selection mode replaces that normal command row with a selected count,
explicit Exit selection, and labeled bulk actions. It never leaves both command
rows visible. A Good collection reports a plain task count; cache/stale wording
is reserved for health states that have not established current data. Escape
exits selection through the existing back route.

## Task hierarchy

Collection views show top-level tasks. Parent rows expose subtask progress and
the earliest relevant unfinished child date when product policy calls for it.
Subtasks are managed in task details and are never orphaned as unexplained rows
in smart views or search results. Search results that match a subtask open its
parent context and identify the match.

The product and local model support exactly one subtask level. There is no
deeper-hierarchy UI. Unexpected deeper API data is not edited, flattened, or
deleted; it produces a typed unsupported-data failure.

## Google Tasks UI and links

Every task has an explicit **Open in Google Tasks** action backed by a validated
Google `webViewLink`. It is an escape hatch for task capabilities that Google
exposes in its UI but not through the public API, including recurrence
configuration. If Google has not supplied a usable link, the disabled action
explains that state rather than disappearing.

Valid `http`/`https` links detected in task content are presented separately as
ordinary external links. Link detection, safety validation, and launch failure
are tested. A task's Google web link is never confused with a user-authored URL.

## Error presentation

Backup restore keeps the private-data warning visible, previews exact
create/existing counts, and explains that existing Google identity wins while
content is never matched. Stopped, unauthorized, offline, stale, or pending
first imports explain that a fresh sync is required. Cross-account preview and
result copy state the duplicate limitation and distinguish local acceptance
from later Google publication.

Errors answer three questions:

1. What did not happen?
2. Is the user's work safe?
3. What can the user do now?

If task storage cannot be opened or becomes unreadable, the normal task shell
is replaced rather than populated with an invented empty account. The recovery
surface says that saved data remains in place, that editing and Google sync are
stopped, exposes only a safe diagnostic code, and offers Retry Open. It never
renders a filesystem path, raw exception, account identity, or task content.

Local data recovery is separately reachable from the application header. Its
preview names aggregate cache, pending/uncertain, Undo, preference, sync, and
import counts without exposing an account identity. Confirmation states that
already-sent uncertain mutations cannot be recalled and that authorization and
device preferences remain. After commit it says “Rebuilt from Google” only for
Good health; an unavailable rebuild instead says the cache is empty and sync is
not healthy.

Transient, already-retrying conditions stay calm but visible in sync details.
Persistent failures affecting freshness or durability appear near the affected
workflow and in global health. The release product shows safe diagnostic codes
and summaries rather than raw exceptions or payloads.

## Development diagnostics

Debug development builds must not require terminal or filesystem access to
understand a failure. A clearly marked Diagnostics surface is reachable in one
interaction from sync details and provides a live, searchable event stream with
copy, explicit export, and clear actions. It includes sensitive task content,
remote payload context, operation/database transitions, and stack traces needed
for debugging, and continuously warns that the view and its exports contain
private test-account data.

This surface is not the release UX. Release builds provide only the bounded,
production-safe diagnostic history and have no hidden gesture, setting, or
runtime flag that can enable the sensitive development view. Neither build logs
credentials or uploads diagnostics automatically.

## Desktop visual system

Fedora uses one compact, documented desktop rhythm. The 4dp spacing scale is
4, 8, 12, 16, and 24 logical pixels. Standard density uses a 48px application
header, 40px ordinary fields and buttons, 20px icons, 16px horizontal inset,
and 12px section gap. Compact uses a 44px header, 36px controls, 12px inset,
and 8px section gap; body text remains at the Standard readable size. Desktop
buttons and fields use an 8px corner radius. Pills are limited to semantic
status or toggle treatments, not routine commands.

The native window title is the sole Axiotask brand treatment. The in-app
desktop header is a compact, labeled application-control bar: frequent
navigation, search, and sync controls remain visible, while keyboard help,
settings, backup, and local recovery are available in its labeled overflow.
Hover and keyboard focus have distinct visible state treatments in both themes.
These desktop reductions do not apply to Android touch targets.

## Accessibility and visual validation

- Semantics labels and roles are part of widget acceptance tests.
- Status never relies only on color, motion, tooltip, hover, or gesture.
- Text scaling, keyboard traversal, contrast, reduced motion, long titles/notes,
  and narrow/wide layouts have representative fixtures.
- Material defaults are a baseline, not an excuse for generic web-like layout.
- Significant states are checked through widget tests, curated goldens, and
  actual screenshots on Fedora and Android.
