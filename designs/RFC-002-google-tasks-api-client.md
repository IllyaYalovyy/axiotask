# RFC-002: Google Tasks API Client

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Define `GoogleTasksClient` — the single trait that abstracts the Google Tasks
v1 API. This is the **only** abstraction layer between the rest of the app and
Google's API, per VISION ("no abstraction layers between gui and backend api
(only for unit testing mocking)"). Provide a real `reqwest`-backed
implementation and an in-memory mock used by every sync/test scenario.

---

## Goals

- **G1** — A single trait covers all Tasks API operations the MVP needs: list tasklists, list tasks (paginated), insert, update, patch, delete, move (reorder).
- **G2** — Real implementation handles pagination, etag passthrough, `401`→refresh→retry (via [[RFC-001-auth-oauth-pkce]]), and `5xx` exponential backoff.
- **G3** — Mock implementation is the reference test double for [[RFC-004-sync-engine]] and Tauri command tests.
- **G4** — A single contract-test suite runs against **both** implementations to keep them in sync.

## Non-Goals

- **NG1** — Batch/`google-api-rust-client` integration.
- **NG2** — Caching at this layer (caching lives in the store, RFC-003).
- **NG3** — Surface-area beyond what the MVP UI needs (e.g., no shared task lists, no assignees).

---

## Background & Motivation

Sync engine, command handlers, and UI prototypes all need to talk to Google
Tasks. Without a mockable seam, tests would have to hit the live API — slow,
flaky, and ratelimited. The trait is also the **enforcement point** for the
"no other abstractions" rule: everything above this is direct; everything
below is hidden.

---

## Considered Options

### Option A — Hand-rolled trait + `reqwest`

**Pros**: Minimal dependencies. We use only the seven endpoints we need. Easy to mock.
**Cons**: We hand-write request/response types.

### Option B — `google-tasks1` from `google-apis-rs`

**Pros**: Generated bindings cover the whole API.
**Cons**: Huge surface area, generated types are awkward, harder to mock cleanly, slow compile.

### Option C — gRPC / protobuf bindings

**Pros**: Type safety.
**Cons**: Google Tasks is REST-only. Not applicable.

---

## Decision

**Chosen option: Option A.** Hand-rolled is a fit because the MVP touches a
small fraction of the API; the trait stays small and the mock stays cheap.

---

## Design

```rust
#[async_trait]
pub trait GoogleTasksClient: Send + Sync {
    async fn list_tasklists(&self) -> Result<Vec<TaskList>>;
    async fn list_tasks(&self, list_id: &str, page: Option<PageToken>) -> Result<Page<Task>>;
    async fn insert_task(&self, list_id: &str, new: NewTask) -> Result<Task>;
    async fn patch_task(&self, list_id: &str, id: &str, patch: TaskPatch) -> Result<Task>;
    async fn delete_task(&self, list_id: &str, id: &str) -> Result<()>;
    async fn move_task(&self, list_id: &str, id: &str, parent: Option<&str>, previous: Option<&str>) -> Result<Task>;
}
```

- **Pagination** handled inside the trait surface via `Page<T> { items, next_token }`. Callers iterate; the client does not auto-collect.
- **Errors** are a typed `enum ApiError { Unauthorized, NotFound, RateLimited { retry_after }, Conflict, Network(_), Other(_) }`. Sync engine matches on these.
- **Real impl** (`HttpClient`) wraps `AuthedClient` from RFC-001, applies exponential backoff for `5xx`/`429`, honors `Retry-After`.
- **Mock impl** (`InMemoryClient`) maintains an in-memory state machine, supports fault injection (`fail_next("delete_task", 503)`), and assigns monotonic etags so conflict tests are deterministic.

---

## Testing Strategy

- **Contract tests** — One module of `#[tokio::test]` functions parameterized over a `Box<dyn GoogleTasksClient>`; both `HttpClient` (with `wiremock`) and `InMemoryClient` run the same suite.
- **Real-impl-only** — Pagination edge cases, `Retry-After` parsing, JSON shape compatibility (snapshot tests with `insta`).
- **Mock-impl-only** — Fault-injection mechanics, deterministic etag generation.

---

## Development Plan

- [ ] **Step 1** — Domain types: `TaskList`, `Task`, `NewTask`, `TaskPatch`, `Page<T>`, `ApiError` *(prerequisite: RFC-001 Step 6)*
- [ ] **Step 2** — `GoogleTasksClient` trait *(prerequisite: Step 1)*
- [ ] **Step 3** — `InMemoryClient` *(prerequisite: Step 2)*
- [ ] **Step 4** — Contract test harness *(prerequisite: Step 3)*
- [ ] **Step 5** — `HttpClient` real impl *(prerequisite: Step 2)*
- [ ] **Step 6** — Backoff/retry layer *(prerequisite: Step 5)*
- [ ] **Step 7** — Live-API smoke test, env-gated *(prerequisite: Step 5)*

---

## Open Questions

- [ ] **Q1** — Do we model `position` (Google's lex-sortable string) opaquely, or parse it? Opaque is safer.
- [ ] **Q2** — Should `move_task` be expressed as `patch_task` + `parent`/`previous` params, matching the API's `/move` endpoint?
- [ ] **Q3** — How do we surface partial-page failures from `list_tasks` — fail the whole iteration or yield what we have?
