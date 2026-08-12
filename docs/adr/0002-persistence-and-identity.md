# ADR 0002: Drift/SQLite persistence and stable local identity

- Status: Accepted
- Date: 2026-08-09

## Problem

Offline edits, uncertain remote outcomes, base state, account isolation,
preferences, and sync health must survive crashes atomically. Google assigns a
task ID only after create, so using the remote ID as UI/local identity couples
sync to open editors and navigation.

## Alternatives considered

1. Key/value storage plus JSON snapshots. Simple, but weak transactions,
   querying, referential integrity, and crash recovery.
2. Raw `sqlite3` with handwritten mapping. Maximum control, with substantial
   repetitive mapping/migration/reactivity code in a correctness-critical area.
3. Drift over SQLite with generated persistence types and explicit domain
   mapping.
4. An object database or generic offline-sync framework. Easier demos, but its
   lifecycle/conflict model becomes hidden product policy.

For preferences:

1. Put every setting in SQLite. One storage system, but it conflates disposable
   presentation choices with relational/account state.
2. Put every setting in a platform key-value store. Simple, but unsuitable for
   critical, relational, or account-scoped data.
3. Expose one typed preferences repository and select storage by semantics.

For identity:

1. Use Google's remote ID everywhere and replace provisional IDs after create.
2. Use a UUID local ID.
3. Use an opaque SQLite integer local key plus a separate nullable unique remote
   ID.

## Decision

Choose Drift/SQLite and identity option 3. Acknowledged mutations atomically
write visible state and one coalesced durable desired-state record per changed
resource. Every account, list, task, parent reference, UI selection, and
desired-state record uses stable local keys.
Remote IDs and etags are external metadata, never primary application identity.
Remote-key uniqueness is scoped by Google account and resource type.

The first schema supports multiple isolated account partitions, while the
initial application allows only one configured account and provides no account
switching UI. Future multi-account behavior must not require replacing local
identity or migrating unscoped task data.

Choose preference option 3. Account-scoped settings and preferences referencing
lists/views use SQLite. Small disposable device-presentation settings use
`SharedPreferencesAsync`. The application sees one typed
`PreferencesRepository`; no caller selects storage directly. Sync-critical
state never uses the preference plugin. Tokens use platform secure storage.

Run the production connection away from the UI isolate and inject connections
for tests. Use foreign keys and explicit transactions. Exact durability pragmas
remain gated on implementation experiments; the synchronization schema must
satisfy the accepted Stage 4 specification.

Do not encrypt the whole cache initially. The platform sandbox/user boundary is
the stated cache threat model; secrets are stored separately. SQLCipher's native
and key-recovery failure modes do not currently earn their cost. Revisit if
encrypted task content at rest becomes a product requirement or the threat
model changes.

## Rationale

SQLite supplies the transactions and referential integrity required for durable
offline continuity, while Drift reduces mapping, migration, and reactive-query
risk. Stable local identity prevents remote creation or synchronization from
invalidating UI references. Selecting preference storage by semantics keeps
critical account state transactional without treating disposable presentation
settings as database domain data.

## Consequences

- Creating a remote object never invalidates widget/view-model identity.
- UI editing state is irrelevant to synchronization.
- Multiple account partitions can be added without cross-account mixing even
  though the initial UI exposes only one configured account.
- Drift generation and row/domain mapping are accepted costs.
- A second lightweight preference adapter is accepted, but its scope is narrow
  and its failures can only reset non-critical presentation defaults.
- Database open/corruption behavior must be explicitly tested; no empty-store
  fallback is permitted.
- SQLite-assigned keys are installation-local by design. Confirmed records map
  through account-scoped Google IDs; provisional creates remain intentionally
  installation-local until Google returns an ID.
