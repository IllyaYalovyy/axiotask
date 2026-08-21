# Axiotask — Product vision

## Purpose

Axiotask is a native Flutter client for Google Tasks on Fedora GNOME and
Android. Google Tasks is the backend and the durable cross-device task system;
Axiotask provides the responsive, efficient, trustworthy client that Google
does not.

Axiotask is not a local task manager with optional synchronization. It keeps a
local working copy so the interface stays responsive and remains useful during
temporary loss of connectivity, but every supported list and task is intended
to exist in Google Tasks.

## The problem

Google Tasks has useful integration with Google Calendar and the rest of Google
Workspace, but its clients make frequent task-management workflows slow and
offer poor visibility into synchronization health. The previous Axiotask client
made the latter problem worse: it could show a healthy indicator while an
expired authorization prevented all synchronization. That leaves the user
working against stale state and turns the next successful connection into a
large, avoidable reconciliation event.

The product's first obligation is therefore trust. A fast interface is not a
success if it misrepresents whether the displayed data is current.

## Product principles

### 1. Google-connected and truthful

Google Tasks is the product's remote system of record. Axiotask must make the
actual state of the connection understandable at a glance:

- whether the account is authorized;
- whether Google can currently be reached;
- whether synchronization is running;
- when synchronization last completed successfully;
- whether local changes are waiting to reach Google;
- whether the displayed data may be stale;
- the concrete reason for any failure and any action the application can
  actually offer.

A healthy indicator is allowed only after a verified successful synchronization
within the current freshness window and while no newer failure or unsent change
invalidates that claim. Expired or revoked authorization must be persistent and
prominent until repaired. Offline or stale data remains usable, but it can never
remain green. The user-facing outcome is one of inactive, good, failed, or
pending; inactive always explains whether authorization is absent or the user
stopped synchronization.

### 2. Correct, self-healing synchronization

Synchronization is the highest-risk subsystem and receives the strongest
architecture, specification, observability, and testing investment. It must be
deterministic where possible, resilient to retries and interruption, and
recoverable after restart.

Conflict labels or duplicated "conflicted copies" are not an adequate primary
strategy. Most concurrent changes should be reconciled automatically using
operation semantics and known base state. When safe automatic progress is not
possible, synchronization stops for the affected scope with a concrete failure
reason instead of inventing a generic manual-intervention state. No acknowledged
edit may disappear silently. Deletion is decisive: when a task is deleted, edits
to that deleted task no longer matter.

### 3. Offline continuity, not a second backend

The user can read cached Google Tasks and make changes without connectivity.
Those changes are durably queued and synchronized promptly after connectivity
returns or the application resumes. There are no local-only task lists.

Android does not perform periodic background synchronization while the
application is inactive. It synchronizes in the foreground and immediately on
resume. Local edits trigger a short coalescing window so synchronization feels
responsive without creating a network session for every keystroke.

### 4. Superior everyday efficiency

Common actions should require one or two clear interactions: capture a task,
complete it, move it, change its date, or find it. Meaningful defaults should
make the common case require no configuration. Mouse and touch efficiency are
primary; keyboard support on GNOME is an additional accelerator.

The application should be calm and information-dense without becoming cramped.
It should start quickly, respond immediately, and never feel like a web page in
a desktop or mobile shell.

### 5. Adaptive, platform-appropriate Flutter UI

Fedora GNOME and Android share product concepts, domain behavior, and visual
language, not a forced identical layout. Desktop can use its available width,
hover, context menus, and keyboard. Android must respect touch targets, gestures,
system back behavior, lifecycle, and safe areas.

### 6. One supported subtask level

The supported product model is a top-level task with at most one level of
subtasks. Primary lists and smart views show top-level tasks; task details show
and manage their subtasks. No deeper hierarchy is represented in the product or
local domain model.

### 7. Privacy and security by default

There is no telemetry, analytics, advertising, or account system beyond Google
authorization. OAuth tokens are stored only in platform secure storage.
Production diagnostics never contain task contents, credentials, full request
URLs, or personal account details. Development builds deliberately provide
local, visibly marked sensitive diagnostics—including task content and detailed
API/storage context—so failures can be investigated rather than hidden. Those
diagnostics are bounded, easy to inspect and clear, excluded from release
builds, never uploaded automatically, and never committed. Credentials,
authorization material, and private keys are never logged in any build.
Personal account/task data never enters committed fixtures, screenshots, or
repository artifacts; synthetic or dedicated test-account data is used instead.

### 8. Engineering quality is product quality

The application is built in small, reviewable changes with deterministic local
verification. Behavior is specified by meaningful tests, not coverage targets.
Architecture must keep synchronization independent of widgets and transient UI
state. Workarounds, silent fallbacks, proxy tests, and knowingly short-lived
designs are not acceptable substitutes for understanding the problem.

## Important product behavior

- Smart views, bulk workflows, search, task details, subtasks, fast date actions,
  and adaptive desktop/mobile interactions remain parity targets unless the
  parity matrix records an intentional change.
- Every task exposes an "Open in Google Tasks" action through Google's task
  `webViewLink` as an explicit escape hatch to UI capabilities the documented
  API cannot read or write, including recurrence configuration. Missing or
  invalid links stay visibly unavailable rather than hiding the action.
- Opening valid web links found in task content is a separate convenience and
  must not be conflated with the Google Tasks recurrence escape hatch.
- Synchronization can be stopped and resumed without deleting authorization,
  cached task data, or durable pending changes.
- Export and import are required user-controlled safety features. Their format
  and recovery semantics must preserve account boundaries and synchronization
  invariants.
- Read-only/push-disabled synchronization may exist in development tooling only
  if it does not complicate production behavior.

## Non-goals

- Replacing Google Tasks as the backend.
- Local-only task lists or a general-purpose local task database.
- Team project management, time tracking, Gantt charts, or document editing.
- Cross-product shared/assigned tasks created from Google Docs or Chat. They
  cannot be created in the standalone Google Tasks UX and Axiotask does not
  request the API's optional assigned-task results.
- Windows, macOS, iOS, web, or explicit support for non-GNOME Linux desktops.
- Periodic Android background synchronization.
- Special support for Android devices without Google Play Services.
- Recurrence editing through an API that does not expose recurrence.
- Distribution packaging, app-store publication, CI/CD, telemetry, or automated
  release infrastructure.
- Compatibility or migration from the Rust/Tauri application or discarded
  Flutter development builds.

## Target users

People who already use Google Tasks and want a dedicated desktop and mobile
client that makes frequent task management faster without weakening their trust
in cross-device state.

## Success criteria

Axiotask succeeds when users can:

- immediately understand whether the displayed data is synchronized, pending,
  offline, stale, failed, or awaiting reauthorization;
- launch into useful cached data quickly while a foreground refresh verifies it;
- create, complete, reschedule, find, and reorganize tasks with minimal friction;
- work through a temporary outage and converge safely after reconnection;
- trust that acknowledged work will not be silently lost or duplicated;
- use a polished, native-feeling interface on both supported platforms;
- build, test, and visually inspect the application locally from documented
  instructions on a clean supported development system.
