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
details without leaving the current work. Android uses the top app bar plus a
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

In a Google-list collection using manual order, pointer drag shows an overlay
row plus a before/after insertion marker without moving the canonical rows until
the shared structure command commits. Dropping on another Google list uses the
same stable-ID move command. Sorted, same-position, smart-view, and other invalid
targets do not commit; cancel or failure removes the preview and exposes the
canonical projection. Detail Move up/down and Move to list controls remain the
focusable non-pointer equivalents.

## Task hierarchy

Collection views show top-level tasks. Parent rows expose subtask progress and
the earliest relevant unfinished child date when product policy calls for it.
Subtasks are managed in task details and are never orphaned as unexplained rows
in smart views or search results. Search results that match a subtask open its
parent context and identify the match.

The product and local model support exactly one subtask level. There is no
deeper-hierarchy UI. Unexpected deeper API data is not edited, flattened, or
deleted; it produces a typed unsupported-data failure.

## Recurrence and links

The Google Tasks API's `webViewLink` powers an explicit **Manage recurrence in
Google Tasks** action. The copy explains that recurrence is managed by Google's
UI because the API does not expose its configuration.

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

## Accessibility and visual validation

- Semantics labels and roles are part of widget acceptance tests.
- Status never relies only on color, motion, tooltip, hover, or gesture.
- Text scaling, keyboard traversal, contrast, reduced motion, long titles/notes,
  and narrow/wide layouts have representative fixtures.
- Material defaults are a baseline, not an excuse for generic web-like layout.
- Significant states are checked through widget tests, curated goldens, and
  actual screenshots on Fedora and Android.
