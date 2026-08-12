# Google Tasks API contract evidence

Research snapshot: 2026-08-11 UTC. This document records the externally observable
Google Tasks API behavior on which Stage 4 synchronization may depend. It is an
evidence inventory, not a synchronization policy.

The accepted policy built on this evidence is in
[SYNC_SPEC.md](SYNC_SPEC.md); its evidence map is in
[SYNC_TEST_MATRIX.md](SYNC_TEST_MATRIX.md).

The primary machine-readable source was the official
[Tasks API discovery document](https://www.googleapis.com/discovery/v1/apis/tasks/v1/rest),
revision `20260804`, retrieved on 2026-08-09. Human-readable Google documentation
is linked at each claim. Documentation can change independently of this file, so
the discovery revision and research date are part of the evidence.

Controlled probes were run on 2026-08-11 UTC with approved credentials for a
dedicated development account and disposable uniquely prefixed data. Credentials,
raw IDs, and raw output remained outside Git; committed observations below are
sanitized. Historical Rust probes remain leads only unless the new run reproduced
them explicitly.

## Evidence labels

| Label | Meaning in this document |
|---|---|
| **Officially documented** | Stated by current primary Google documentation or the current official discovery document. |
| **Observed by a controlled probe** | Reproduced during the 2026-08-11 controlled runs with disposable data and sanitized evidence recorded below. |
| **Inherited historical evidence needing reverification** | Recorded by the read-only Rust project, but not independently reproduced for this contract. |
| **Inference** | A conclusion from documented presence or absence, not an explicit Google promise. |
| **Unknown** | Neither current documentation nor a controlled current probe establishes the behavior. |

Absence from the discovery document proves only that the current public Tasks
API does not expose that field or parameter there. It does not prove that Google
will never add it or that an undocumented server behavior is stable.

## Product boundary

Axiotask is a client for ordinary Google Tasks behavior, with offline
continuity. It does not expose local-only lists or cross-product assigned tasks.
Requests therefore keep `showAssigned=false`. The product supports a task and
one subtask level, matching the intended Google Tasks UX; behavior below that
level is outside product scope and must not influence synchronization design.

Recurring-task configuration is a Google Tasks UI capability, not an Axiotask
API feature. The `webViewLink` escape hatch for managing recurrence is separate
from launching user-authored links in task content.

## Resource fields

### Task list

Source: [TaskList resource](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists).

| Field | Contract evidence | Label | Synchronization significance |
|---|---|---|---|
| `kind` | Output-only resource type; always `tasks#taskList`. | **Officially documented** | Validate if present; it is not identity. |
| `id` | Task-list identifier. | **Officially documented** | Remote task-list identity. |
| `etag` | Resource ETag. | **Officially documented** | Presence is documented; mutation precondition behavior is not established by this field alone. |
| `title` | List title; maximum length 1,024 characters. | **Officially documented** | Mutable user content. |
| `updated` | Output-only RFC 3339 last-modification timestamp. | **Officially documented** | A version hint, not a documented change cursor. |
| `selfLink` | Output-only URL pointing to this resource. | **Officially documented** | Informational; not durable local identity. |

The resource has no documented deletion marker, parent, ordering, recurrence,
or client-supplied idempotency field. This is an **Inference** from discovery
revision `20260804`, not a promise about server internals.

### Task

Source: [Task resource](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks).

| Field | Contract evidence | Label | Synchronization significance |
|---|---|---|---|
| `kind` | Output-only resource type; always `tasks#task`. | **Officially documented** | Validate if present; it is not identity. |
| `id` | Task identifier. P7 preserved it during same-list and cross-list moves. | **Officially documented; observed by a controlled probe** | Remote task identity is stable across the probed move operations. |
| `etag` | Resource ETag. | **Officially documented** | Presence is documented; endpoint-specific conditional behavior requires probes. |
| `title` | Title; maximum length 1,024 characters. | **Officially documented** | Mutable user content. |
| `updated` | Output-only RFC 3339 last-modification timestamp. | **Officially documented** | A version hint. Ordering, uniqueness, and cursor semantics are not documented. |
| `selfLink` | Output-only URL pointing to this resource. | **Officially documented** | Informational only. |
| `parent` | Output-only parent task ID, omitted for top-level tasks; use `move` to change it. | **Officially documented** | Encodes the supported parent/subtask relation. |
| `position` | Output-only position string. Lexicographic comparison orders siblings under the same parent; use `move` to change it. | **Officially documented** | Opaque ordering value, meaningful only among siblings. |
| `notes` | Optional notes; maximum length 8,192 characters. | **Officially documented** | Mutable user content. |
| `status` | Either `needsAction` or `completed`. | **Officially documented** | Mutable completion state. |
| `due` | Optional RFC 3339 timestamp representing a scheduled day, not a deadline. Only the date is stored; the time is discarded and cannot be read or written through the API. | **Officially documented** | Domain value is date-only; a timestamp must not create a time-of-day claim. |
| `completed` | RFC 3339 completion timestamp, omitted while incomplete. | **Officially documented** | Server completion metadata; mutation/cascade details are not documented. |
| `deleted` | Boolean deletion flag; default `false`. | **Officially documented** | Establishes a task tombstone shape, but not retention or field completeness. |
| `hidden` | Read-only boolean; true when the task was completed when the list was last cleared. Default `false`. | **Officially documented** | Hidden completed tasks require explicit listing. |
| `links[]` | Output-only links with `type`, `description`, and `link`. | **Officially documented** | Google-originated links, separate from URLs parsed from task text. |
| `webViewLink` | Output-only absolute link to the task in Google Tasks Web UI. | **Officially documented** | Potential recurrence-management escape hatch; universal presence is not promised. |
| `assignmentInfo` | Output-only cross-product assignment context. | **Officially documented** | Deliberately excluded from this product with `showAssigned=false`. |

Discovery revision `20260804` exposes no recurrence rule, series identifier,
occurrence identifier, sync token, mutation request ID, or client-generated task
ID. That absence is **Inference**, not an explicit statement that private or
future APIs cannot expose such data.

The discovery snapshot can be reproduced without credentials:

```sh
curl -fsSL https://www.googleapis.com/discovery/v1/apis/tasks/v1/rest \
  | jq '{revision, schemas: (.schemas | keys), resources: (.resources | keys)}'
```

## Listing and pagination

Sources: [`tasklists.list`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/list),
[`tasks.list`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list), and
[Tasks parameters](https://developers.google.com/workspace/tasks/params).

| Behavior | Contract evidence | Label | Open consequence |
|---|---|---|---|
| Complete task-list enumeration | The method says it returns all task lists for the authenticated user. It returns `items` and an optional `nextPageToken`. Page size defaults to 1,000 and cannot exceed 1,000. An account can have at most 2,000 lists. | **Officially documented** | Every returned page is required for a complete documented enumeration. |
| Complete task enumeration | The method says it returns all tasks in the specified list, subject to request filters. It returns `items` and an optional `nextPageToken`. Page size defaults to 20 and cannot exceed 100. | **Officially documented** | Every returned page is required; filter choices define what “all” means. |
| Completed and hidden coverage | `showCompleted` defaults to `true`, but `showHidden=true` is also required to return tasks completed in first-party clients. `showHidden` defaults to `false` on the method reference. | **Officially documented** | Omitting either relevant flag can make a pull incomplete. The separate parameters guide currently contradicts the method reference by saying `showHidden` defaults to `true`; callers cannot safely rely on the default. |
| Deleted-task coverage | `showDeleted` controls whether deleted tasks are returned and defaults to `false`. | **Officially documented** | Deletion observation requires an explicit request choice. Tombstone lifetime remains unknown. |
| Assigned-task coverage | `showAssigned` defaults to `false`. | **Officially documented** | Product requests keep it false; assigned tasks are outside scope. |
| Incremental filters | `updatedMin`, `completedMin/Max`, and `dueMin/Max` are available. The time filters use RFC 3339. | **Officially documented** | No filter is documented as a lossless synchronization cursor. |
| Collection limits | Up to 20,000 non-hidden tasks per list and 100,000 tasks total at one time. | **Officially documented** | A client must not assume a smaller dataset. The documentation does not explain behavior beyond those limits. |
| Snapshot isolation across pages | Google does not document an immutable snapshot. In P3, a task inserted after page 1 was absent from the continued enumeration but present in a clean enumeration; continuation still returned 200. | **Observed by a controlled probe** | One page-token walk is demonstrably not a complete atomic snapshot under concurrent insertion. |
| Token lifetime and replay | No lifetime, single-use rule, consistency rule, or invalidation behavior is documented for `nextPageToken`. | **Unknown** | Resume semantics after interruption cannot be inferred. |
| Ordering of list results | No stable ordering guarantee is documented for task-list or task collection pages. Task `position` orders siblings after retrieval, but does not order pages. | **Unknown** | Page order must not be treated as hierarchy/order evidence. |
| Change feed or sync token | Neither the methods nor discovery revision `20260804` exposes a change-feed or sync-token operation. | **Inference** | Any complete-change claim must be based on available listings, not an invented delta API. |
| Collection ETag | Both list response schemas contain an `etag`; conditional GET semantics and what changes that ETag are not documented for Tasks. | **Unknown** | Do not treat collection ETags as verified change cursors without a probe. |

## Mutations and concurrency

Sources: [`tasklists.insert`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/insert),
[`tasklists.patch`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/patch),
[`tasklists.update`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/update),
[`tasklists.delete`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasklists/delete),
[`tasks.insert`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/insert),
[`tasks.patch`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/patch),
[`tasks.update`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/update),
[`tasks.delete`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/delete), and
[`tasks.move`](https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/move).

| Behavior | Contract evidence | Label | Open consequence |
|---|---|---|---|
| Create list | `tasklists.insert` creates a list from a `TaskList` body and returns the created resource. | **Officially documented** | The returned server representation is available on a known-success response. |
| Rename list | `tasklists.patch` supports patch semantics and returns the resulting `TaskList`; `update` uses PUT and also returns it. | **Officially documented** | Conditional conflict behavior is not documented. |
| Delete list | `tasklists.delete` deletes the specified list and returns an empty body on success. | **Officially documented** | Whether child tasks remain queryable, and exact repeated-delete/not-found behavior, are unknown. |
| Create task | `tasks.insert` creates a task and returns the created `Task`. Optional `parent` and `previous` parameters select hierarchy and sibling placement. | **Officially documented** | The response supplies the server ID only when the response is received. |
| Patch task | `tasks.patch` updates a task with patch semantics and returns the resulting `Task`. | **Officially documented** | Google’s Tasks performance guide documents generic merge semantics: omitted fields remain, supplied fields change, and `null` removes a field where valid. Per-field acceptance still requires verification. |
| Replace task | `tasks.update` uses PUT and returns the resulting `Task`. The Tasks performance guide says omitted optional fields in an update are cleared. | **Officially documented** | Exact writable-field validation remains endpoint-specific. |
| Delete task | `tasks.delete` deletes the specified task and returns an empty body on success. | **Officially documented** | The method page does not specify descendant effects, tombstone lifetime, or conditional headers. |
| Reorder/reparent | `tasks.move` returns the moved task. Omit `parent` for top level; omit `previous` for first among its siblings. Named parent/previous must exist in the relevant list and must not be hidden. P7 preserved IDs and returned canonical ETag/position changes. | **Officially documented; observed by a controlled probe** | Adopt the response and treat positions as opaque. |
| Cross-list move | `destinationTasklist` moves a task to another list. P7 moved both a single task and a parent subtree while preserving IDs; the child followed the parent. | **Officially documented; observed by a controlled probe** | A received-success cross-list move preserves identity in the probed cases. Repeating-task restrictions remain documented separately. |
| Position ordering | Positions are opaque strings; their lexicographic comparison orders siblings. | **Officially documented** | Only relative sibling comparison is contractual. |
| Position generation | The server’s allocation/rebalancing algorithm is not documented. | **Unknown** | Do not infer arithmetic or stability properties from one observed position format. |
| Previous-sibling errors | The method documents validity constraints, but not status codes when `previous`, `parent`, or the subject disappears concurrently. | **Unknown** | Exact error classification and recovery require probes. |
| Task conditional mutation | P1 sent stale/current/`*`/absent `If-Match` to task PATCH, UPDATE, DELETE, and MOVE. Every stale request returned 412 without changing the task; current, `*`, and absent variants succeeded. | **Observed by a controlled probe** | All four probed task mutations can use ETag preconditions; this remains endpoint behavior rather than a documented Google guarantee. |
| List conditional mutation | P2 sent stale/current/`*`/absent `If-Match` to task-list PATCH, UPDATE, and DELETE. Every variant succeeded, including stale ETags. | **Observed by a controlled probe** | Task-list rename/delete ignores `If-Match`; list conflict policy cannot depend on it. |
| Successful mutation response | Insert, patch, update, and move document a resource response; delete documents an empty response. | **Officially documented** | Google does not guarantee that every echoed field is canonical beyond the resource schema. |
| Lost response after mutation | P5/P6/P7 discarded a successful response before read-back/replay. Identical task/list creates duplicated; repeated PATCH/list rename changed version metadata again; repeated DELETE returned 204; repeated same-list MOVE was a 200 no-op; retrying a completed cross-list MOVE from the original list returned 404 while the same ID remained in the destination. | **Observed by a controlled probe** | Recovery must be operation-specific. Blind replay is unsafe for create and misleading for cross-list move. |
| Duplicate-create prevention | Discovery exposes no request ID, idempotency key, conditional-create parameter, or client-selected resource ID. P5 repeated identical task and list POSTs; both calls returned 200 and produced two different IDs. | **Inference; observed by a controlled probe** | Blind retry of an uncertain create demonstrably creates duplicates. |
| Invalid generic PATCH | The Tasks performance guide says an invalid patch returns `400` or `422` and leaves the resource unchanged. | **Officially documented** | This is a guide-level range, not an endpoint-specific matrix. |
| Endpoint validation details | Exact codes and resource effects for each invalid Tasks field/limit are not documented. | **Unknown** | Probe representative invalid fields and limits; do not assume one code for every validation error. |

The [Tasks performance guide](https://developers.google.com/workspace/tasks/performance)
states that its examples may use other APIs while the concepts apply to Tasks.
It therefore supports PATCH-versus-PUT semantics, but it is not sufficient
evidence for exact Tasks endpoint status codes or conditional behavior.

## Deletion, hierarchy, dates, completion, and recurrence

| Behavior | Contract evidence | Label | Open consequence |
|---|---|---|---|
| Soft-deleted flag/listing | A `Task` has `deleted`, and `tasks.list` can include deleted tasks with `showDeleted=true`. | **Officially documented** | The API exposes a task deletion marker through filtered listing. |
| Tombstone shape/retention | P4 direct-GET returned 200 with `deleted=true` after deletion. A directly deleted task retained `due`, `etag`, `links`, `notes`, `position`, `status`, `title`, `updated`, and `webViewLink` in this run. PATCH returned a 200 deleted echo and changed the stored tombstone title; MOVE returned 404. | **Observed by a controlled probe** | Tombstones are readable and mutable in surprising ways, but one run proves no retention duration. Deletion remains terminal for product policy. |
| Parent deletion | P4 deleting a parent soft-deleted its child. Direct child GET returned 200 with `deleted=true`; the returned child no longer contained `parent`. | **Observed by a controlled probe** | Parent deletion cascades in the probed ordinary-task case. |
| List tombstone surface | The task-list collection exposes no documented deletion marker or `showDeleted` parameter. | **Inference** | No public list-tombstone capability is visible in discovery revision `20260804`. |
| List-deletion aftermath | P4 list DELETE returned 204; later list GET, task listing, and direct task GET returned 404. Repeated list DELETE returned 204, and list GET remained 404 after two seconds. | **Observed by a controlled probe** | Repeated delete is idempotent in the probed window; no list tombstone/task recovery surface was observed. |
| Parent/subtask creation | `tasks.insert` accepts a `parent`; omitting it creates a top-level task. Assigned tasks cannot be parents or children. | **Officially documented** | Supports the product’s single subtask level. Exact missing/hidden-parent failures require probes. |
| Parent/subtask move | `tasks.move` changes `parent`; completed hidden tasks, assigned tasks, and repeating tasks have documented nesting restrictions. | **Officially documented** | Product scope remains exactly one subtask level regardless of deeper undocumented/legacy behavior. |
| Subtask count | `tasks.move` documents a maximum of 2,000 subtasks per task. | **Officially documented** | The product must not assume a larger supported sibling set. |
| Completion cascade | P8 completing a parent completed its child; reopening the parent did not reopen the child. Reopening a child under a completed parent returned 200 but remained completed. Inserting or moving an open child under a completed parent returned it completed. | **Observed by a controlled probe** | The adapter must adopt the returned/refetched cascade state rather than assume the requested open state landed. |
| Clear completed | `tasks.clear` marks completed tasks in the list as hidden and returns an empty body. | **Officially documented** | Complete enumeration must account for hidden tasks. Exact field/ETag changes are unknown. |
| Due date | `due` accepts an RFC 3339 representation but stores only a date; time is discarded and unavailable through the API. | **Officially documented** | No time-of-day or deadline can be synchronized through this API. |
| Due timezone/canonical echo | P9 converted the supplied instant to its UTC calendar date and returned midnight UTC with milliseconds. Offset inputs crossed to the prior/next UTC date. Bare/invalid strings returned 400; empty string and JSON `null` cleared/omitted due. | **Observed by a controlled probe** | The encoder must intentionally send a UTC-midnight representation of the product date; it must never reuse an arbitrary local-offset timestamp. |
| Completion timestamp | `completed` is RFC 3339 and absent for incomplete tasks. | **Officially documented** | Who assigns/clears it and its precision under status transitions are not documented. |
| Hidden/completed listing | First-party-completed tasks may require both `showCompleted=true` and `showHidden=true`; `clear` makes completed tasks hidden. | **Officially documented** | A default request is not a complete account view. |
| Web UI link meaning | `webViewLink` is an output-only absolute Google Tasks Web UI link. | **Officially documented** | It is distinct from a user-authored URL in task text. |
| Web UI link presence/navigation | Google does not promise `webViewLink` is present for every ordinary task or that it opens a recurrence editor directly. | **Unknown** | Recurrence UX needs a current probe, but this does not block core content synchronization. |
| Recurrence in Google UI | Google Tasks Help documents creating, editing, completing, and deleting repeating tasks in Google Tasks/Calendar; recurring tasks cannot move between task lists. | **Officially documented** | Recurrence exists in the product even though its rule is absent from the public Tasks schema. |
| Public recurrence contract | Discovery revision `20260804` has no recurrence field or recurrence mutation. Therefore the current public API surface offers no documented way to read or configure the recurrence rule. | **Inference** | Axiotask cannot claim API recurrence support. `webViewLink` is the intended escape hatch, pending link-presence verification. |

Official recurrence source:
[Manage repeating tasks in Google Tasks and Google Calendar](https://support.google.com/tasks/answer/12132599?co=GENIE.Platform%3DDesktop&hl=en).

## Limits, failures, and authentication

Sources: [Tasks quotas and limits](https://developers.google.com/workspace/tasks/limits),
[Tasks authorization](https://developers.google.com/workspace/tasks/auth), and
[Google OAuth 2.0](https://developers.google.com/identity/protocols/oauth2).

| Behavior | Contract evidence | Label | Open consequence |
|---|---|---|---|
| OAuth scope | Read/write requires `https://www.googleapis.com/auth/tasks`; read-only access can use `tasks.readonly`. | **Officially documented** | Synchronization mutations require the write scope. |
| Access-token expiry | Access tokens have limited lifetimes and may be refreshed. | **Officially documented** | Expiry is normal and must not be represented as healthy synchronization. |
| Refresh-token failure | Google documents several invalidation/expiry causes and `invalid_grant` during refresh, including revoked grants and some session policies. | **Officially documented** | The auth layer can receive a terminal reauthorization condition. Exact Tasks request payloads remain separate. |
| Tasks authentication response | P11 sent a malformed bearer token to task-list listing and received 401 with `WWW-Authenticate`; the JSON error contained `code`, `errors`, `message`, and `status`. Expired, revoked, and wrong-scope cases were not probed. | **Observed by a controlled probe; otherwise unknown** | The adapter may classify this observed malformed-token shape as unauthorized but must not generalize it to unprobed auth failures. |
| Daily quota | Courtesy limit is 50,000 queries/day; Google warns that projects may have different quotas visible in Cloud Console. | **Officially documented** | The public number is not a complete per-project runtime limit. |
| Per-minute/user limits | No Tasks-specific public contract was found for per-minute, per-user, or burst limits. | **Unknown** | Runtime status and headers must be captured in a controlled quota-safe probe if possible. |
| Rate-limit response | A discarded initial unpaced probe run encountered HTTP 403 with structured reason `quotaExceeded` and no `Retry-After`; no threshold was established or intentionally exhausted. | **Observed by a controlled probe** | Treat 403 quota reasons as remote throttling, retain pending work, and use client backoff when no server delay is supplied. Do not treat every 403 as quota. |
| Transient server errors | No Tasks-specific status matrix, retry duration, or service-level guarantee was found. | **Unknown** | Generic Google guidance can inform a later conservative policy but is not this API’s verified contract. |
| Error envelope | Tasks endpoint pages do not specify a stable JSON error schema or stable human-readable messages. | **Unknown** | Error parsing must not depend on undocumented prose; exact structured fields need observation. |
| Lost connection | TCP reset, timeout, cancellation, and response truncation are transport outcomes, not evidence that a mutation did or did not commit. | **Inference** | The uncertain-mutation cases must be specified per operation after probing. |
| Malformed/unexpected success response | The discovery schema defines valid responses, but Google gives no guarantee about client behavior when a success body is truncated, invalid JSON, missing required synchronization fields, or contains unknown fields. | **Unknown** | Decoder acceptance/rejection rules belong in the synchronization specification and tests, not in an invented server contract. |

Generic Google Cloud retry pages are intentionally not promoted to Tasks facts.
They consistently warn that retry safety depends on both the error and operation
idempotency, but endpoint-specific Tasks evidence is still required.

## Read-only historical evidence

The Rust/Tauri project was inspected only as historical behavioral evidence at
commit `6297cebac5da6c008243051974520932ab6cd642` (2026-08-05). Its live probe
harness and commit history report tests against a throwaway development account,
but the new project does not contain sanitized raw probe transcripts from those
runs. Every item below therefore remains **Inherited historical evidence needing
reverification**.

Historical source locations:

- `crates/axiotask-core/examples/live_api_probe.rs`
- `designs/RFC-009-sync-conflict-matrix.md`
- commits `a3d2a51b61ccbc367d1a30561f57be3c3b23621a` (2026-07-22),
  `4a73c51b71195931b7bca3f09ba3f2eb17cc7c57` (2026-07-23), and
  `7a38173c6ea3b541c69c355dd29578fbf948aa76` (2026-07-24).

| Historical claim to reverify | Label | Why it matters |
|---|---|---|
| A stale `If-Match` on task PATCH returned 412; task DELETE honored `If-Match`; task-list PATCH ignored it. | **Inherited historical evidence needing reverification** | Conditional mutation and list-rename conflict capabilities. |
| Task move required an explicit zero-length body, changed the task ETag, and returned 404 for a deleted `previous` anchor while an unknown subject returned 400. | **Inherited historical evidence needing reverification** | Correct transport and ambiguity classification. |
| Parent deletion cascaded; completion of a parent completed descendants; reopening the parent did not reopen children. | **Inherited historical evidence needing reverification** | Parent/subtask convergence. |
| Inserting or moving an open child under a completed parent returned it completed; inserting a child did not change the parent ETag. | **Inherited historical evidence needing reverification** | Response adoption and concurrent hierarchy changes. |
| Deleted tasks remained directly readable with `deleted=true`; PATCH of a deleted task returned a success echo while the stored tombstone remained unchanged. | **Inherited historical evidence needing reverification** | P4 reproduced direct readability and the success echo but contradicted “stored unchanged”: the tombstone title changed while `deleted=true` remained. |
| A full timestamp due value was normalized to midnight UTC; an empty string cleared due; a bare date was rejected. | **Inherited historical evidence needing reverification** | Exact due wire encoding, which current documentation does not fully specify. |
| Unknown parent, field-size boundaries, and invalid due values produced permanent 4xx errors. | **Inherited historical evidence needing reverification** | Validation classification without relying on message strings. |

These claims must not be copied into the new fake, synchronization engine, or
tests as current truth until the controlled probes below reproduce them.

## Controlled probe plan

### Safety and reproducibility setup

Every probe run must use a dedicated Google test account and a dedicated OAuth
client authorized only for the Tasks scope. Credential and token files must be
outside this repository. Before any Tasks enumeration or mutation, the harness
must resolve the authenticated Google subject and compare it with an explicit
expected-subject value stored outside Git. Missing or mismatched identity stops
the run with zero Tasks API calls. Operator confirmation is additional evidence,
not the isolation control. No probe may enumerate or mutate a normal application
account.

Use a run prefix of `axiotask-contract-probe-<UTC date>-<random suffix>`. Create
only disposable lists with that prefix. Record results outside Git while the run
is active. A `finally`/trap cleanup must delete every created list, followed by a
list query that confirms no matching list remains. If cleanup fails, stop and
report the exact disposable list names through the secure test channel; do not
hide the failure.

The sanitized record committed in a future evidence update may contain:

- UTC run date, discovery revision, probe version/commit, and account class
  (`dedicated-test`) but no email address;
- HTTP method and endpoint template, status, selected non-sensitive response
  header names/values such as `Retry-After`, and field names/types;
- opaque IDs replaced consistently with labels such as `list-A`, `task-1`;
- ETags replaced with `etag-A`, `etag-B`, preserving only equality/change;
- task titles/notes replaced with probe labels;
- no bearer/refresh tokens, OAuth codes, client credentials, raw URLs containing
  identifiers, raw bodies containing user data, or local machine paths.

### Probe matrix

| Probe | Disposable setup and operation | Evidence to record | Required cleanup |
|---|---|---|---|
| P1: task preconditions | Create one task; retain ETag A; mutate to obtain ETag B; send PATCH, UPDATE, and DELETE variants using A, B, `*`, and no header. Use a fresh task per destructive case. | Status, whether content changed, returned ETag equality/change, and direct GET/list result. | Delete scratch list. |
| P2: list preconditions | Create fresh lists; rename/delete with stale/current/`*`/absent `If-Match`. | Status, resulting title/presence, response fields. | Delete surviving lists. |
| P3: pagination under mutation | Create enough tasks for multiple small pages. Between pages independently insert, patch, move, and delete uniquely labeled tasks. Repeat for task lists with small pages. | Token acceptance, duplicate/omitted labels, ordering, collection ETag changes, and whether a second clean enumeration differs. | Delete scratch lists. |
| P4: tombstones and list deletion | Create parent/child and ordinary tasks; delete child, parent, then a separate list. Query with/without `showDeleted`, direct GET/PATCH/move, and inspect retained fields. Recheck after a bounded delay, explicitly not claiming indefinite retention. | Status and sanitized field-presence matrix; descendant outcomes; list visibility; tombstone ETag/updated behavior. | Delete surviving lists. |
| P5: uncertain create | Create a uniquely titled task/list while deliberately discarding the successful response, then repeat the identical POST once. Enumerate by unique marker. Do not simulate by merely timing out before request transmission. | Count, IDs-as-labels, and whether any request-id/idempotency facility is accepted. | Delete every created resource. |
| P6: uncertain non-create mutations | For task patch/delete/move, list rename, and list delete, allow the server to receive the request while the client discards the response, then read back before any retry; separately retry an identical request. | Final resource state, ETag/updated changes, duplicate effects, and repeated-delete/move responses. | Delete scratch list. |
| P7: move, order, and delete race | Reorder first/middle/last; reparent; use stale/deleted/missing `previous`; move parent/child across lists; then issue task DELETE through the old source-list path and current destination in separate disposable cases. | ID stability, descendant behavior, ETag/updated/position changes, exact statuses, relative order, and whether stale-path DELETE can report success while the ID remains live in the destination. | Delete both lists. |
| P8: parent/completion | Complete/reopen parent and child in each order; insert/move an open child under a completed parent; clear completed tasks. | Response versus refetched states, cascade direction, timestamps, ETags, hidden/deleted flags. | Delete scratch list. |
| P9: due dates | Insert/patch offsets around UTC date boundaries, fractional/no-fraction timestamps, bare dates, invalid dates, `null`, and empty string. | Status, canonical echo, refetched value, and semantic date. | Delete scratch list. |
| P10: recurrence/Web UI link | In the dedicated account only, manually create one ordinary and one recurring task in current Google UI. Retrieve both without changing recurrence. | Presence/shape of `webViewLink`, API field differences, and whether opening the link reaches the intended task-management UI. No claim based on hidden fields. | Delete both tasks/series in Google UI and scratch list. |
| P11: auth failures | Against an empty disposable list, use an expired access token, revoked/invalid refresh token in the OAuth layer, insufficient scope, and malformed bearer token. | Status, stable structured error fields, and headers; redact all token material and message text that contains identifiers. | Revoke only the dedicated probe grant if required; delete list first. |
| P12: writable fields and parser fixtures | For every optional writable task field, set a non-empty value and then clear it using each representation supported by primary documentation; read back after every request. Also send representative oversized/invalid fields. Separately feed locally stored synthetic truncated JSON, wrong types, missing fields, and unknown fields to future adapter tests; do not attribute synthetic fixtures to Google. | Exact accepted clear representation, canonical response/read-back, endpoint statuses and unchanged/changed resource state; decoder result for synthetic fixtures. | Delete scratch list. |

Do not intentionally exhaust the 50,000-query courtesy quota to manufacture a
rate-limit response. If normal quota-safe probing encounters throttling, record
the sanitized status, structured reason, and `Retry-After` presence. Otherwise
rate-limit response details remain Unknown.

## Controlled probe evidence — 2026-08-11 UTC

### Reproducible setup and custody

- Go `1.25.12` standard-library harness; current source-set SHA-256
  `37b853d05397982ecb5da24f486e0457a43d9c87bc224e566f5bc41d2af9e63a`.
- Dedicated development account, OAuth grant limited to the Tasks scope, and
  disposable `axiotask-contract-probe-<UTC>-<random>` lists only.
- Successful runs paced requests by 800 ms. Each request/response—including
  task content and raw IDs—was written to a mode-`0600`, Git-ignored local log;
  authorization headers, tokens, client credentials, and refresh responses were
  never logged.
- Main run: 68 sanitized observations across P1–P9 and the safe P11 malformed
  bearer case; sanitized-record SHA-256
  `71d3d57dfe9dc6f2366555b71f1b371aa59379dbb28ee7500b5e8e1445452852`.
- Focused corrected run: 34 observations across P1/P2/P7 after fixing malformed
  PUT probe bodies and adding MOVE preconditions/cross-list replay;
  sanitized-record SHA-256
  `ddd01ef21f756699e99f3ec9adfd7ee2ade75a905ab12cf2bef8f9aee0d09696`.
- Each successful run performed prefix-scoped deletion and a zero-match
  re-enumeration. A separate cleanup-only invocation independently reconfirmed
  zero matching lists for both prefixes.
- One earlier unpaced run was discarded after 403 `quotaExceeded` responses.
  It left 26 prefixed lists temporarily; a later prefix-scoped cleanup deleted
  all 26 and confirmed zero remaining. Only the rate-limit response itself is
  retained as evidence from that run.

### Sanitized observations

| Probe | Observed result | Specification consequence |
|---|---|---|
| P1 task preconditions | PATCH, UPDATE, DELETE, and MOVE returned 412 and made no change with a stale ETag. Current, `*`, and absent preconditions succeeded (200 for resource-returning mutations, 204 for DELETE). | Use `If-Match` for task mutations formed against a confirmed base. A 412 is conclusive stale-base evidence, not a transient failure. |
| P2 list preconditions | PATCH, UPDATE, and DELETE succeeded even with a stale ETag. Rename changed ETag; stale DELETE removed the list. | List ETags cannot provide conditional-write protection. Delete remains decisive; rename needs explicit non-atomic reconciliation policy. |
| P3 concurrent pagination | All original tokens remained accepted. A task inserted after page 1 was omitted from that walk and appeared in a clean enumeration. Single patch/move/delete task trials and insert/patch/delete list trials showed no duplicate/omission relative to the subsequent clean view. | Treat every paged walk as non-atomic. One clean trial cannot promote the unaffected cases to guarantees. |
| P4 deletion | Task delete produced readable tombstones; parent delete cascaded to its child. PATCH of a deleted task returned 200 and changed tombstone content while leaving it deleted; MOVE returned 404. List deletion made the list and its tasks unreadable, while repeated list DELETE returned 204. | Never resurrect or conflict-copy a deleted task from a mutation echo. Adopt deletion as terminal and treat list absence separately from task tombstones. |
| P5 uncertain create | Repeating an identical task POST or list POST returned 200 twice and produced two distinct resources. | An uncertain create cannot be blindly replayed. The API supplies no verified exactly-once create mechanism. |
| P6 uncertain non-create | Repeated identical task PATCH and list rename returned 200 and changed ETag/`updated` again. Repeated task DELETE returned 204. Repeated same-list MOVE returned 200 without another position/ETag change. | Read-back can identify landed desired state, but replay effects differ by operation and must be specified individually. |
| P7 move/order | Same-list reorder/reparent and cross-list moves preserved task IDs. A parent cross-list move carried its child. Deleted `previous` returned 404; fabricated `previous` returned 400. Retrying a landed cross-list move from the original list returned 404 while the same ID remained in the destination. | Cross-list move is not a clone/delete operation. Recovery must search the destination by stable ID before interpreting source-list 404. |
| P8 completion | Parent completion cascaded to children; parent reopen did not. Child reopen under a completed parent returned 200 but remained completed. Insert/move under a completed parent returned a completed child. Clear returned 204 and all observed completed rows were hidden. | Mutation echoes/read-back and server cascades are authoritative; requested `needsAction` cannot be assumed to land under a completed parent. |
| P9 due | Google normalized valid instants to the corresponding UTC date at `00:00:00.000Z`. Offset boundary inputs moved to the prior/next UTC date. Bare/invalid values returned 400; empty string and JSON `null` cleared/omitted due. | Encode the product date directly as UTC midnight. Do not serialize a local-offset instant and assume its written calendar date survives. |
| P11 malformed bearer | Malformed bearer produced 401, `WWW-Authenticate`, and JSON error fields `code`, `errors`, `message`, and `status`. | This case is unauthorized. Expired, revoked, and wrong-scope classification still needs separate safe evidence. |

## Remaining API unknowns and implementation gates

Stage 4 synchronization policy is accepted. These unknowns gate only the named
adapter or later UX slice; none permits guessed behavior.

| Unknown | Accepted policy | Implementation gate |
|---|---|---|
| Task-list rename race | List PATCH/UPDATE/DELETE ignore stale `If-Match`, so the read/write race cannot be closed. Timestamp policy applies to observed versions; the returned/read-back server result is authoritative for a later race. | Contract tests must reproduce ignored preconditions; no extra live fact is needed to implement the accepted limitation. |
| Uncertain create recovery | P5 proves replay can duplicate and discovery exposes no idempotency/client-ID facility. Retry without content matching, bind the first durably received ID, then apply the newest desired generation; an earlier duplicate may remain. | P5 remains the live contract test for both task and list creates. |
| Concurrent pagination beyond observed cases | P3 proves insertion can be omitted. A successful run means the required traversal completed, not that Google supplied an atomic snapshot. Server mutation results are authoritative for an unobservable race; absence alone never deletes. | P3 remains the fake/live contract boundary. |
| Tombstone retention duration | Do not rely on indefinite retention. Confirm only from current positive evidence or a confirmed local operation. | No adapter slice depends on a retention duration. |
| DELETE after a concurrent cross-list move | Old-source MOVE returns 404, but old-source task DELETE has not been probed. Never confirm from old-list absence or an unverified stale-path response; resolve/read back by stable ID. | The P7 extension gates delete/move race handling. |
| Optional writable-field clearing | Generic PATCH documentation does not establish every task field's accepted clear representation. Whole-record writes may use only representations reproduced by P12. | The P12 extension gates the task-write adapter. |
| Exact expired/revoked/wrong-scope auth mapping | Only malformed bearer is currently established. Unknown shapes do not become `noAuthorization` by guess. | P11 and platform auth tests gate the affected Linux/Android slices. |
| Due encoder implementation | P9 establishes UTC-midnight spelling and the offset hazard. | Adapter contract tests must reproduce P9 before admission. |
| `webViewLink` presence and recurrence navigation | This does not affect core sync. | P10 gates only the recurrence-management UX slice. |
| Full rate-limit/transient-error matrix | Use reason-aware conservative backoff and show the observed failure immediately. Unknown shapes fail closed. | Quota-safe observation may expand the adapter later; deliberate quota exhaustion is forbidden. |
| Unexpected/malformed success bodies | Strict decoding fails the affected scope; it never invents server behavior. | Synthetic P12 fixtures gate decoder behavior. |

## Evidence quality conclusion

Current primary documentation remains strongest for resource shape and method
surface. The controlled runs now provide current evidence for task versus list
preconditions, non-atomic pagination, deletion/cascade behavior, replay effects,
stable-ID cross-list movement, completion cascades, UTC due normalization, one
auth failure, and one quota response.

The evidence sharply reduces capability uncertainty but does not itself invent
policy. The accepted synchronization specification records possible duplication
for an uncertain create, server-authoritative uncloseable races, non-atomic
pagination semantics, and task-list delete recovery explicitly. Auth cases
beyond malformed bearer, optional-field clearing, stale-source task DELETE, and
recurrence navigation remain named implementation gates.
Historical Rust claims are accepted only where the new results reproduce them,
and the deleted-tombstone mutation claim is explicitly superseded by the
contradictory current observation.
