# Database schema version 1

Schema version 1 is the first intentional Axiotask SQLite format. It contains
the account-scoped Google cache foundation; there is no migration from an older
Axiotask implementation or from the earlier development-only `accounts` proof.
An existing file must match the exact version-1 schema digest, pass SQLite
integrity checking, and have no foreign-key violations before Drift opens it.
Unknown, modified, or corrupt files are preserved and rejected rather than
replaced with an empty cache.

## Tables

| Table | Responsibility |
|---|---|
| `accounts` | Stable local account key and unique verified Google subject. No email address or credential is stored. |
| `task_lists` | Materialized list projection with a stable local key, account key, separate nullable Google ID, title, and supported/deleted/unsupported projection boundary. |
| `tasks` | Materialized task projection with stable local/account/list/parent keys, separate nullable Google ID, supported content, date-only due epoch day, opaque Google position, and projection boundary. |
| `task_list_remote_bases` | Last confirmed list content, Google identity/version metadata, and the publication that observed it. |
| `task_remote_bases` | Last confirmed supported task content, structure, lifecycle, links, Google identity/version metadata, and the publication that observed it. |
| `scope_completeness` | Account list-enumeration or per-list task-enumeration page-chain state, including the opaque next-page token while incomplete. |
| `account_preferences` | Relational account settings, initially the sync-enabled control and an optional account-owned default list reference. |
| `sync_facts` | Account-scoped last verified success, newest failure, unresolved-work counts, reauthorization/retry/scope/follow-up facts used by the truthful health projection. Runtime authorization, connectivity, and active phase remain injected observations rather than durable guesses. |
| `task_list_preferences` | Account/list-owned sidebar order and smart-view exclusion storage. |
| `view_preferences` | Account/view-owned sort and completion-filter storage. |

The preference tables establish relational storage only. Their typed
application adapter and device-only preferences remain the S22A slice.

## Invariants

- Every cache, remote-base, completeness, and relational-preference row carries
  or derives an `account_id`. Composite foreign keys prevent a task, parent,
  remote base, or preference from attaching to another account or list.
- Repository reads require an `AccountId`; every list/task predicate and join is
  constrained by that account. There is no unscoped task read API.
- Local list/task IDs are SQLite-assigned 64-bit identities. Google IDs are
  separate external values, unique by account and resource type. Binding a
  Google ID does not replace the local ID.
- Google IDs are nullable in the schema because later durable-create intent
  needs a provisional identity. S10 exposes no create command or desired-state
  table, so a row without a Google ID is retained but cannot enter a repository
  snapshot and cannot behave as a local-only resource.
- A task parent must be in the same account and list. Cache writes reject a
  parent that is already a child, so the supported projection has only a top
  level and one subtask level.
- Remote bases are separate from materialized projections. Updating projected
  content or structure cannot silently overwrite the historical agreement
  point; a task base may retain its confirmed source list while its projected
  row targets another account-owned list.
- Live task bases require title, status, and position; tombstone bases may
  retain only fields Google supplied. Date-only due values are integer UTC
  epoch days, and task-link JSON and absolute URIs are strictly decoded.
- Unsupported/deleted/provisional projection rows are preserved but excluded
  from ordinary snapshots. A read never flattens, repairs, deletes, or exposes
  them as supported tasks.
- Page-chain completeness is account-scoped and keyed uniquely even for the
  account-wide list scope. It becomes complete only when its next-page token is
  absent. Aggregate cache completeness requires the list scope and every
  selected supported list scope from the same publication walk to be complete.
- `CacheCompleteness.complete` means only that a recorded page walk terminated.
  Every `CachedTasksSnapshot` is explicitly `unverifiedCache`; it supplies no
  last-success, authorization, connectivity, pending-work, or freshness fact
  and therefore can never establish healthy synchronization.
- `sync_facts.last_successful_sync_at` is written only for a completed required
  synchronization. Failure reason/time/diagnostic/action are one nullable unit;
  unresolved counts are non-negative. Missing rows mean no success, failure, or
  unresolved work, never implicit freshness. `account_preferences.sync_enabled`
  is joined into the same account-scoped projection.
- S13B Stop/Resume updates only `account_preferences.sync_enabled` in one
  account-scoped transaction. It does not delete or rewrite cache rows, remote
  bases, health evidence, unresolved counts, account identity, or credentials.
- An S12A read run uses its opaque publication ID as the durable page-walk
  identity. Begin marks the required scope incomplete, every page transaction
  replaces only that scope's token/completeness evidence, and finalization
  advances `sync_facts.last_successful_sync_at` only after the list scope and
  every list selected by that publication have terminal task scopes. An
  interrupted or failed publication remains incomplete and retains the prior
  success time and previously valid cache rows.
- SQLite foreign keys remain enabled and multi-row writes use explicit
  transactions. Failed transactions may re-emit an unchanged Drift snapshot,
  but cannot expose or retain partially written state.

OAuth tokens, DPoP keys, authorization headers, mutation attempts, desired
mutation payloads, diagnostics, and device-only preferences are not part of
these cache/health tables.
