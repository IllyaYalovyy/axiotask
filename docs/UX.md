# UX direction

## Android touch acceptance

The v1.5.3 behavior basis and November 15 regression audit are maintained as
36 numbered flows plus four findings in the Android regression manifest.
Task-row long press selects, horizontal swipes complete or schedule, and the
48 dp drag handle reorders siblings after Collection actions → Reorder tasks
in manual-order phone layouts. Done or system Back hides the handles;
non-manual sorts omit that action. Subtasks in details reorder by holding and
dragging the row, with Move up/down available in each row's menu. Ordinary
rows keep completion, content and one overflow menu; row gestures retain
their separate meanings. Pulling
down refreshes through the same coordinator as the visible Refresh action,
including empty and short lists, with progress and recoverable failure feedback.

Startup/sync feedback occupies at most 40% of a phone's available shell
height and scrolls to its actions, leaving room for the task collection.
Completion and deletion Undo appear at the bottom, above navigation and the
gesture inset, so acting on a row does not shift the remaining rows downward.
Undo yields during capture and selection, while its original window remains
valid. Routine bulk sync counts use the compact sync status on phones; bulk
failures still show their detailed feedback. This keeps short screens usable
while completing several actions in sequence.
Composer fields retain their input connection through short keyboard/rotation
frames. Outcome tests cover persistence and Undo; viewport/text-scale screenshots
supplement them. See [Testing](TESTING.md#android-takeover-qualification).
Physical signed-candidate and comparison-image qualification remains separate.

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
Routine local work stays compact too: verification of an earlier success
with no unresolved work, and edits made less than five minutes after a
verified sync with nothing uncertain or failed, both while they are queued
and while the run that publishes them verifies with Google. The status shows
the unconfirmed count (as a badge on phones; `Saved on device` or `Checking
Google` with the waiting count in wide windows), and its label and details
say the change is saved on this device but not yet confirmed by Google; it
never reads `Synced` while work remains.
Failed, uncertain, retrying, stopped, unauthorized and checking states, and
local work behind an old or absent success, expand into a bounded banner: the
outcome and a specific reason on one line, what happened to unsent changes
and the next step, the last-success age, the recovery action and Sync
details. The banner is at most 40% of the screen; at large text its text
scrolls while the controls stay in view. A failure whose cause is not
recognized says the cause is unknown
and points to the reference code in details instead of implying a reason.
Explanations come from typed reasons and known diagnostic codes, never from
raw errors. Android uses the top app bar plus this banner for failed states.
Neither platform hides an expired token in a settings screen or transient
toast.

## Information architecture

Shared concepts:

- smart views and Google task lists;
- task collection, task details, search, and bulk selection;
- account/sync health and application preferences;
- top-level tasks with subtasks in details.

Application-level places are reachable from the application menu ("More app
actions") on every form factor, and again from Settings, where a user looks
for them: Settings, Account (sign out, switch account), Account backup, Local
data recovery, Sync activity, About (with the version) and Support the
project. Settings holds every persistent choice: theme, density, collapse
completed subtasks, haptics (touch devices), read-only sync and auto-sync on
startup. Export opens a sheet with a preview and separate Copy, Save and
(Android) Share actions; nothing leaves the application before one is chosen.
None of these may be removed or hidden without the owner's explicit order; see
the [must-have feature contract](TESTING.md#must-have-feature-contract).

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
  visible alternatives. On task rows and subtask rows a touch swipe right
  completes the task (with the completion Undo) and a swipe left opens quick
  scheduling for that task; short, cancelled or mostly vertical swipes do
  nothing, and a mouse never swipes.
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

Phones (Android touch layouts narrower than the desktop workspace) restore
v1.5.3's bottom smart-view navigation. A bar under the collection offers Focus,
Upcoming, Missed, Unscheduled and All with equal-width 48 dp-plus touch targets;
the shown view is active (in pixels and semantics), a list opened from the
drawer leaves every destination inactive, and each destination announces its
view count, the same count the drawer shows. The bar pads itself past the
system gesture area, clamps label text scaling to 1.3 (labels scale down rather
than overflow at 320 dp), and is 56 dp with labels beside the icons on short
(landscape) layouts. It yields over details, search and the drawer, during
selection and capture, while a keyboard is up, and where it would leave the
collection less than three touch rows (scaled with text, for example a phone in
landscape at large text); the drawer's smart views and lists remain, and the
drawer button now shows at every width without the desktop navigation pane.
Back from details returns to the view that was active. Phone task rows show
v1.5.3's readable metadata beneath the title: a notes mark, the due date in
relative words ("2d overdue", "today", "in 3d", then "Dec 3") coloured by
urgency, an earlier open subtask's date ("↳ tomorrow"), "no date" when undated,
subtask progress ("1/2" with a bar) and, in a smart view, the task's list. The
items wrap rather than overflow, and assistive technology hears one phrase
("Has notes, Due 2 days ago, 1 of 2 subtasks complete, In Inbox"). The shared
`projectTaskRowMetadata` policy derives all of it from cached tasks; desktop
rows keep their dense subtitle.

Phones use a standard app bar: navigation at the leading edge, the current
list or smart-view title, then Search, compact sync health and an overflow.
Refresh and Stop sync live in that overflow; pull to refresh remains available.
The collection header carries its task count, sort and collection actions.
Details and search have their own app bars instead of a second global toolbar.
Keyboard focus decoration appears for keyboard use, not ordinary touch.

A floating New task button sits at the collection's bottom-right. The list
keeps room to scroll its last row clear of it. On short screens where it would
cover a row's controls, the button docks beside the count and collection
commands. It leaves during capture, selection or keyboard use. Tapping it
opens a bottom sheet above the keyboard, with focus in New task and a scrim
that prevents accidental changes to the underlying list. Cancel and Save stay
on the title row; optional multiline notes, destination, date and Paste
multiple scroll when height is limited. Save or keyboard submit stores title
and notes through the shared create command, then dismisses the sheet. The
next capture starts empty. A rejected or failed save keeps the draft and
explains the failure. Back lowers the keyboard first, then dismisses the
sheet while retaining the draft; tapping the scrim also retains it. Cancel
discards it. None of these dismissal actions creates a task. Desktop keeps
its quick-capture bar and consecutive-entry behavior.

In a Google-list collection using manual order, pointer drag shows an overlay
row plus a before/after insertion marker without moving the canonical rows until
the shared structure command commits. Dropping on another Google list uses the
same stable-ID move command. Sorted, same-position, smart-view, and other invalid
targets do not commit; cancel or failure removes the preview and exposes the
canonical projection. On touch, a drag handle on each row (long press, then
drag) reorders in My order; the row's actions menu also offers Move up and Move
down, which step the task past its nearest visible sibling through the same
command. Detail Move up/down and Move to list controls remain the focusable
non-pointer equivalents.

Collection headers use two distinct command modes. Normal mode keeps the
collection title, a compact visible sort/order control, Select, and one labeled
collection-actions overflow. On phones, the title is in the app bar and Select
tasks lives in the collection overflow alongside Reorder tasks; long press
remains a direct selection shortcut. Infrequent creation, list management, completed
visibility, and destructive clear commands live in that overflow with text
labels. Selection mode replaces that normal command row with a selected count,
explicit Exit selection, and labeled bulk actions. It never leaves both command
rows visible. When the labeled selection toolbar does not fit beside the title
(phones in either orientation, large text), it spans the collection above the
title and stays pinned outside the scrolling header. If the labels still do not
fit on one line, Complete, Reschedule, Move and Delete become 48 × 48 icon
buttons whose tooltips and accessibility labels carry the names; Exit and the
count lead, and the actions take a second line when the width requires it, so
no control is clipped or overflows. Long press on a row enters selection, and
system Back exits it. A Good collection reports a plain task count; cache/stale wording
is reserved for health states that have not established current data. Escape
exits selection through the existing back route.

## Task hierarchy

Collection views show top-level tasks. Parent rows expose subtask progress and
the earliest relevant unfinished child date when product policy calls for it.
Subtasks are managed in task details and are never orphaned as unexplained rows
in smart views or search results. A search result that matches a subtask names
its parent and opens the matched subtask itself, never the parent; system Back
then returns to the parent's details and, next, to the collection. The
collection stays as it was when it shows the hit's top-level task (the task, or
a subtask's parent); otherwise that task's list opens, as in v1.5.3.

Phone details have one Back action, completion beside the editable title,
a date row, notes that grow with content, subtasks, and expandable Google Tasks
links. Edit, move, organize, duplicate, Previous/Next and Delete live in the
app-bar task menu. Desktop keeps Previous and Next beside Back and Close.
Previous and Next step through the ordering the user came from: the visible collection, with its view, sort
and completed filter, for a top-level task, and the parent's subtasks, as
details list them, for a subtask. Each control is disabled at its end of the
ordering and in a one-task view. Steps are lateral, so Back still leaves for
the collection (or the parent of a subtask). Neighbours are resolved by task
identity when a control is used: when the open task leaves the ordering (it is
completed while completed tasks are hidden, rescheduled out of a smart view or
moved), Previous and Next still lead to the tasks that surrounded it, and a
deleted task closes details. Pending inline edits are stored on the task being
left before the next one opens.

The task-detail actions menu offers Duplicate task, as v1.5.3's detail overflow
did. It creates one new task titled "`<title>` (copy)" in the same list and under
the same parent, so a duplicated subtask stays a subtask; notes, the due date,
completion and subtasks are not copied, and Google places the copy first among
its siblings. Inline edits are stored first, so the copy uses the title the
editor shows; if they cannot be stored, nothing is copied and the failure is
shown. Details stay on the original and confirm "Duplicated as “…”" with Open
copy for a few seconds. A repeated tap while one Duplicate runs makes one copy.

The product and local model support exactly one subtask level. There is no
deeper-hierarchy UI. Unexpected deeper API data is not edited, flattened, or
deleted; it produces a typed unsupported-data failure.

## Desktop task inspector

The desktop inspector is an independently scrolling, compact editor. Complete
is the clear primary action and Edit remains direct. Status, Due, Notes, Google
Tasks, Subtasks, and Organization use short, ordered sections; absent notes or
subtasks use one concise line rather than reserving blank space. Due has one
Change due date menu containing fast dates and the custom-date route. Add
subtask appears beside its section heading. Reorder and move-to-list actions
are grouped in Organization, while hierarchy changes and deletion remain in
labeled menus with the existing task-delete Undo contract. Every control stays
reachable by scrolling at the inspector's minimum supported width and height.

Title and notes are edited in place, on phones and desktop alike, as in
v1.5.3; the Edit task dialog remains an explicit alternative. There is no
Save button: the text is stored once typing pauses (about 0.75 s), and
immediately when a field loses focus, on Back, on opening another task or
leaving the details, and when the app leaves the foreground. While a keyboard
composition is open the pause does not store the half-composed text; leaving
stores what the field shows. The notes field states whether changes are
unsaved, saving or stored automatically. An empty title is not stored: the
field explains that the saved title stays, the notes still save, and leaving
shows the saved title again. When a save fails the field keeps the text, says
it was not saved and why, and offers Retry; leaving and returning to the task
shows the same unsaved text until a retry stores it. Edits are kept per task,
so text typed for one task is never stored on another, and a slower earlier
save can never overwrite newer text. The policy lives in the shared
`TaskContentAutosave` service owned by the tasks view model; widgets never
write the database.

On desktop the custom-date route is a typed `YYYY-MM-DD` date. Touch
platforms (Android phones and tablets) restore the v1.5.3 calendar instead,
from both Change due date → Choose date and the swipe scheduling sheet. It
opens on the task's stored date with that day selected (today's month and no
selection when undated) and marks today from the application clock. The
arrows step by month and the month/year header opens a year grid. Tapping a
day only selects it. Set date stores the selection and Clear date removes the
date, both through the shared due command, so the parent/subtask cascade and
its Undo apply. Committing the stored date is not a change. Cancel, Back and
a tap outside store nothing. A failed change keeps the dialog and its
selection open with the reason. Calendar arithmetic uses UTC fields, so a day
whose local midnight is skipped by a daylight-saving or date-line change
still selects that day. The dialog fits narrow, landscape and 2x-text
phones: in landscape the summary and actions sit beside the calendar, and
the calendar scrolls when the screen is shorter than it. As in Material's own
date picker, the summary and actions scale text up to 1.6x and the day grid
up to 1.3x, so two-digit days stay whole at 320 logical pixels.

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

Desktop task rows use a stable two-line rhythm: 56px minimum in Standard and
48px minimum in Compact, with a title and one concise metadata line when
present. Long or scaled text grows the row rather than clipping. Completion,
selection, hover, focus, fixed action space, and reorder insertion/rejection
states remain distinct without shifting row text.

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
