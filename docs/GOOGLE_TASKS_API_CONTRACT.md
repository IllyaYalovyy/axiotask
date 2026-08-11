# Google Tasks API contract evidence

Research snapshot: 2026-08-09. This document records the externally observable
Google Tasks API behavior on which Stage 4 synchronization may depend. It is an
evidence inventory, not a synchronization policy.

The primary machine-readable source was the official
[Tasks API discovery document](https://www.googleapis.com/discovery/v1/apis/tasks/v1/rest),
revision `20260804`, retrieved on 2026-08-09. Human-readable Google documentation
is linked at each claim. Documentation can change independently of this file, so
the discovery revision and research date are part of the evidence.

No live probe was run for this research pass, and no credentials or personal
task data were inspected. Dedicated existing development credentials outside
the repository have since been approved for the controlled probe plan below.
Consequently, this document does not yet label any claim **Observed by a
controlled probe**. Historical Rust probes are useful leads only and are
explicitly marked for reverification.

## Evidence labels

| Label | Meaning in this document |
|---|---|
| **Officially documented** | Stated by current primary Google documentation or the current official discovery document. |
| **Observed by a controlled probe** | Reproduced during this research pass with disposable data and sanitized evidence. No rows currently have this label. |
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
| `id` | Task identifier. | **Officially documented** | Remote task identity within its account/list context; cross-list stability remains unknown. |
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
| Snapshot isolation across pages | Google does not state that page tokens represent one immutable snapshot or define behavior when resources change between pages. | **Unknown** | A controlled concurrent-mutation probe is required before claiming one run is an atomic snapshot. |
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
| Reorder/reparent | `tasks.move` returns the moved task. Omit `parent` for top level; omit `previous` for first among its siblings. Named parent/previous must exist in the relevant list and must not be hidden. | **Officially documented** | Response adoption is possible, but ID/ETag/position changes need current observation. |
| Cross-list move | `destinationTasklist` moves a task to another list. Repeating tasks cannot be moved between lists. | **Officially documented** | Identity stability, descendant handling, and atomicity are not documented. |
| Position ordering | Positions are opaque strings; their lexicographic comparison orders siblings. | **Officially documented** | Only relative sibling comparison is contractual. |
| Position generation | The server’s allocation/rebalancing algorithm is not documented. | **Unknown** | Do not infer arithmetic or stability properties from one observed position format. |
| Previous-sibling errors | The method documents validity constraints, but not status codes when `previous`, `parent`, or the subject disappears concurrently. | **Unknown** | Exact error classification and recovery require probes. |
| Task conditional mutation | Task and list resources contain ETags. The Tasks performance guide gives a generic `If-Match` example for APIs that use ETags, but does not state which Tasks endpoints honor it or their exact stale response. | **Unknown** | Patch/update/delete/move must each be probed before a conflict guarantee uses `If-Match`. |
| List conditional mutation | No Tasks endpoint page defines stale-ETag behavior for rename or delete. | **Unknown** | List rename/delete conflict detection cannot be claimed. |
| Successful mutation response | Insert, patch, update, and move document a resource response; delete documents an empty response. | **Officially documented** | Google does not guarantee that every echoed field is canonical beyond the resource schema. |
| Lost response after mutation | Google does not document a mutation-status lookup, operation ID, or exactly-once receipt for Tasks. | **Unknown** | A transport failure can leave whether the server committed unresolved. Each mutation class needs a probe/reconciliation design. |
| Duplicate-create prevention | Insert exposes no request ID, idempotency key, conditional-create parameter, or client-selected resource ID in discovery revision `20260804`. | **Inference** | No public duplicate-prevention capability is visible; behavior after retrying an uncertain create must be probed. |
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
| Tombstone shape/retention | Google does not document which other fields remain, direct-GET behavior, or retention duration. | **Unknown** | Tombstone shape and retention require a controlled probe. |
| Parent deletion | The delete method does not document whether subtasks are deleted, detached, hidden, or otherwise transformed. | **Unknown** | Descendant reconciliation cannot rely on a cascade until reverified. |
| List tombstone surface | The task-list collection exposes no documented deletion marker or `showDeleted` parameter. | **Inference** | No public list-tombstone capability is visible in discovery revision `20260804`. |
| List-deletion aftermath | The delete method returns no body; subsequent task visibility and repeated-delete behavior are not documented. | **Unknown** | Disappearance detection and task behavior after list deletion require a probe. |
| Parent/subtask creation | `tasks.insert` accepts a `parent`; omitting it creates a top-level task. Assigned tasks cannot be parents or children. | **Officially documented** | Supports the product’s single subtask level. Exact missing/hidden-parent failures require probes. |
| Parent/subtask move | `tasks.move` changes `parent`; completed hidden tasks, assigned tasks, and repeating tasks have documented nesting restrictions. | **Officially documented** | Product scope remains exactly one subtask level regardless of deeper undocumented/legacy behavior. |
| Subtask count | `tasks.move` documents a maximum of 2,000 subtasks per task. | **Officially documented** | The product must not assume a larger supported sibling set. |
| Completion cascade | Current method/resource documentation does not define whether completing, reopening, moving under, or inserting under a completed parent changes descendants. | **Unknown** | All supported parent/subtask completion transitions require probes. |
| Clear completed | `tasks.clear` marks completed tasks in the list as hidden and returns an empty body. | **Officially documented** | Complete enumeration must account for hidden tasks. Exact field/ETag changes are unknown. |
| Due date | `due` accepts an RFC 3339 representation but stores only a date; time is discarded and unavailable through the API. | **Officially documented** | No time-of-day or deadline can be synchronized through this API. |
| Due timezone/canonical echo | Google does not specify the canonical returned offset, fractional precision, normalization zone, or behavior for every valid offset. | **Unknown** | Probe multiple offsets and date-boundary cases; compare semantic dates, not an unverified wire spelling. |
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
| Tasks authentication response | The exact status/body/header matrix for expired, revoked, wrong-scope, or malformed bearer tokens is not documented on Tasks endpoint pages. | **Unknown** | Controlled probes are required to map failures without relying on message text. |
| Daily quota | Courtesy limit is 50,000 queries/day; Google warns that projects may have different quotas visible in Cloud Console. | **Officially documented** | The public number is not a complete per-project runtime limit. |
| Per-minute/user limits | No Tasks-specific public contract was found for per-minute, per-user, or burst limits. | **Unknown** | Runtime status and headers must be captured in a controlled quota-safe probe if possible. |
| Rate-limit response | Tasks documentation does not promise an exact HTTP status, error reason, or `Retry-After` header. | **Unknown** | Do not make a Tasks-specific retry claim from another Google API’s documentation. |
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
| Deleted tasks remained directly readable with `deleted=true`; PATCH of a deleted task returned a success echo while the stored tombstone remained unchanged. | **Inherited historical evidence needing reverification** | Delete/edit races and the danger of trusting a mutation echo alone. |
| A full timestamp due value was normalized to midnight UTC; an empty string cleared due; a bare date was rejected. | **Inherited historical evidence needing reverification** | Exact due wire encoding, which current documentation does not fully specify. |
| Unknown parent, field-size boundaries, and invalid due values produced permanent 4xx errors. | **Inherited historical evidence needing reverification** | Validation classification without relying on message strings. |

These claims must not be copied into the new fake, synchronization engine, or
tests as current truth until the controlled probes below reproduce them.

## Controlled probe plan

### Safety and reproducibility setup

The next probe run must use a dedicated Google test account and a dedicated OAuth
client authorized only for the Tasks scope. Credential and token files must be
outside this repository. The operator must verify the account identity before
the first write. No probe may enumerate or mutate a normal application account.

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
| P6: uncertain non-create mutations | For patch/delete/move/list rename, allow the server to receive the request while the client discards the response, then read back before any retry; separately retry an identical request. | Final resource state, ETag/updated changes, duplicate effects, and repeated-delete/move responses. | Delete scratch list. |
| P7: move and order | Reorder first/middle/last; reparent; use stale/deleted/missing `previous`; move parent/child across lists; inspect response and both lists. | ID stability, descendant behavior, ETag/updated/position changes, exact statuses, and relative order. | Delete both lists. |
| P8: parent/completion | Complete/reopen parent and child in each order; insert/move an open child under a completed parent; clear completed tasks. | Response versus refetched states, cascade direction, timestamps, ETags, hidden/deleted flags. | Delete scratch list. |
| P9: due dates | Insert/patch offsets around UTC date boundaries, fractional/no-fraction timestamps, bare dates, invalid dates, `null`, and empty string. | Status, canonical echo, refetched value, and semantic date. | Delete scratch list. |
| P10: recurrence/Web UI link | In the dedicated account only, manually create one ordinary and one recurring task in current Google UI. Retrieve both without changing recurrence. | Presence/shape of `webViewLink`, API field differences, and whether opening the link reaches the intended task-management UI. No claim based on hidden fields. | Delete both tasks/series in Google UI and scratch list. |
| P11: auth failures | Against an empty disposable list, use an expired access token, revoked/invalid refresh token in the OAuth layer, insufficient scope, and malformed bearer token. | Status, stable structured error fields, and headers; redact all token material and message text that contains identifiers. | Revoke only the dedicated probe grant if required; delete list first. |
| P12: validation and parser fixtures | Send representative oversized/invalid writable fields. Separately feed locally stored synthetic truncated JSON, wrong types, missing fields, and unknown fields to the future adapter tests; do not attribute synthetic fixtures to Google. | Endpoint statuses and unchanged/changed resource state; decoder result for synthetic fixtures. | Delete scratch list. |

Do not intentionally exhaust the 50,000-query courtesy quota to manufacture a
rate-limit response. If normal quota-safe probing encounters throttling, record
the sanitized status, structured reason, and `Retry-After` presence. Otherwise
rate-limit response details remain Unknown.

## Remaining unknowns and specification blockers

| Unknown | Stage 4 effect | Blocks synchronization specification? |
|---|---|---|
| Conditional semantics for task PATCH/UPDATE/DELETE and list PATCH/DELETE | Determines which concurrent writes can be detected rather than overwritten. | **Yes — P1/P2.** |
| No documented idempotency key or create lookup after a lost response | Determines whether an uncertain create can be retried without duplicates and how it can be reconciled. | **Yes — P5.** |
| Pagination behavior under concurrent mutations and page-token interruption | Determines whether anything stronger than “all documented pages were consumed” can be claimed. | No for the conservative foundation, which assumes no atomic snapshot and never deletes from listing absence alone. P3 is required before adopting stronger absence handling. |
| Tombstone field shape/retention, parent-delete cascade, and list-deletion aftermath | Determines reliable deletion detection and hierarchy cleanup. | **Yes — P4.** |
| Cross-list move identity, descendant behavior, and uncertain-response behavior | Determines whether a move is one recoverable mutation or requires a different model. | **Yes — P6/P7.** |
| Parent/completion cascade semantics | Determines convergence for the supported task/subtask relationship. | **Yes — P8.** |
| Exact auth-failure mapping | Determines when the system has lost authorization versus encountered a retryable request failure; truthful sync health depends on the distinction. | **Yes — P11.** |
| Exact due wire normalization | A date-only domain is documented, but encoder/decoder fixtures need a verified spelling. | No; P9 is required before adapter implementation. |
| `webViewLink` presence and recurrence navigation | Affects the recurrence-management escape hatch, not core content synchronization. | No; P10 blocks that UX slice. |
| Tasks-specific `Retry-After`, rate-limit, and transient-error matrix | Affects retry timing and diagnostics. Safe probe may not be able to force it. | No; it remains an explicit uncertainty in the specification. |
| Unexpected/malformed success bodies | Server occurrence is unknowable; adapter behavior can be defined and tested with synthetic fixtures. | No; P12 informs strict adapter tests. |

## Evidence quality conclusion

Current primary documentation is strong for resource shape, supported methods,
filters, pagination mechanics, list/task limits, date-only due semantics,
completed/hidden visibility, and the existence of the Google UI recurrence
feature. It is weak for synchronization-critical concurrency, atomic listing,
deletion retention, uncertain mutation outcomes, endpoint-specific failures, and
retry hints.

The historical Rust probes identify precise questions and credible prior
outcomes, but they are not accepted as current facts because this pass neither
reproduced them nor found sanitized raw output suitable for independent review.
The synchronization specification must not begin by silently assuming answers
to the rows marked as blockers.
