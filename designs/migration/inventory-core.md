# axiotask-core migration inventory
Crate root: <reference-repo>/crates/axiotask-core
Generated 2026-08-06 from branch task-129-android-auth-play-services. Paths are relative to the crate root.

## src/lib.rs (15)
PURPOSE: Crate root: declares modules (api, auth, config, dates, error, export, model, store, sync); no UI dependency.
PUBLIC SURFACE:
- pub mod api, auth, config, dates, error, export, model, store, sync
- pub use error::{Error, Result} — crate-wide error re-export
TESTS (in-file #[cfg(test)]): none
NOTES: Doc comment states the crate contract: "No UI framework dependency. Pure logic, fully testable."

## src/error.rs (34)
PURPOSE: Crate-wide error enum wrapping each subsystem's error type.
PUBLIC SURFACE:
- type Result<T, E = Error> — result alias used throughout crate
- enum Error — variants: Api(ApiError), Auth(AuthError), Store(StoreError), Sync(SyncError), Json(serde_json::Error), Other(String); all #[from] transparent except Json/Other
TESTS (in-file #[cfg(test)]): none
NOTES: Pure thiserror plumbing; port as a sealed union of subsystem errors.

## src/model.rs (260)
PURPOSE: Domain types shared by API, store, and sync (API-shape and store-shape in one module).
PUBLIC SURFACE:
- struct TaskList {id, title, etag: Option, updated} — a Google Tasks task list
- struct Task {id, parent: Option, position, title, notes: Option, status, due: Option, completed: Option, etag: Option, updated, web_view_link: Option (serde rename "webViewLink"), deleted: bool} — a task; serde skips None fields; deleted skipped when false
- enum TaskStatus {NeedsAction, Completed} — serde camelCase
- TaskStatus::as_api_str(self) -> &'static str — "needsAction"/"completed" wire form
- TaskStatus::parse_api(&str) -> Option<Self> — parse wire form, None on unknown
- struct BaseSnapshot {title, notes: Option, due: Option, status} — content as of last server agreement (RFC-009 §B/§G, #124)
- BaseSnapshot::of(&Task) -> Self — snapshot task's current content as new base
- struct NewTask {title, notes?, due?, status?, parent?, previous?} — insert_task payload; server fills rest
- struct TaskPatch {title?, notes?, due?, status?} — sparse patch; Some("") clears notes/due
- TaskPatch::is_empty(&self) -> bool — true when no fields set
- struct Page<T> {items: Vec<T>, next_page_token: Option<String>} — one page of a list response
TESTS (in-file #[cfg(test)]):
- task_status_round_trips_through_api_strings — status wire-string round trip; unknown rejected
- empty_patch_is_detected_as_empty — is_empty true only for default patch
- task_serializes_with_camel_case_status — camelCase status; None parent skipped
- task_deserializes_web_view_link_from_google_field — webViewLink maps in; absent → None
NOTES: `deleted` is meaningful ONLY on a by-id refetch (soft-deleted task answers 200 with deleted:true, verified live, RFC-009 §B/§D); powers 412-refetch delete-wins (P4); stored/listed rows always deleted=false — locally deleted rows are hard-removed, never tombstoned. BaseSnapshot holds exactly the user-content fields (title/notes/due/status), nothing structural; it is what distinguishes "only we changed" from "server changed too" (#118 bare-reorder etag bump; #122 orphan adoption). Ports 1:1.

## src/dates.rs (256)
PURPOSE: Pure date arithmetic for one-keystroke due-date moves (RFC-008) plus due-string canonicalization and UTC now-stamps; no IO.
PUBLIC SURFACE:
- fn normalize_due(raw: &str) -> Option<String> — canonicalize due to Google's exact `YYYY-MM-DDT00:00:00.000Z`
- fn now_utc_string() -> String — true-UTC RFC-3339 now with microsecond precision (single source for local_updated)
- enum DateMove {Today, Tomorrow, NextWeek, NextMonth, Clear} — requested one-keystroke move
- fn apply_date_move(today: Date, mv: DateMove) -> Option<Date> — apply move; None means clear
- (private) fn next_month_clamped(today: Date) -> Date — +1 month clamped to month-end
TESTS (in-file #[cfg(test)]):
mod tests:
- today_returns_same_date — Today is identity
- tomorrow_advances_one_day — +1 day
- tomorrow_crosses_month_boundary — Jan 31 → Feb 1
- next_week_is_plus_seven_days — +7 days
- next_month_clamps_at_february — Jan 31 → Feb 28
- next_month_uses_leap_february_when_applicable — leap year → Feb 29
- next_month_crosses_year — Dec 30 → Jan 30 next year
- next_month_clamps_at_30_day_month — Mar 31 → Apr 30
- clear_returns_none — Clear yields None
- applying_tomorrow_twice_is_two_days_apart — moves compose
mod normalize_tests:
- bare_date_becomes_full_form — YYYY-MM-DD gains T00:00:00.000Z
- seconds_only_form_gains_millis — ...T00:00:00Z gains .000
- canonical_form_is_unchanged — idempotent
- nonzero_time_is_floored_to_date — time component discarded
- garbage_is_rejected — empty/words/invalid dates → None (Feb 30 rejected, not clamped)
- import_uses_the_leading_ten_chars_and_floors_the_rest — prefix-based; trailing junk/tz discarded; leading junk rejected
- short_or_multibyte_input_returns_none_without_panicking — byte-indexed get(..10) never panics
- now_utc_string_has_z_and_micros — Z suffix, micro precision, consecutive calls differ
NOTES: Google rejects bare `YYYY-MM-DD` with 400 and normalizes accepted timestamps to `.000Z` (verified live) — normalize_due is what stops phantom due mismatches. now_utc_string's sub-second precision guards the push mark-clean race (dirty flag cleared only when local_updated equals drained snapshot); a `Zoned::now()`+literal-Z would mislabel local time as UTC (issue #47). Uses jiff. Ports 1:1.

## src/config.rs (465)
PURPOSE: App configuration (TOML) with instance isolation via AXIOTASK_PREFIX and comment-preserving [sync] persistence.
PUBLIC SURFACE:
- const APP_NAME: &str = "axiotask" — base app dir name
- const INSTANCE_ENV: &str = "AXIOTASK_PREFIX" — env var selecting an isolated instance
- (private) fn sanitize_prefix(&str) -> Result<String, String> — ASCII alnum/-/_ ≤64 chars; blocks path traversal
- fn instance_prefix() -> Option<String> — active prefix; PANICS on invalid value (never silently falls back to production)
- fn app_dir_name() -> String — "axiotask" or "axiotask-<prefix>"
- (private) fn app_dir_name_for(Option<&str>) -> String — pure helper
- fn config_path_in(base: &Path) -> PathBuf — `base/<app-dir>/config.toml`; shared by desktop (dirs::config_dir) and Android (Tauri app_config_dir, #170)
- struct AppConfig {google: GoogleConfig, sync: SyncConfig} — serde(default)
- struct GoogleConfig {client_id, client_secret, scopes} — default: empty creds, tasks scope
- struct SyncConfig {push_enabled, auto_sync_on_start} — default: push OFF, auto-sync ON
- AppConfig::load() -> Self — from default path or defaults
- AppConfig::load_from(&Path) -> Option<Self> — parse a specific file
- AppConfig::default_path() -> PathBuf — instance-aware XDG path (desktop only in practice)
- AppConfig::write_default_if_missing() — seed default file at default path
- AppConfig::write_default_if_missing_at(&Path) — seed at given path, never overwrite
- AppConfig::default_toml() -> &'static str — embedded ../config.default.toml template
- AppConfig::save_sync_to(&Path, &SyncConfig) -> io::Result<()> — toml_edit write preserving comments and [google]
- AppConfig::save_sync(&SyncConfig) -> io::Result<()> — save to default path
TESTS (in-file #[cfg(test)]):
- app_dir_name_default_and_prefixed — prefix maps to axiotask-<p>
- config_path_in_roots_the_shared_config_layout_under_the_given_base — same subtree under any base (desktop/mobile)
- sanitize_prefix_accepts_safe_names — alnum/-/_ accepted
- sanitize_prefix_rejects_unsafe_names — empty/traversal/separators/space/dot/overlength rejected
- default_google_config_has_empty_credentials — no baked creds
- default_google_config_has_tasks_scope — tasks scope default
- default_sync_config_has_push_disabled — push off by default
- default_sync_config_has_auto_sync_enabled — auto-sync on by default
- load_from_missing_file_returns_none — missing file → None
- load_from_valid_toml — full parse round trip
- load_from_partial_toml_uses_defaults — serde(default) fills gaps
- write_default_creates_file_when_missing — template seeded with sections
- write_default_does_not_overwrite_existing — existing file untouched
- default_toml_is_parseable — embedded template parses
- save_sync_round_trips_values — saved values reload
- save_sync_preserves_credentials_and_comments — toml_edit keeps user file intact
- save_sync_creates_file_from_template_when_missing — creates from template incl. comments
TESTS use tempfile::TempDir.
NOTES: instance_prefix PANIC-on-invalid is deliberate — silent fallback would point a "isolated" instance at production data (see MEMORY isolate-from-production-data). Android must call config_path_in with Tauri's app_config_dir or preferences never save (#170). save_sync_to falls back to the embedded template if existing file is malformed. Template file config.default.toml lives at crate root and is include_str!'d.

## src/export.rs (548)
PURPOSE: Pure (no-IO) lossless JSON backup/export of the full local store — lists, tasks, and all sync metadata — plus the inverse restore.
PUBLIC SURFACE:
- const BACKUP_VERSION: u32 = 1 — schema version; readers refuse unknown versions
- const BACKUP_APP: &str = "axiotask" — self-describing producer name
- struct Backup {version, app, exported_at, lists: Vec<BackupList>} — root document
- struct BackupList {id, title, etag?, updated, local_only, sync_state: String, local_updated, pending_op?, tasks: Vec<BackupTask>} — list + sync metadata + nested tasks
- struct BackupTask {id, parent?, position, title, notes?, status: String, due?, completed?, etag?, updated, sync_state: String, local_updated, pending_op?} — task with every field verbatim
- Backup::build(exported_at, Vec<(StoredTaskList, Vec<StoredTask>)>) -> Self — assemble from store rows, order preserved
- Backup::to_json_pretty(&self) -> Result<String, serde_json::Error> — pretty print
- Backup::from_json(&str) -> Result<Self, _> — parse; unknown fields ignored (forward-compatible)
- Backup::into_stored(self) -> Vec<(StoredTaskList, Vec<StoredTask>)> — exact inverse of build; unknown enum strings degrade (sync_state→Clean, status→NeedsAction)
- Backup::task_count(&self) -> usize — total tasks across lists
- (private) BackupTask::from_stored(&StoredTask) -> Self; BackupList::into_stored(self); BackupTask::into_stored(self, list_id)
TESTS (in-file #[cfg(test)]):
- build_sets_envelope_metadata — version/app/exported_at set
- build_preserves_lists_and_nested_tasks_in_order — order and local_only preserved
- task_exports_every_field_with_no_loss — all 13 task fields exported
- list_exports_all_sync_metadata — list sync_state/pending_op exported
- task_notes_are_kept_verbatim — multiline notes untouched
- json_is_pretty_and_round_trips — pretty, self-describing, lossless
- unknown_future_fields_are_ignored_on_read — forward compatibility
- from_json_parses_a_backup_document — parse inverse of serialize
- from_json_rejects_malformed_input — garbage errors
- into_stored_is_the_inverse_of_build — byte-identical store rows restored
- into_stored_round_trips_through_json — restored tasks tagged with list_id
- into_stored_degrades_unknown_enums_safely — unknown enums → safe defaults, no panic
NOTES: Couples to store::{StoredTask, StoredTaskList, SyncState} and model types. Enum fields serialized as wire strings (as_api_str / SyncState::as_str) so the JSON is human-readable. Restore sets web_view_link=None and deleted=false (not exported). Callers own file IO and the exported_at timestamp. Ports 1:1.

## src/api/mod.rs (17)
PURPOSE: API module root: declares the client trait and its two implementations.
PUBLIC SURFACE:
- pub use ApiError, HttpClient, InMemoryClient, GoogleTasksClient (in_memory is a pub mod)
TESTS (in-file #[cfg(test)]): none
NOTES: Doc states the VISION rule: GoogleTasksClient is the ONLY abstraction between the app and Google's API; InMemoryClient is a fully-behaving test double kept in step with HttpClient (wiremock-tested).

## src/api/error.rs (76)
PURPOSE: Typed API errors the sync engine matches on to decide retry/refresh/give-up.
PUBLIC SURFACE:
- enum ApiError — Unauthorized (refresh+retry once), AuthExpired(String) (invalid_grant: permanent, sign in again), NotFound, PreconditionFailed (etag mismatch: pull+merge+retry), RateLimited (Retry-After honored in http.rs), Server{status: u16}, Network(String), Other(String)
- ApiError::is_transient(&self) -> bool — true for RateLimited | Server | Network
TESTS (in-file #[cfg(test)]):
- transient_classification — exactly RateLimited/Server/Network transient; all others not
NOTES: AuthExpired vs Unauthorized split is load-bearing: Unauthorized = recoverable refresh signal, AuthExpired = dead session → needs_reauth UI state. Sync engine and scheduler both branch on these variants.

## src/api/traits.rs (62)
PURPOSE: The sole abstraction layer between the app and Google Tasks v1 (async_trait).
PUBLIC SURFACE (trait GoogleTasksClient: Send + Sync):
- async fn list_tasklists() -> Result<Vec<TaskList>, ApiError> — all visible task lists
- async fn insert_tasklist(title) -> Result<TaskList, _> — create list, returns server view
- async fn patch_tasklist(id, title) -> Result<TaskList, _> — rename list
- async fn delete_tasklist(id) -> Result<(), _> — delete list (server cascades tasks)
- async fn list_tasks(list_id, page_token: Option<&str>) -> Result<Page<Task>, _> — one page of tasks
- async fn insert_task(list_id, NewTask) -> Result<Task, _> — create task, server fills etag/position
- async fn get_task(list_id, id) -> Result<Task, _> — single-task refetch; NotFound if gone
- async fn patch_task(list_id, id, TaskPatch, etag: Option<&str>) -> Result<Task, _> — sparse update; Some(etag) sends If-Match → PreconditionFailed on conflict
- async fn delete_task(list_id, id) -> Result<(), _> — delete task
- async fn move_task(list_id, id, parent: Option<&str>, previous: Option<&str>) -> Result<Task, _> — reparent/reorder
TESTS (in-file #[cfg(test)]): none
NOTES: "The MVP needs exactly these — adding methods here is the canonical extension point." Any port must keep the If-Match/etag semantics on patch_task and the paginated list_tasks shape.

## src/api/http.rs (1143)
PURPOSE: reqwest-backed `GoogleTasksClient` for Google Tasks v1 REST: URLs, (de)serialization, status→ApiError mapping, pagination, backoff.
PUBLIC SURFACE:
- HttpClient (struct: AuthedClient + base_url + max_retries) — HTTP-backed Google Tasks client
- HttpClient::new(auth: AuthedClient) -> Self — construct against real Google endpoint, 4 retries
- HttpClient::with_base_url(auth, base_url: impl Into<String>) -> Self — construct against arbitrary base URL (wiremock tests)
- HttpClient::with_max_retries(self, n: u32) -> Self — builder: override/disable retry count
- HttpClient::send_authed(&self, req closure) -> Result<Response, ApiError> (private) — retry wrapper; on 401 refresh token, retry once; Denied→AuthExpired, Transient→Network
- TaskListsResponse (private Deserialize) — wire page: items + nextPageToken for lists
- TaskListWire (private Deserialize) — wire shape of a tasklist (optional etag/updated)
- impl From<TaskListWire> for TaskList (fn from) — wire→model; missing updated becomes empty string
- TasksResponse (private Deserialize) — wire page: items + nextPageToken for tasks
- TaskWire (private Deserialize) — wire task; webViewLink renamed; almost all fields optional
- impl TryFrom<TaskWire> for Task (fn try_from) — wire→model; unknown status → ApiError::Other; defaults for missing fields
- map_status(StatusCode) -> ApiError (private) — status mapping with empty body
- map_status_with_body(StatusCode, body: &str) -> ApiError (private) — 401→Unauthorized, 403 body-split rate-limit/permanent, 404→NotFound, 409|412→PreconditionFailed, 429→RateLimited, 5xx→Server
- is_rate_limit_body(&str) -> bool (private) — detects rateLimitExceeded/userRateLimitExceeded/quotaExceeded/dailyLimitExceeded substrings
- body_reason(&str) -> String (private) — extract error.message from JSON body, else "permission denied"
- retry_after_from(&HeaderMap) -> Option<Duration> (private) — parse integer-seconds Retry-After header
- send_with_retry(max_retries, req closure) -> Result<Response, ApiError> (private) — loop: retry transient errors/network failures; honor Retry-After else exponential backoff; 403 reads body first
- backoff(attempt: u32) -> Duration (private) — 100ms doubling per attempt, capped at 5s
- impl GoogleTasksClient for HttpClient::list_tasklists() -> Vec<TaskList> — GET all lists, follows pagination fully (maxResults=100)
- impl::insert_tasklist(title) -> TaskList — POST new list with title body
- impl::patch_tasklist(id, title) -> TaskList — PATCH rename; deliberately NO If-Match (server ignores it)
- impl::delete_tasklist(id) -> () — DELETE list by URL-encoded id
- impl::list_tasks(list_id, page_token) -> Page<Task> — GET one page; showCompleted+showHidden+maxResults=100; encodes pageToken
- impl::insert_task(list_id, NewTask) -> Task — POST task; parent/previous as query params; status defaults NeedsAction
- impl::get_task(list_id, id) -> Task — GET single task, both ids URL-encoded
- impl::patch_task(list_id, id, TaskPatch, etag) -> Task — PATCH only-set fields; optional If-Match etag header
- impl::delete_task(list_id, id) -> () — DELETE task; deliberately unconditional (no If-Match)
- impl::move_task(list_id, id, parent, previous) -> Task — POST /move, query params, explicit Content-Length: 0 (Google 411s without it)
TESTS (in-file #[cfg(test)] mod tests):
- backoff_grows_then_caps — backoff grows from 100ms, caps at 5s
- map_status_categorizes_correctly — 401/412/429/503 map to expected variants
- refresh_on_401_then_retry_succeeds — 401 triggers exactly one refresh, retry succeeds
- refresh_on_401_still_fails_returns_unauthorized — persistent 401 after refresh returns Unauthorized
- denied_refresh_surfaces_auth_expired_without_retrying_the_call — invalid_grant becomes AuthExpired, no request replay
- transient_refresh_failure_maps_to_retryable_network_error — flaky token endpoint maps to transient Network
- quota_403_is_transient_rate_limit_not_permanent_rejection — quota 403 body maps to RateLimited
- permission_403_stays_permanent — permission 403 stays Other, non-transient
- list_tasklists_follows_pagination — both list pages collected via nextPageToken
- list_tasks_parses_response_and_pagination — tasks parsed, next_page_token surfaced
- list_tasks_asks_for_completed_and_hidden_tasks — pins showCompleted+showHidden params on wire
- patch_tasklist_sends_no_if_match — list PATCH must omit If-Match (D6)
- list_tasks_passes_page_token — pageToken query param forwarded
- list_tasks_encodes_special_page_token — special-char page token URL-encoded correctly
- insert_task_sends_body_and_parses_response — POST body sent, id/etag parsed
- patch_task_sends_if_match_etag — task PATCH carries If-Match etag
- patch_task_412_maps_to_precondition_failed — 412 maps to PreconditionFailed
- delete_task_succeeds — 204 delete returns Ok
- delete_task_sends_no_if_match — task DELETE stays unconditional (P4)
- delete_task_404_maps_to_not_found — delete 404 maps to NotFound
- move_task_sends_parent_and_previous — move sends parent/previous query params
- move_task_sends_an_explicit_content_length — bodyless move POST pins Content-Length: 0
- insert_tasklist_sends_title_and_parses — list insert parses id/title/etag
- patch_tasklist_renames — list rename parses new title/etag
- delete_tasklist_succeeds — 204 list delete returns Ok
- delete_tasklist_404_maps_not_found — list delete 404 maps NotFound
NOTES:
- Auth coupling: all requests go through `crate::auth::AuthedClient` (get/post/patch/delete builders add Authorization). `send_authed` layers 401 handling on top of `send_with_retry`: refresh once via `auth.refresh_now()`; RefreshError::Denied (invalid_grant) → ApiError::AuthExpired so the sync engine aborts the whole run; RefreshError::Transient → ApiError::Network (retryable next run). Denied refresh must NOT replay the original request.
- Retry semantics: up to `max_retries` (default 4) extra attempts on transient errors (reqwest network error, RateLimited, Server 5xx per ApiError::is_transient); server-sent Retry-After (integer seconds) overrides exponential backoff 100ms·2^attempt capped 5s. Non-transient errors return immediately.
- 403 split (load-bearing): body inspected only for 403 — rate-limit/quota reasons (rateLimitExceeded, userRateLimitExceeded, quotaExceeded, dailyLimitExceeded, matched by raw substring) → RateLimited (transient); otherwise permanent Other with error.message. Treating quota 403 as permanent would mass-reject pending changes during a burst.
- Status mapping: 409 AND 412 both → PreconditionFailed; 404 → NotFound; unknown → Other("unexpected status N").
- Etag policy (deliberate, live-verified per RFC-009): task PATCH sends If-Match when etag given (412 = conflict); task DELETE is unconditional (no If-Match) so a delete can never be blocked by a concurrent edit; tasklist PATCH sends no If-Match because the endpoint ignores it (list renames are last-writer-wins by server design, so list conflict detection is impossible — forces D6).
- move_task quirk: endpoint takes everything in the query string, but Google returns 411 Length Required for a POST without Content-Length, and reqwest omits the header for bodyless POSTs — the explicit `Content-Length: 0` header is load-bearing; without it every reorder/promote/demote fails live.
- list_tasks MUST send both showCompleted=true and showHidden=true: Google auto-hides completed tasks; dropping either param makes them vanish from pulls and ghost detection would delete local completed history.
- list_tasklists paginates to completion because ghost detection treats the result as the COMPLETE remote list set — a dropped page would locally delete lists.
- maxResults=100 on both list endpoints (default page is 20 for tasks).
- Wire quirks: page/query tokens and ids are URL-encoded via `urlencoding::encode` (page tokens can contain +/= etc.); TaskWire/TaskListWire tolerate missing title/updated/position (defaulted); unknown task status is a hard decode error (ApiError::Other); insert_task serializes status via TaskStatus::as_api_str, parses via parse_api; JSON decode failures map to ApiError::Other("decode ...").
- Test helpers (not tests): make_tokens, counting_refresh, build_test_client (wiremock base URL, max_retries=0), plain_client.


## src/api/in_memory.rs (2074)
PURPOSE: Deterministic in-memory fake of GoogleTasksClient modeling live Google Tasks strictness, with fault injection for sync-engine tests.

PUBLIC SURFACE:

Types:
- pub enum Method — fault-injection/call-count key, one variant per client method (ListTaskLists, InsertTaskList, PatchTaskList, DeleteTaskList, ListTasks, InsertTask, GetTask, PatchTask, DeleteTask, MoveTask)
- pub struct InMemoryClient — the test double; interior Mutex<State> plus separate Mutex<Option<OnCall>> hook slot
- (private) enum FaultTarget { Id(String), Page(usize) } — scope of a targeted fault
- (private) struct TargetedFault { method, target, err } — order-independent one-shot fault
- (private) struct State — lists, live tasks (list_id, Task), soft-deleted tasks, etag_counter, fault queue, targeted faults, page_size, calls[10], commit_then_fail
- (private) type OnCall = Box<dyn FnMut(&InMemoryClient, Method) + Send> — sync per-call interleave hook
- (private) consts MAX_TITLE_CHARS = 1024, MAX_NOTES_CHARS = 8192 — live-API field limits (chars, not bytes)

Free functions (server-behavior helpers):
- validate_due(Option<String>) -> Result<Option<String>, ApiError> — None passes, "" clears, bare date = permanent 400, else normalized
- validate_sizes(title: Option<&str>, notes: Option<&str>) -> Result<(), ApiError> — char-counted length limits; overflow = permanent 400

State methods (private, model server behavior):
- State::new() — Default::default constructor
- fresh_etag(&mut self) -> String — monotonic "etag-N" counter for deterministic conflicts
- next_fault(&mut self, Method) -> Option<ApiError> — pop untargeted FIFO fault if front matches method
- next_targeted_fault(&mut self, Method, &FaultTarget) -> Option<ApiError> — fire+consume matching id/page fault, order-independent
- record(&mut self, Method) — increment per-method call counter
- take_commit_then_fail(&mut self, Method) -> bool — consume lost-response arming for this method
- position_after(&self, previous: Option<&str>) -> Result<String, ApiError> — shared insert/move lexicographic positioning; unknown previous = 404
- soft_delete_subtree(&mut self, id) -> usize — move root+descendants to deleted set; 0 = caller 404s
- is_completed(&self, id) -> bool — is task currently completed server-side
- cascade_complete_descendants(&mut self, root) — complete whole subtree, fresh etag + completed stamp each

InMemoryClient inherent methods (all pub unless noted):
- new() -> Self — construct empty client
- set_on_call(hook: impl FnMut(&InMemoryClient, Method) + Send + 'static) — install per-call interleave hook (mid-run racing-device mutations)
- clear_on_call() — remove installed hook
- (private) fire_on_call(Method) — run hook with slot emptied; re-entrant-safe, restored after
- seed_list(id, title) -> TaskList — seed a list with etag/updated filled
- seed_task(list_id, id, title, position) -> Task — seed task, caller-controlled id/position, no parent
- seed_task_with_parent(list_id, id, title, position, parent: Option<&str>) -> Task — seed task for hierarchy tests; asserts list exists
- fail_next(Method, fn() -> ApiError) — queue untargeted FIFO fault for next call
- fail_next_for_id(Method, id, fn() -> ApiError) — one-shot fault when method hits that task id
- fail_list_tasks_page(page: usize, fn() -> ApiError) — fault a specific 0-based list_tasks page
- set_page_size(usize) — split list_tasks into pages with real next_page_tokens
- commit_then_fail_next(Method) — next call commits mutation then returns network error (lost response)
- commit_then_fail_next_insert() — back-compat shorthand for commit_then_fail_next(InsertTask)
- clear_faults() — disarm all untargeted, targeted, and commit-then-fail faults
- delete_task_from_state(_list_id, task_id) — soft-delete subtree as another client would; no call record/fault
- seed_task_if_list_exists(list_id, id, title, position) — race-tolerant server-side insert (no-op if list gone); hook-safe
- delete_list_from_state(list_id) — remove list + its tasks + tombstones (other-client list delete)
- call_count(Method) -> u32 — how many times a method was invoked

impl Debug for InMemoryClient:
- fmt — hand-written; reports state + whether on_call hook armed (closure not Debug)

impl GoogleTasksClient for InMemoryClient (async_trait):
- list_tasklists() -> Result<Vec<TaskList>> — return seeded lists; fault + count hooks
- insert_tasklist(title) -> Result<TaskList> — create "remote-list-N" with fresh etag
- patch_tasklist(id, title) -> Result<TaskList> — rename list, fresh etag; unknown id = NotFound
- delete_tasklist(id) -> Result<()> — remove list, cascade tasks + tombstones; unknown = NotFound
- list_tasks(list_id, page_token) -> Result<Page<Task>> — live rows sorted by position, paged via "page-N" tokens; bad token = 400
- insert_task(list_id, NewTask) -> Result<Task> — validates parent/sizes/due; positioning; completed-parent cascade; lost-response fault
- get_task(list_id, id) -> Result<Task> — 200 for live AND soft-deleted (deleted:true) rows; else NotFound
- patch_task(list_id, id, TaskPatch, etag: Option<&str>) -> Result<Task> — size/due validation, 412 on stale etag, deleted-row 200-echo-ignore, reopen-ignore, complete cascade, lost-response fault
- delete_task(list_id, id) -> Result<()> — soft-delete with subtree cascade (no If-Match, deliberately); lost-response fault
- move_task(list_id, id, parent, previous) -> Result<Task> — unknown subject/parent/cycle = permanent 400, unknown previous = 404, repositioning, fresh etag, completed-destination cascade, lost-response fault

TESTS (in-file #[cfg(test)] mod tests):
- seeded_lists_are_returned — seeded list comes back from list_tasklists
- insert_then_patch_changes_etag — patch issues a fresh etag
- stale_etag_returns_precondition_failed — wrong If-Match etag draws 412
- fail_next_injects_one_error — untargeted fault fires once then clears
- call_count_tracks_each_method — per-method call counters are independent
- delete_soft_deletes_gone_from_list_but_still_gettable — deleted row absent from list, get still 200
- patch_of_a_deleted_task_is_200_but_ignored — echo body returned, stored row untouched
- oversize_title_and_notes_are_permanent_400s — 1024/8192 char limits, char-counted, non-transient, row untouched
- empty_notes_patch_clears_the_field_to_none — notes:"" clears to None, stored too
- empty_title_is_accepted_not_rejected — untitled tasks valid on insert and patch
- patch_of_a_deleted_task_with_a_stale_etag_still_200s_no_412 — deleted row never 412s (P4 delete-wins)
- delete_soft_deletes_the_whole_subtree — cascade soft-deletes every descendant
- deleting_a_parent_prevents_new_inserts_under_it — insert under deleted parent = permanent 400
- move_task_rejects_an_unknown_parent — move to unknown parent permanent 400, no mutation
- move_task_rejects_a_cycle — self/descendant parent permanent 400, tree unchanged
- move_task_updates_parent_and_position — no-previous move goes to top slot
- move_task_with_previous_sets_position — moved position sorts between anchor and successor
- move_with_an_unknown_previous_sibling_is_not_found — unknown previous is 404, not 400
- move_bumps_the_task_etag — a move issues a fresh etag
- move_creating_a_third_level_is_accepted — no nesting-depth cap
- moving_an_open_task_under_a_completed_parent_completes_it — cascade shown in move response
- moving_a_task_under_an_open_parent_leaves_it_open — cascade keys off destination status only
- inserting_a_subtask_under_a_completed_parent_returns_it_completed — insert response already completed
- inserting_a_child_does_not_change_the_parents_etag — child insert leaves parent etag alone
- completing_a_parent_cascades_to_a_child_we_never_pulled — pre-child etag lands, cascade covers unseen child
- list_tasks_returns_position_order_not_insertion_order — sorted by position string
- move_reorders_task_in_subsequent_list — move changes real list ordering
- list_tasks_paginates_with_real_tokens — real page tokens, full coverage, no dupes
- fail_list_tasks_page_targets_one_page_only — page fault fires on target page, consumed
- fail_next_for_id_targets_only_that_task — id fault order-independent, consumed on fire
- move_task_unknown_id_is_permanent_400 — unknown move subject is 400 not 404
- completing_a_parent_completes_its_subtree_server_side — completion cascades with stamps to descendants
- reopening_a_child_of_a_completed_parent_is_silently_ignored — 200 but status stays completed
- reopening_a_parent_does_not_reopen_its_children — children stay done after parent reopens
- insert_to_nonexistent_list_returns_not_found — unknown list on insert is NotFound
- patch_without_etag_always_succeeds — no If-Match means unconditional patch

NOTES:
Live-API strictness this fake models (each verified against the live service unless noted; see module doc + `live_api_probe` example, RFC-009):
- Due format: `due` must be a full RFC-3339 timestamp; bare `YYYY-MM-DD` = permanent 400; accepted values normalized to `YYYY-MM-DDT00:00:00.000Z` (via crate::dates::normalize_due); empty string clears to None.
- Field-size limits: title > 1024 chars or notes > 8192 chars = permanent 400 on both insert and patch; Google counts CHARACTERS not bytes; validation precedes resource lookup (fires even on deleted/absent rows); rejected patch leaves row+etag untouched. Empty title is VALID (untitled task).
- Notes clearing: notes:"" clears to None (both live row and deleted-row echo) — never a stored empty string.
- ETag/412: patch with If-Match against a stale etag = PreconditionFailed; no etag = unconditional. Etags are a monotonic "etag-N" counter for deterministic conflicts. Deliberate divergence: delete_task takes NO etag (live DELETE honors If-Match, but HttpClient deliberately sends none — RFC-009 P4 "delete wins" — so the trait/fake have no parameter).
- Soft delete: DELETE moves row + cascaded subtree into a separate `deleted` collection; row vanishes from list_tasks (showDeleted=false default), direct get still 200 (with deleted:true on the returned Task), patch returns 200 echoing the edit but persists nothing, and — key for P4 — a stale-etag patch on a deleted row must NOT 412. Deleted rows are invisible to all internal live-set queries (parent checks, positioning, cascades), so e.g. inserting under a soft-deleted parent is the same permanent 400 as an unknown parent.
- Delete cascade: deleting a parent soft-deletes its entire descendant subtree. delete_tasklist hard-removes the list's tasks AND its tombstones.
- Completion cascade: completing a parent auto-completes the whole subtree (each descendant gets fresh etag + completed timestamp "2026-01-01T00:00:00Z"); covers children the client never pulled, and a complete pushed with a pre-child etag lands (child insert does NOT bump parent etag). Reopening a subtask whose parent is completed returns 200 but is silently ignored. Reopening a parent does NOT reopen children. Attaching an open task to a completed parent (insert-with-parent or move) completes it — the response body already carries status=completed, and the cascade takes the attached subtree.
- Parent/position semantics: insert and move share one positioning rule (position_after): with `previous`, anchor.position + '+' (0x2B, sorts after anchor, before successor); with none, top slot '!' + descending counter. list_tasks returns tasks sorted by the opaque lexicographic position string, so moves really reorder. Move issues a fresh etag; no nesting-depth cap.
- Error-status asymmetries: move with unknown SUBJECT id = 400 "Invalid task ID" (not 404); unknown `previous` = 404 "Previous task id not found"; unknown/deleted `parent` on insert OR move = permanent 400 (insert's verified rule reused for move, #114); move creating a cycle (target parent is self or in own subtree, walked against current server state) = permanent 400 (#155). Unknown list = NotFound. All permanent 400s are non-transient so they drive the engine's PushFailure::Reject path (#146).
- Pagination: set_page_size splits list_tasks into pages with real opaque "page-N" tokens; malformed token = 400; last page has no token.
- Fault injection: fail_next (untargeted FIFO per method), fail_next_for_id (order-independent, one-shot, per task id), fail_list_tasks_page (per 0-based page), commit_then_fail_next (mutation commits server-side THEN a network error is returned — the at-least-once lost-response hazard, available on insert/patch/delete/move), clear_faults disarms everything. call_count tracks per-method invocations.
- Interleave hook: set_on_call installs a SYNCHRONOUS FnMut fired at the start of every trait call BEFORE the state lock, so a test can model another device mutating mid-run via the sync helpers (seed_task_if_list_exists, delete_task_from_state, delete_list_from_state — none of which record calls or consume faults); the hook slot is emptied while it runs so re-entrant client calls neither re-fire nor deadlock (on_call lives under its OWN mutex, separate from inner).
- Concurrency shape: all state under one Mutex<State>; trait methods are async but do no awaiting — everything is synchronous under the lock. Task ids are unique across lists (subtree resolution ignores list_id). Generated ids: "remote-N" / "remote-list-N" from the etag counter; updated is always the fixed "2026-01-01T00:00:00Z"; web_view_link is synthesized as "https://tasks.google.com/task/{id}".
- Porter warning: the strictness is the point — a permissive fake lets the whole suite pass while production sync is broken (memory rule: keep in_memory.rs as strict as Google). Divergences from live are deliberate and documented (currently only the missing DELETE If-Match); do not "fix" them.

## src/auth/mod.rs (20)
PURPOSE: Auth module root: OAuth 2.0 PKCE for desktop plus the authed-request wrapper (RFC-001) and Android token-provider seam (RFC-010).
PUBLIC SURFACE:
- pub use client::{AuthedClient, RefreshError, RefreshFn, parse_refresh_response}
- pub use error::AuthError
- pub use flow::{OAuthConfig, build_auth_url, login, parse_redirect} (flow is a pub mod)
- pub use pkce::{Pkce, PkceParams, random_state}
- pub use store::{InMemoryTokenStore, KeyringTokenStore, StoredTokens, TokenStore}
- pub use token_provider::{FakeTokenProvider, MobileTokenProvider, TokenProviderError, provider_refresh_fn}
TESTS (in-file #[cfg(test)]): none
NOTES: —

## src/auth/error.rs (36)
PURPOSE: Auth-layer error enum (OAuth, token storage, request authentication).
PUBLIC SURFACE:
- enum AuthError — Keyring(String), StateMismatch (CSRF/stale redirect), UserDenied, TokenEndpoint(String), Redirect(String), NotSignedIn, Format(String)
TESTS (in-file #[cfg(test)]): none
NOTES: —

## src/auth/pkce.rs (95)
PURPOSE: Pure PKCE primitives (verifier/challenge/state), no IO.
PUBLIC SURFACE:
- struct Pkce {verifier, challenge, method: &'static str} — generated verifier + S256 challenge
- Pkce::generate() -> Self — 32 random bytes → 43-char base64url verifier + challenge
- Pkce::challenge_for(verifier: &str) -> String — S256(verifier) base64url-no-pad (public for testing)
- struct PkceParams {code, state} — params expected on the loopback redirect
- fn random_state() -> String — 24 random bytes base64url-no-pad CSRF state
TESTS (in-file #[cfg(test)]):
- challenge_is_deterministic_for_known_verifier — RFC 7636 §4.6 test vector
- generate_produces_unique_verifiers — uniqueness; method S256; challenge consistent
- verifier_meets_rfc_length_minimum — length in 43..=128
- random_state_is_unique — two states differ
NOTES: Method is always "S256". Uses rand + sha2 + base64 URL_SAFE_NO_PAD.

## src/auth/store.rs (153)
PURPOSE: Token persistence: TokenStore trait with OS-keychain (keyring crate) and in-memory implementations.
PUBLIC SURFACE:
- struct StoredTokens {access_token, refresh_token, access_expires_at: Option<i64> (epoch secs), scope} — persisted bundle
- trait TokenStore: Send + Sync — load() -> Result<Option<StoredTokens>>, save(&StoredTokens), clear()
- struct InMemoryTokenStore + ::new() — Mutex<Option<StoredTokens>>; volatile, same contract
- struct KeyringTokenStore + ::new(service, user) — one keychain entry per service+user ("default" user for single-account MVP)
- (private) KeyringTokenStore::entry() — keyring::Entry construction
TESTS (in-file #[cfg(test)]):
- in_memory_round_trips — load/save/clear round trip
- stored_tokens_serialize_round_trip — JSON round trip of the bundle
NOTES: Keychain stores the bundle as JSON in the entry's password. NoEntry maps to Ok(None) on load and Ok(()) on clear. Keyring impl itself is untested in-file (needs OS keychain).

## src/auth/client.rs (302)
PURPOSE: Authenticated HTTP wrapper: bearer-token request builders, refresh-on-401 seam, and pure refresh-response parsing.
PUBLIC SURFACE:
- enum RefreshError {Denied(String), Transient(String)} — grant-dead vs retry-later split the sync engine needs; impl Display
- fn parse_refresh_response(http_status, body, refresh_token, scope_fallback, now_epoch) -> Result<StoredTokens, RefreshError> — pure; OAuth JSON `error` code (not HTTP status) decides Denied vs Transient
- type RefreshFn = Arc<dyn Fn(String) -> BoxFuture<Result<StoredTokens, RefreshError>> + Send + Sync> — token-refresh seam
- struct AuthedClient (Clone) — reqwest::Client + Arc<Mutex<StoredTokens>> + Arc<dyn TokenStore> + RefreshFn
- AuthedClient::new(http, tokens, store, refresh) -> Self
- AuthedClient::access_token() -> String — snapshot of current token
- AuthedClient::is_access_expired() -> bool — conservative: no-expiry-known = not expired
- AuthedClient::replace_tokens(StoredTokens) -> Result<(), AuthError> — swap in memory + persist
- AuthedClient::refresh_now() -> Result<(), RefreshError> — force refresh; persist failure reported Transient (token live in memory)
- AuthedClient::get/post/patch/delete(url) -> reqwest::RequestBuilder — pre-authenticated builders
- (private) make_request(method, url) — bearer_auth attach
TESTS (in-file #[cfg(test)]):
- refresh_now_updates_token_in_memory_and_in_store — refresh swaps token and persists
- refresh_response_invalid_grant_is_denied_not_transient — Google's live invalid_grant body (HTTP 400) → Denied
- refresh_response_5xx_and_garbage_are_transient — 5xx, missing access_token, non-grant OAuth codes retryable
- refresh_response_success_keeps_or_rotates_the_refresh_token — keeps old rt unless response rotates it; expiry = now+expires_in
- is_access_expired_handles_unset_expiry_as_not_expired — None expiry ≠ expired
NOTES: Grant-level codes invalid_grant/invalid_client/unauthorized_client → Denied; everything else Transient. Refresh-token rotation: adopt response's refresh_token if present, else carry old. expires_in defaults 3600. The actual 401-replay lives in api/http.rs; this file only supplies the seam. RefreshFn is also the adapter point for Android (token_provider.rs).

## src/auth/flow.rs (357)
PURPOSE: Desktop OAuth 2.0 PKCE login: loopback HTTP server on an ephemeral port, browser consent, redirect parse, code-for-tokens exchange.
PUBLIC SURFACE:
- struct OAuthConfig {client_id, client_secret, scopes, auth_url, token_url}
- OAuthConfig::google_tasks(client_id, client_secret) -> Self — Google endpoints + tasks scope ("Desktop app" client: secret required even under PKCE)
- fn build_auth_url(config, redirect_uri, challenge, method, state) -> String — pure consent-URL builder (percent-encoded)
- fn parse_redirect(redirect_url, expected_state) -> Result<String, AuthError> — extract code; ?error= → UserDenied; wrong/missing state → StateMismatch (code rejected even when present)
- async fn login(config, store: &Arc<dyn TokenStore>) -> Result<StoredTokens, AuthError> — full flow: bind 127.0.0.1:0, open::that(browser), accept one connection, parse GET path, exchange, save to store, serve success HTML
- (private) async fn exchange_code(config, code, redirect_uri, verifier) -> Result<StoredTokens, AuthError> — POST form with client_id+client_secret+code_verifier
TESTS (in-file #[cfg(test)]):
- parse_redirect_extracts_code_from_desktop_loopback_url — happy path
- parse_redirect_rejects_state_mismatch_even_with_a_valid_code — CSRF guard beats a valid code
- parse_redirect_reports_user_denied_on_error_param — error=access_denied → UserDenied
- parse_redirect_reports_user_denied_when_no_code_present — missing code → UserDenied
- build_auth_url_carries_loopback_redirect_pkce_and_state — encoded redirect, challenge, method, state, client_id
- desktop_login_exchanges_code_and_sends_the_client_secret — wiremock: exchange sends client_secret + code_verifier; tokens persist
NOTES: Android does NOT use this flow (Google rejects custom-scheme/loopback redirects on Android) — Play Services AuthorizationClient via token_provider.rs instead (RFC-010). login reads a single 4KB request and always replies 200 HTML. exchange_code requires refresh_token in the response (errors without it); scope taken from config, not response.

## src/auth/token_provider.rs (295)
PURPOSE: Android on-device token seam (RFC-010): MobileTokenProvider trait over Play Services AuthorizationClient, adapter to RefreshFn, and a scripted fake.
PUBLIC SURFACE:
- (private) const TASKS_SCOPE — the single scope ever requested
- enum TokenProviderError {InteractionRequired, Unavailable(String)} — permanent (dead session → needs_reauth) vs transient split; impl Display
- trait MobileTokenProvider: Send + Sync — async authorize(interactive: bool) -> Result<String, TokenProviderError> (non-interactive MUST NOT show UI; interactive = sign-in gesture, may launch picker/consent); async sign_out() (drop account association)
- fn provider_refresh_fn(Arc<dyn MobileTokenProvider>) -> RefreshFn — adapts provider to AuthedClient's 401-refresh seam: ignores refresh-token arg, silent authorize(false); returns bundle with empty refresh_token and access_expires_at None (refresh only reactively on 401); InteractionRequired → RefreshError::Denied, Unavailable → Transient
- struct FakeTokenProvider — scripted double; constructors with_token(t), needs_interaction(), unavailable(msg); set_token(t) flips outcome; calls() -> Vec<bool> records interactive flags; was_signed_out() -> bool
- (private) enum FakeOutcome {Token, NeedsInteraction, Unavailable}
TESTS (in-file #[cfg(test)]):
- silent_refresh_fetches_a_fresh_token_without_ui — 401 path asks non-interactively; empty rt; no expiry
- silent_refresh_needing_interaction_is_denied_not_transient — revoked grant → Denied → needs_reauth, not endless retry
- silent_refresh_when_unavailable_is_transient — GMS outage stays retryable
- interactive_authorize_is_the_sign_in_gesture — silent probe fails, gesture succeeds, both recorded
- sign_out_is_recorded — sign_out flag observable
NOTES: Real impl is the in-repo tauri-plugin-google-auth Kotlin plugin. Deliberately no refresh-token concept on Android — Play Services owns the grant; "refresh" is a silent token fetch. Desktop auth is untouched by this module. Nothing from the adapter's bundle is ever persisted (RFC-010 G4).


## src/store/mod.rs (885)
PURPOSE: Opens the local SQLite cache pool and enforces the schema-fingerprint wipe-and-recreate lifecycle (no migrations pre-1.0).
PUBLIC SURFACE:
- StoreError (pub use from error.rs) — the store's error type, re-exported
- PendingMove / Store / StoredTask / StoredTaskList / SyncState (pub use from repo.rs) — repo types re-exported at store root
- fn open(path: &Path) -> Result<SqlitePool, StoreError> — open file-backed pool (WAL, FK on, max 4 conns), create-if-missing, then prepare_schema
- fn open_memory() -> Result<SqlitePool, StoreError> — in-memory pool (1 conn, FK on) for tests; prepare_schema with no backup path
TESTS (in-file #[cfg(test)]):
- open_memory_succeeds_and_schema_exists — fresh in-memory DB has tasks table
- open_stamps_the_schema_fingerprint — fresh DB stamped non-zero, equals fingerprint
- reopen_of_current_db_preserves_data — matching fingerprint means no wipe, no backup
- fresh_db_is_not_backed_up — brand-new DB writes no pre-wipe file
- incompatible_schema_is_exported_then_wiped_and_recreated — old schema exported to JSON, wiped, re-stamped
- wipe_and_recreate_drops_stale_views_and_triggers — wipe drops views and triggers too (#133)
- cascade_delete_still_works_after_a_wipe — FK pragma restored after wipe; cascade intact
- wipe_aborts_when_backup_fails_and_local_only_data_at_risk — WipeAborted; local-only data untouched (#129)
- wipe_aborts_when_backup_fails_and_dirty_edits_at_risk — dirty unpushed edits block backup-less wipe
- clean_cache_wipes_best_effort_even_when_backup_fails — fully-synced cache wipes without backup
- has_unsynced_local_data_distinguishes_clean_from_at_risk — detector: clean cache safe, local-only list at risk
NOTES:
- Schema fingerprint logic (SPECIAL ATTENTION): the entire schema lives in one file, `crates/axiotask-core/schema.sql`, embedded via `include_str!` as const SCHEMA. `schema_fingerprint()` (private) = first 4 bytes of SHA-256 of the schema text, as i64 (big-endian i32); coerced to 1 if it hashes to 0 because 0 is the unstamped default. The value is stored in SQLite's `PRAGMA user_version` header slot.
- `prepare_schema(pool, Option<path>)` (private): reads user_version; equal to fingerprint → no-op fast path. Mismatch + user tables present → old/incompatible DB: attempt JSON backup (`export_before_wipe`), then `wipe()`, then execute SCHEMA and stamp `PRAGMA user_version = fingerprint`. Mismatch + no tables → fresh DB: just create + stamp. NO migrations ever (RFC-003 G4): a schema change = wipe-and-recreate the cache.
- Backup-failure policy (#129): if the pre-wipe JSON backup cannot be written durably, the wipe only proceeds when the cache is fully synced. `has_unsynced_local_data` (private) probes (schema-agnostically, conservatively — a probe error counts as at-risk) for: local_only=1 lists, non-clean lists/tasks, tasks with pending_op, any pending_moves or inflight_creates rows. If at risk → `StoreError::WipeAborted` and the DB is left untouched (fail open). Helper `any_row_matches` treats a missing table as safe, an unreadable one as at-risk.
- `wipe()` (private): drops triggers first, then views, then tables (all non-sqlite_* objects from sqlite_master), with `PRAGMA foreign_keys` toggled OFF then back ON on one connection. Views/triggers included because a standalone view survives a table-only drop (#133).
- Backup mechanics: `export_before_wipe` → `raw_dump_json` (schema-agnostic SELECT * of every user table; each cell decoded by SQLite type class via `cell_to_json`, BLOBs base64) wrapped in {app, kind:"pre-wipe-raw-dump", exported_at, tables}. Written by `write_durably` (write + file sync_all + best-effort parent-dir fsync) to `pre_wipe_backup_path`: `axiotask-prewipe-<YYYYmmdd-HHMMSS>.json` beside the DB file (timestamped so successive wipes never clobber). In-memory DBs (path None) skip backup and report Durable.
- BackupOutcome (private enum): Durable | Failed(String) — drives the abort-vs-proceed decision above.
- Uses runtime sqlx queries (not compile-time macros) so the crate builds without DATABASE_URL; queries validated only at test time.
- A porter must reproduce: fingerprint stamping, fail-open abort, durable timestamped JSON export, and full-object (trigger/view/table) wipe with FK restore.

## src/store/repo.rs (2571)
PURPOSE: The Store repository — every query/mutation on the SQLite cache, encoding sync-state guards (dirty-preservation, race-guarded landings, base snapshots, tombstones, in-flight creates).
PUBLIC SURFACE:
- enum SyncState { Clean, Dirty, Deleted } — per-row sync state stored as text
- SyncState::as_str(self) -> &'static str — wire form "clean"/"dirty"/"deleted"
- SyncState::parse(&str) -> Option<Self> — parse SQLite text back; None on unknown
- struct StoredTask { task: Task, list_id, sync_state, local_updated, pending_op: Option<String> } — domain task plus sync metadata
- struct StoredTaskList { list: TaskList, sync_state, local_updated, pending_op, local_only: bool } — list plus sync metadata; local_only never syncs
- struct PendingMove { task_id, list_id, parent_id: Option, previous_id: Option } — queued position/parent move for the move API
- struct Store (Clone, wraps SqlitePool) — repository handle
- Store::new(pool: SqlitePool) -> Self — wrap an open pool
- Store::pool(&self) -> &SqlitePool — expose underlying pool
- Store::upsert_list(&StoredTaskList) — insert/replace list row unconditionally
- Store::upsert_remote_list(&StoredTaskList) — server upsert; WHERE sync_state='clean' spares dirty rows
- Store::delete_list_hard_if_clean(id) — hard-delete list only when still clean
- Store::all_lists() -> Vec<StoredTaskList> — all non-deleted lists, arbitrary order
- Store::upsert_task(&StoredTask) — insert/replace task; captures/clears base_* snapshot via CASE logic
- Store::upsert_remote_task(&StoredTask) — server upsert; atomic WHERE clean guard preserves live edits
- Store::remove_ghost_task(id) -> bool — delete clean row server lost; cascade takes subtree
- Store::rehome_unpushed_tasks(from_list, to_list) -> u64 — move etag-less rows/subtrees out of dying list (tx; also moves inflight markers)
- Store::has_unpushed_tasks(list_id) -> bool — list still holds server-unseen rows
- Store::list_tasks(list_id) -> Vec<StoredTask> — non-deleted tasks ordered top-level-first, then parent, position
- Store::find_task_any(id) -> Option<StoredTask> — fetch by id including tombstones
- Store::dirty_ids() -> HashSet<String> — ids of dirty/deleted tasks (pull skip-set)
- Store::clean_task_ids_for_list(list_id) -> HashSet<String> — clean ids per list, for ghost detection
- Store::drain_dirty() -> Vec<StoredTask> — dirty/deleted tasks to push: create→update→delete, parents first; excludes local-only lists
- Store::mark_task_clean(id, new_etag, server_updated, expected_local_updated) — clean only if local_updated matches drain snapshot; etag adopted regardless
- Store::apply_pushed_task(&Task, expected_local_updated) — adopt full server response; snapshot-guarded; pending-move guard on parent/position; missing-parent detach drops etag; re-bases base_* if still dirty
- Store::refresh_task_meta(id, new_etag, server_updated) — adopt etag/updated only, never touches sync_state (post-move)
- Store::delete_task_hard(id) — unconditional row delete (post server confirm)
- Store::tombstone_subtree(root_id, descendant_ids, now) — one tx: root gets pending 'delete', descendants local-only tombstones (pending_op NULL)
- Store::delete_list_hard(id) — unconditional list delete
- Store::drain_dirty_lists() -> Vec<StoredTaskList> — dirty/deleted lists to push, create→update→delete; excludes local-only
- Store::mark_list_clean(id, new_etag, server_updated) — mark list synced, clear pending_op, adopt etag
- Store::clean_list_ids() -> HashSet<String> — clean, non-local-only list ids for ghost detection
- Store::remap_list_id(local_id, remote_id, etag, server_updated) — tx (defer_foreign_keys): rewrite list id across task_lists/tasks/pending_moves/inflight_creates, mark clean
- Store::record_move(task_id, list_id, parent_id, previous_id) — upsert pending move (one per task, last wins)
- Store::pending_moves() -> Vec<PendingMove> — all queued moves
- Store::clear_move(task_id) — remove one pending move
- Store::pending_push_count() -> u32 — read-only count of dirty tasks + lists + moves, excluding local-only
- Store::clear_all() — delete all tasks, lists, moves, inflight markers (fresh sync)
- Store::clear_synced() — delete only local_only=0 lists; FK cascade clears their tasks/moves/markers
- Store::write_sync_log(pulled, pushed, conflicts, duration_ms, error) — append sync_log row, prune to newest 500; errors swallowed (non-Result)
- Store::finish_create(local_id, remote_id, etag, server_updated, expected_local_updated, server_position) — one tx: remap id everywhere (self, children, all 3 pending_moves columns), guarded clean/position/base handling, tombstone kept as 'delete', re-edit flips create→update, clear inflight marker
- Store::record_inflight_create(local_id, list_id, base_local_updated) — tx: durably mark insert in flight + set base_* to payload as sent, before the non-idempotent server insert
- Store::inflight_creates() -> Vec<(String, String)> — (local_id, list_id) markers; non-empty only after a crash mid-create
- Store::inflight_base_local_updated(local_id) -> Option<String> — drain-time local_updated stored on the marker (#124)
- Store::base_snapshot(id) -> Option<BaseSnapshot> — base_* columns; base_title NULL is the "no base" sentinel
- Store::clear_inflight_create(local_id) — drop a marker without finalizing (insert never reached server)
- Store::server_may_hold(id) -> bool — etag present OR open inflight marker: decides tombstone vs hard delete
TESTS (in-file #[cfg(test)]):
- upsert_and_read_lists — list upsert round-trips through all_lists
- local_only_flag_round_trips — local_only column persists per list
- clean_list_ids_excludes_local_only — ghost set never contains local-only lists
- drain_dirty_lists_excludes_local_only — dirty local-only list never drained
- drain_dirty_excludes_tasks_in_local_only_lists — only synced-list tasks drained
- pending_push_count_sums_tasks_lists_moves_excluding_local_only — count = task+list+move, local-only excluded
- upsert_remote_list_does_not_clobber_dirty — server list upsert spares dirty rename
- delete_list_hard_if_clean_spares_dirty — dirty list survives conditional delete
- upsert_task_and_list_in_order — list_tasks orders top-level before subtasks
- drain_dirty_orders_create_before_update_before_delete — drain op ordering
- mark_task_clean_updates_etag_and_clears_flags — matching snapshot lands clean
- mark_task_clean_stale_snapshot_keeps_dirty_but_adopts_etag — re-edit stays queued, etag adopted
- refresh_task_meta_never_touches_sync_state — move landing keeps dirty flag
- apply_pushed_task_detaches_when_the_adopted_parent_is_absent — missing parent → detach + drop etag
- apply_pushed_task_keeps_a_parent_that_is_present — existing parent adopted normally
- apply_pushed_task_reedited_row_stays_dirty_and_rebases_to_server_body — stale snapshot: keep content, re-base base_*
- apply_pushed_task_does_not_resurrect_a_row_deleted_mid_push — late landing leaves tombstone intact
- apply_pushed_task_keeps_a_pending_move_intact — queued move's parent/position survive; content lands
- finish_create_rewrites_self_and_children_and_marks_clean — id remap incl. children, atomic clean
- finish_create_reedited_row_stays_dirty_as_update — mid-flight edit flips create→update
- finish_create_clean_landing_clears_base — clean create landing nulls base_*
- finish_create_reedited_row_keeps_its_base — still-dirty row keeps payload-as-sent base
- delete_task_hard_removes_row — unconditional delete works
- tombstone_subtree_marks_root_pushable_and_children_local_only — root 'delete', children pending_op NULL, all hidden
- delete_list_hard_removes_row — unconditional list delete works
- list_tasks_excludes_deleted — tombstones invisible to list view
- find_task_any_sees_tombstones — tombstone reachable by id; missing id None
- all_lists_excludes_deleted — deleted list hidden
- sync_state_round_trips — as_str/parse round-trip; unknown → None
- upsert_task_overwrites_existing — same id replaces content and state
- web_view_link_round_trips — web_view_link persists in both readers
- upsert_remote_task_does_not_clobber_dirty — pull upsert spares dirty edit
- upsert_remote_task_updates_clean_and_inserts_new — inserts new, updates clean rows
- remove_ghost_task_spares_dirty — dirty ghost spared; clean removed
- remove_ghost_task_cascades_its_whole_subtree — ghost delete cascades even unpushed subtask (D3 rejected)
- rehome_unpushed_tasks_moves_only_rows_the_server_never_saw — etag-less subtree moves; synced/tombstone/orphan stay
- clear_all_removes_everything — full wipe of lists and tasks
- clear_synced_preserves_local_only_lists_and_tasks — local-only list and tasks survive fresh sync
- clear_synced_cascades_moves_of_synced_tasks — no orphan pending moves after clear_synced
- record_and_read_pending_move — move upsert round-trips
- record_move_upserts_same_task — second record replaces first per task
- clear_move_removes_it — clear_move empties queue
- clear_all_removes_pending_moves — clear_all also drops moves
- deleting_task_cascades_pending_move — FK cascade removes task's move
- inflight_create_record_and_list — marker recorded and listed
- finish_create_clears_inflight_marker — finalize removes marker in same tx
- deleting_task_cascades_inflight_marker — FK cascade removes marker
- finish_create_does_not_resurrect_a_tombstone — deleted-mid-flight row keeps 'delete', learns server id/etag
- server_may_hold_covers_the_etag_and_the_inflight_window — etag OR inflight marker → true
- editing_a_clean_row_captures_and_preserves_its_base — first edit captures base; repeat edits preserve; clean landing clears
- upsert_landing_a_dirty_row_clean_clears_its_base — dirty→clean upsert nulls base (#139)
- inflight_base_is_the_payload_as_sent_and_is_durable — base survives mid-flight edit; drain snapshot durable
- finish_create_rewrites_pending_move_task_id — remap rewrites pending_moves.task_id
NOTES:
- Tables touched: task_lists, tasks, pending_moves, inflight_creates, sync_log. FK ON DELETE CASCADE is load-bearing everywhere: task delete cascades subtasks, its pending_move, its inflight marker; list delete cascades its tasks (and transitively the rest). `PRAGMA defer_foreign_keys = ON` is used inside the remap transactions (remap_list_id, finish_create).
- Base-snapshot invariant (#124/#139, RFC-009 §B): base_title/base_notes/base_due/base_status are NULL while a row is clean. upsert_task's ON CONFLICT CASE logic: landing clean → NULL them; clean→dirty transition → capture the OLD row's content (tasks.* on the RHS of DO UPDATE is the pre-update row); otherwise preserve. base_title NULL is the presence sentinel (title is NOT NULL so it can only be NULL when no base exists).
- Race guard pattern: every push-landing mutation (mark_task_clean, apply_pushed_task, finish_create) compares `local_updated` against the drain-time snapshot; mismatch means a mid-flight re-edit — keep content + dirty flag, adopt only etag/updated. apply_pushed_task additionally refuses to touch parent_id/position while a pending_moves row exists, and detaches (parent NULL + etag dropped) when the server names a parent absent locally (FK-safe; pull re-links later).
- finish_create's pending_op CASE: deleted row stays 'delete' (learns the server id so the delete can push — never resurrected); matching snapshot → NULL (clean); otherwise → 'update' (re-running as create would duplicate). Server-assigned position adopted only when guarded and no pending move.
- Local-only lists (local_only=1) are excluded from: drain_dirty (via JOIN), drain_dirty_lists, clean_list_ids (ghost detection), pending_push_count, and are preserved by clear_synced.
- Ghost/re-home semantics (RFC-009): remove_ghost_task deletes only clean rows and the FK cascade kills the whole subtree — no promotion (D3 rejected). rehome_unpushed_tasks moves only etag-less non-deleted rows that are top-level or whose (also-moving) parent qualifies, evaluated against the pre-update state via `id IN (SELECT ...)`; inflight markers follow their rows (P8).
- write_sync_log is fire-and-forget (returns (), errors ignored) and self-prunes to the newest 500 rows.
- Private helper stored_task_from_row(SqliteRow) -> StoredTask decodes rows; bad status/sync_state text → StoreError::Decode; `deleted` field always false (tombstones are a sync_state, the domain flag is for API wire use).
- pending_op values are the strings "create" | "update" | "delete"; drain ordering is by CASE on that string, then parents-before-children, then local_updated ASC.

## src/store/error.rs (43)
PURPOSE: Persistence-layer error enum + sqlx::Error conversion.
PUBLIC SURFACE:
- enum StoreError — Open(String), Migrate(String), WipeAborted(String), Sql(String), Decode(String), NotFound
- impl From<sqlx::Error> — RowNotFound → NotFound, everything else → Sql(msg)
TESTS (in-file #[cfg(test)]): none
NOTES: WipeAborted is the pre-1.0 fail-open guard: a schema wipe-and-recreate is REFUSED when local-only/unsynced data exists and the pre-wipe backup could not be written durably — startup fails with data intact rather than destroying it silently.

## src/sync/mod.rs (10)
PURPOSE: Sync module root: bidirectional sync between local store and a GoogleTasksClient (RFC-004 conflict table).
PUBLIC SURFACE:
- pub use engine::{SyncEngine, SyncOutcome}; pub use error::SyncError; pub mod reconcile
TESTS (in-file #[cfg(test)]): none
NOTES: designs/RFC-004-sync-engine.md holds the conflict table; RFC-009 is the semantic authority for sync behavior.

## src/sync/error.rs (75)
PURPOSE: Sync-run error enum with the transient/permanent/auth-expired classification the scheduler branches on.
PUBLIC SURFACE:
- enum SyncError — Api(#[from] ApiError), Store(#[from] StoreError), Internal(String)
- SyncError::is_transient(&self) -> bool — only Api errors that are themselves transient; scheduler retries these silently at base cadence, everything else backs off and surfaces attention
- SyncError::is_auth_expired(&self) -> bool — Api(AuthExpired) only; drives the needs-reauth UI state (neither retry nor generic attention)
TESTS (in-file #[cfg(test)]):
- transient_only_for_retryable_api_errors — 503/network/rate-limit transient; NotFound/412/AuthExpired/Internal not
- auth_expired_detected_only_for_dead_session — AuthExpired yes; Unauthorized/500/Internal no
NOTES: In practice the engine swallows transient API errors and returns Ok (partial run), so a transient SyncError rarely reaches the scheduler — the classification exists so backoff/attention never mis-fires when one does. Store failures are the only ones treated as fatal.

## src/sync/engine.rs (7809)
PURPOSE: The IO half of sync — one `run()` pushes local changes, pulls remote state, and applies `reconcile`'s pure decisions to the store (RFC-004 design, RFC-009 conflict matrix, "remote wins" MVP).

PUBLIC SURFACE:
- SyncOutcome (pub struct, Debug/Default/Clone/PartialEq/Eq) — counters + changed-data scope of one run: pulled, pushed, conflicts, deleted, errors (rejected-but-kept rows), changed_list_ids, lists_changed
- SyncOutcome::mark_list_changed(&mut self, list_id) [private] — dedup-append a list id to changed_list_ids
- SyncConfig (pub struct, Default) — push_enabled flag + held_create_id (hold exactly ONE create whose id the UI holds; remap would invalidate it)
- SyncEngine (pub struct) — stateless engine over Arc<dyn GoogleTasksClient> + Store + SyncConfig
- SyncEngine::new(client, store) — construct with default config (push off)
- SyncEngine::with_push(client, store, push_enabled) — construct with explicit push flag
- SyncEngine::hold_create_id(self, Option<String>) -> Self — builder: set the one held create id
- SyncEngine::run(&self) async -> Result<SyncOutcome, SyncError> — single entry point: push→pull→D7 flatten; ALWAYS writes sync_log (counters, duration, error)

Significant private functions (each a distinct mechanism/pass):
- execute(&self, out) — orchestrates: push_all (if enabled) → pull_all → post-run D7 flatten over EVERY local list (invariant #1 must hold even when the pull was skipped, #150)
- push_all(&self, out) — push pass order: recover_inflight_creates; compute unresolved-create hold set; push_list_creates (skipped while any create is held); create loop in dependency order (parents first, each id attempted at most once/run to avoid double-insert); updates+deletes (skipping rows whose own create is unresolved in flight); push_moves; push_list_mutations
- row_push_failure(e, out, id, op) [static] — classify a push error via reconcile::push_failure and apply it
- apply_push_failure(failure, e, out, id, op) [static] — apply Retry (warn, stay dirty) / Abort (propagate, run dies) / Reject (count errors, continue)
- push_list_creates(&self, out) — push locally-created lists; adopt an existing same-title remote list (remap_list_id) instead of duplicating; tracks adopted ids so two same-title creates don't PK-collide
- push_list_mutations(&self, out) — list renames (patch_tasklist; 404 → DeleteLocal path re-homes never-pushed rows or revives the list as an unpushed create) and list deletes (plan_list_delete → DeleteLocal / Retry / Abort / Revive when server refuses e.g. the default list)
- recover_inflight_creates(&self, out) — crash recovery: for each in-flight create marker, fetch the complete remote list, find the orphan by BASE snapshot (falls back to content; keyed on parent, #145; completed orphans accepted under a parent, RFC-009 §G) and finish_create with the drain-time local_updated (#122/#124) so a mid-flight edit survives as an update; deleted-local + no-orphan → drop tombstone; no-orphan → clear marker and let push retry; held id is skipped
- ref_state_of(&self, Option<&str>) — RefState of a referenced task id for push-eligibility checks
- revert_local_move(&self, before) — undo the optimistic half of a refused/dropped move: CLEAN rows only, drop etag so the pull re-adopts server truth (P6)
- move_refs(&self, mv, before) — gather MoveRefs (task/parent/previous RefStates, task_has_children, parent_is_subtask) for reconcile::plan_move's third-level check
- apply_move_response(&self, before, remote) — adopt a landed move: clean row takes the whole body (server cascade may complete it), dirty row meta-only so its pending edit survives
- push_moves(&self, out) — pending-move drain via the move endpoint; plan_move → Drop / Refuse (revert + clear) / Wait / Send; degradation ladder (P5): ambiguous 404 with a previous → retry once as reparent-only; DropIntent / Retry / Abort / RejectAndDrop on errors
- push_create(&self, row, out) — anchor a subtask create after its last synced sibling; durably record_inflight_create BEFORE the non-idempotent insert; on success finish_create atomically remaps id + adopts etag/updated/server position, keeping a mid-flight re-edit dirty as an update; on error KeepInflight (transient) or ClearInflight+classified failure
- push_update(&self, row, out) — patch_task with If-Match; success adopts the RESPONSE BODY (server can coerce silently); 412 → resolve_conflict; 404 → hard-delete local subtree (P4, D3 rejected); else classified failure
- resolve_conflict(&self, local, out) — 412 pass: refetch canonical; tombstone/404 → delete-wins; base-snapshot merge (#118/D8: typed content unchanged vs base → local edit wins, checkbox too when base proves remote didn't move it) → keep dirty with fresh etag; else AdoptRemote (no divergence) or ConflictedCopy — remote lands via apply_pushed_task (detaches unknown parent, #155) and the local edit survives as a new "(conflicted copy)" create
- push_delete(&self, row, out) — unconditional delete (no If-Match by choice, probe 7); success/404 → hard-delete local (FK cascade takes subtree); else classified failure
- rehome_before_dropping(&self, ghost, survivors, out) — P2/D2: before a remotely-deleted list dies, move its NEVER-PUSHED rows into a surviving list; returns false when nowhere to put them (caller revives the list as an unpushed create)
- pull_all(&self, out) — pull pass: list_tasklists (transient → skip pull); upsert_list each; list ghost detection (clean local lists absent remotely → rehome-or-revive then delete, survivors exclude other ghosts); recompute dirty-id skip set AFTER push; build per-list in-flight-create base set; pull_list each
- pull_list(&self, list, dirty_ids, inflight, out) — fetch all pages; reconcile::pull_batch skips dirty rows + in-flight orphans, orders parents before children (FK safety); per-row plan_pull_row → Skip / Upsert / UpsertDetached (unknown parent → parent=None, etag=None so it re-links later); race-safe upsert_remote_task; ghost removal only when the page walk was complete
- repair_third_level(&self, list_id, third_level, out) — D7 flatten (invariant #1 absolute): synced grandchild + push off → promote_and_detach locally, server move deferred; synced + push on → corrective move_task(top-level) then promote_local_if_nested, on failure promote_and_detach anyway (transient re-detects next run, permanent ghost-removes); un-pushed create → promote_local_if_nested so it pushes top-level. Every repair counts as a conflict (never silent)
- promote_local_if_nested(&self, id) — set a nested row's parent to None keeping everything else (etag, pending op)
- promote_and_detach(&self, id) — promote to top-level AND drop etag for CLEAN rows only (dirty rows keep the etag so their retry patch stays If-Match-guarded)
- fetch_all_tasks(&self, list_id) -> (Vec<Task>, complete: bool) — paginate list_tasks; transient mid-scroll returns partial + complete=false (never treated as a wipe)
- build_etag_map(&self, list_id) — task_id → etag idempotency map; rows without a stored web_view_link are excluded so they re-pull once (backfill)
- remove_ghosts(&self, list_id, remote_ids, out) — delete clean local rows absent from a COMPLETE remote view (remove_ghost_task is clean-guarded: a live re-dirty cancels it; FK cascade takes the subtree)
- upsert_list(&self, list) -> bool — reconcile one remote list: KeepLocal (dirty local wins) / AdoptLocalCreate (remap by title) / Upsert (race-safe)

TESTS (in-file #[cfg(test)] mod tests) — helpers: engine, engine_with_push, dirty_task, stage_edit, completed, tombstone, remote_gone, local_move, remote_order, local_order, remote_parent, assert_at_most_one_level, dirty_list, placement, sidebar, tombstone_list.

Push tests:
- push_disabled_does_not_push — push off means zero insert calls
- push_create_remaps_id — create remaps local UUID to server id
- crash_during_create_adopts_orphan_no_duplicate — inflight recovery adopts server orphan, no re-insert
- crash_before_insert_reached_server_reinserts — no orphan: marker cleared, normal push inserts
- clean_create_clears_inflight_marker — happy create leaves no marker
- create_commit_then_response_timeout_does_not_duplicate — lost insert response never duplicates; next run adopts
- inflight_create_waits_when_recovery_view_is_incomplete — unresolved marker holds its create back
- move_response_body_is_adopted_so_a_server_cascade_cannot_stick — clean row adopts move body (cascade completion)
- move_whose_anchor_was_deleted_does_not_retry_forever — pure reorder loses its anchor: intent drains
- move_whose_previous_vanished_still_pushes_the_reparent — keep reparent, drop only ordering half
- move_whose_target_parent_vanished_is_dropped — dead target parent: intent dropped, no 400
- inflight_recovery_leaves_the_held_create_id_alone — held row's marker waits for hold release
- create_push_interleaved_with_reedit_keeps_edit_as_update_no_dup — mid-flight re-edit survives as update, no duplicate
- push_create_parent_before_child — dependent creates land in dependency order
- push_update_clears_dirty — successful update marks row clean
- push_update_412_real_conflict_preserves_both — genuine divergence: canonical remote + conflicted copy
- conflicted_copy_detaches_when_the_remote_parent_is_unknown_locally — #155: 412 canonical with unknown parent detaches, no FK abort
- push_update_412_identical_edit_no_copy — identical content 412 adopts etag, no copy
- lost_patch_response_self_content_412_converges_no_copy — lost PATCH response, self-content 412 converges clean

RFC-009 §B/§C matrix (edit/complete crossings):
- edit_vs_remote_move_no_false_conflicted_copy — remote move is not a content conflict
- edit_vs_remote_delete_discards_edit_and_row_disappears — P4 delete wins over local edit
- edit_412_then_refetch_tombstone_delete_wins_no_resurrected_copy — 412×delete race: tombstone refetch, no resurrection
- edit_vs_remote_parent_cascade_delete_discards_edit — parent's remote delete cascades our edited child
- complete_vs_remote_edit_produces_conflicted_copy — title+status diverge: copy forked (D1 stays narrow)
- status_only_divergence_remote_wins_no_copy — D1: checkbox-only difference, remote wins outright
- d8_status_only_toggle_survives_a_bare_remote_reorder — D8: base proves reorder, local completion wins
- d8_rename_and_completion_both_survive_a_bare_remote_reorder — #118+D8: both local edits win a bare reorder
- complete_vs_remote_delete_row_gone — P4: completion lost with remotely deleted row

RFC-009 §D matrix (local delete × remote):
- delete_vs_remote_edit_delete_wins — unconditional delete beats a remote rename
- delete_vs_remote_status_change_delete_wins — delete beats remote complete/reopen, no D1 leak
- delete_vs_remote_move_and_reparent_delete_wins — delete by id regardless of remote placement
- delete_parent_takes_a_remote_born_subtask_with_it — server cascade kills unseen remote child
- delete_subtask_vs_remote_edit_leaves_the_parent_intact — child delete never dirties/cascades parent
- delete_parent_with_an_unpushed_child_converges — create-then-cascade converges, nothing stranded
- conflicted_copy_pushes_then_converges — the forked copy itself pushes and goes clean
- push_update_into_a_remotely_deleted_list_deletes_local — genuine PATCH 404 (dead list) → DeleteLocal
- push_update_412_transient_get_task_stays_dirty_then_resolves — transient conflict refetch defers, edit kept
- push_update_412_non_transient_get_task_aborts_preserving_edit — hard refetch error aborts run, edit intact
- push_update_of_a_soft_deleted_task_converges_via_ghost — 200-ignored PATCH, ghost detection removes row
- push_delete_removes_local — confirmed delete hard-deletes locally
- push_create_transient_leaves_dirty — one attempt/run, dirty + inflight marker kept
- push_delete_transient_leaves_tombstone — transient delete keeps tombstone for retry
- push_delete_not_found_hard_deletes_local_without_error — 404 delete is success
- unauthorized_aborts_the_run_leaving_rows_dirty — 401 aborts on first sight
- push_to_unknown_list_is_counted_not_fatal — poisoned row counted, run continues
- oversize_field_push_is_rejected_every_run_never_wedges — #146: forever-Reject loop never wedges queue
- push_multiple_edits_coalesce — only the final edit is pushed

Real-API semantics (verified live):
- bare_due_date_is_normalized_on_push_not_rejected — bare YYYY-MM-DD canonicalized on create
- bare_due_date_on_update_is_normalized_too — same on update
- clearing_due_date_pushes_successfully — due=None round-trips
- conflict_412_with_only_due_format_difference_is_not_a_conflict — .000Z vs Z is not divergence
- crash_adoption_matches_across_due_normalization — orphan match survives due normalization
- poisoned_row_does_not_starve_other_pushes_or_pull — rejection doesn't block pipeline
- auth_expired_aborts_the_run_instead_of_grinding_through_rows — invalid_grant aborts immediately
- child_create_waits_for_unresolved_parent — child never pushed with local parent id
- three_level_creates_resolve_in_one_run — create loop resolves arbitrary nesting in one run
- pull_multilevel_nesting_is_fk_safe_and_d7_flattens_the_third_level — hostile order pulls FK-safe; D7 flattens read-only
- move_push_preserves_pending_content_edit — landed move keeps the pending edit dirty
- created_task_adopts_server_assigned_position — insert response position adopted
- server_coercion_in_patch_response_is_adopted — response body is the truth
- move_for_unsynced_task_waits_for_its_create — move with local UUID waits, ids remapped later
- subtask_creates_land_in_creation_order — previous-anchor keeps creation order on server
- two_same_title_local_list_creates_do_not_collide — second create inserts, no PK collision
- refused_list_delete_revives_the_list_instead_of_nagging_forever — default-list delete refusal revives
- pull_detaches_task_whose_parent_is_unknown_instead_of_failing — read-only pull detaches child of unrecovered orphan

Pull tests:
- pull_seeds_store — initial pull stores tasks
- pull_backfills_missing_web_view_link_without_etag_change — NULL link re-pulls once
- pull_upserts_lists — lists pulled
- pull_multiple_lists — tasks land in their own lists
- pull_parents_before_children — FK-safe ordering
- pull_skips_dirty_rows — dirty local edit never clobbered
- pull_updates_when_remote_etag_differs — etag change re-pulls row
- pull_handles_pagination — every page iterated
- pull_incomplete_pagination_never_ghosts_real_rows — mid-scroll fault suppresses ghost removal
- pull_first_page_failure_is_empty_but_incomplete_not_a_server_wipe — empty+incomplete is "learned nothing"

Ghost detection:
- ghost_rows_deleted — clean row absent remotely is removed
- ghost_detection_preserves_dirty_rows — local-only dirty create survives
- ghost_detection_skipped_on_transient — faulted list fetch skips ghosting
- ghost_detection_per_list — removal scoped to the affected list
- ghost_removal_completeness_is_isolated_per_list — completeness decided per list, not per run

Idempotency & transient handling:
- second_sync_is_noop — quiescent run does nothing
- transient_list_tasklists_error_not_fatal — transient list fetch skips pull, no error

Sync log:
- sync_log_written_on_success — counters recorded
- sync_log_written_on_error — error string recorded

Move (reorder / reparent):
- push_move_calls_move_api_and_clears — move endpoint hit, intent cleared
- push_move_disabled_when_push_off — intent preserved with push off
- push_move_not_found_drops_intent — stale move dropped, not retried forever
- push_move_transient_retries — transient keeps the intent

RFC-009 §E/§F matrix (moves × remote):
- reorder_vs_remote_reorder_last_writer_wins_and_converges — no etag on moves: last writer wins
- reorder_vs_remote_content_edit_keeps_both — move body brings the rename, ordering lands
- move_whose_previous_died_remotely_keeps_the_reparent — ambiguous 404: retry reparent-only (P5 ladder)
- move_404_without_a_previous_drops_the_intent_and_the_run_goes_on — no previous: 404 means subject gone
- reorder_vs_remote_delete_of_the_moved_task_drops_the_intent — 400 unknown subject: drop, pull removes row
- demote_under_a_parent_deleted_remotely_converges_in_both_orders — both serializations converge (400 and 404 injected)
- demote_under_a_remotely_completed_parent_arrives_completed — move response cascade adopted (P6)
- demote_of_a_task_that_gained_a_remote_subtask_is_refused — client-side third-level refusal, local reverted
- a_refused_move_leaves_a_pending_content_edit_alone — dirty row keeps etag; If-Match guard survives
- demote_under_a_task_that_became_a_subtask_remotely_is_refused — target parent became subtask: refused

D7 third-level repair:
- d7_repairs_a_remote_born_third_level_after_our_demote_landed — pull promotes remote-born grandchild + corrective move
- d7_flattens_a_pulled_third_level_locally_even_with_push_disabled — #137: local flatten regardless of push
- d7_repairs_our_queued_subtask_create_under_a_remotely_demoted_parent — §G: our own third level repaired in one round-trip
- d7_promotes_a_still_unpushed_subtask_create_locally — held create promoted locally, pushes top-level
- d7_third_level_repair_defers_to_a_racing_promotion_pulled_first — racing promotion: no redundant move
- d7_corrective_move_on_an_already_top_level_row_is_an_accepted_no_op — pins the API contract D7 leans on
- d7_transient_move_failure_still_flattens_locally_then_converges — flatten locally now, retry converges server
- d7_permanent_move_failure_flattens_locally_on_a_partial_pull — vanished grandchild flattened, ghost-removed later
- d7_flattens_a_third_level_when_the_pull_is_skipped_by_a_list_fetch_fault — #150: flatten runs after EVERY sync
- d7_dirty_grandchild_keeps_its_etag_so_the_retry_push_stays_guarded — dirty grandchild keeps If-Match guard
- promote_vs_remote_delete_drops_the_intent_and_the_row_disappears — promote × remote delete: P4
- promote_vs_remote_reparent_last_writer_wins — promote written last wins
- a_content_edit_and_a_move_on_the_same_row_both_land_in_one_run — updates-then-moves, both land coherently

List sync:
- push_list_create_remaps_and_tasks_follow — list create remaps id, queued tasks follow
- held_edit_holds_list_create_then_pushes_on_release — held edit freezes list creates that run
- push_list_rename — rename lands, row clean
- push_list_delete — delete lands both sides
- push_list_rename_not_found_hard_deletes_local — 404 rename converges by deleting locally
- push_list_rename_not_found_rehomes_the_rows_the_server_never_saw — §I×P2: unpushed rows re-home first
- push_list_rename_not_found_keeps_the_list_when_there_is_nowhere_to_rehome — no survivor: list revived as create
- push_list_rename_transient_stays_dirty_then_converges — 503 rename retries next run
- push_list_delete_transient_leaves_tombstone — transient list delete keeps tombstone
- push_list_delete_auth_abort_leaves_tombstone — 401 aborts, tombstone survives
- pull_adopts_local_create_by_title — offline "My Tasks" adopts remote same-title list
- pull_preserves_locally_renamed_list — dirty local rename not clobbered by pull
- pull_removes_ghost_list_and_its_tasks — remote list delete cascades locally
- ghost_detection_spares_local_only_list — local_only lists never ghosted
- push_skips_local_only_list_and_its_tasks — local_only never pushed

§G — local create × remote (P2):
- create_in_remotely_deleted_list_rehomes_to_default_list_still_dirty — unpushed create re-homes, then pushes
- rehome_keeps_an_unpushed_subtree_together_but_the_orphan_dies_with_its_parent — subtree re-homes intact; D3 rejected
- rehome_with_nowhere_to_go_keeps_the_list_as_an_unpushed_create — only list deleted: kept and re-created
- edited_parent_deleted_remotely_takes_its_unpushed_subtask_with_it — 404-update cascade takes unpushed child
- synced_row_in_remotely_deleted_list_dies_with_the_list — P2 shields only never-seen work
- subtask_create_parent_deleted_remotely_dies_with_its_parent — D3 rejected: child dies, no promotion
- subtask_create_parent_completed_remotely_converges_no_wedge — insert accepted, cascade completion adopted
- create_racing_identical_remote_create_both_live_no_content_dedup — adoption is marker-scoped, not content dedup
- held_create_survives_remote_list_delete_and_pushes_after_release — held row re-homes without id remap
- crash_between_rehome_and_push_converges_no_duplicate — inflight marker survives re-home; orphan adopted
- a_fatal_abort_mid_push_leaves_a_partial_push_the_next_run_heals — #143: partial push heals in one healthy run

RFC-009 §I matrix (list ops × remote):
- a_list_rename_race_lands_last_writer_wins_with_no_conflicted_copy — D6: no list conflict machinery exists
- a_remote_rename_after_ours_landed_wins_on_the_next_pull — remote rename silently wins (D6)
- a_locally_deleted_list_takes_remotely_added_tasks_with_it — server cascade; no local orphan row
- a_pending_list_delete_hides_the_list_while_the_push_retries — tombstoned list invisible while retrying
- a_list_delete_that_already_happened_remotely_is_a_success — 404 clears the tombstone
- a_local_list_create_adopts_a_same_title_list_created_remotely — adoption carries queued tasks along

RFC-009 §A (completed/hidden rows):
- a_task_completed_remotely_is_pulled_not_ghost_deleted — showCompleted/showHidden keeps done rows alive
- a_completed_subtask_survives_the_pull_still_attached — completed child stays attached, parent untouched

Mid-run interleave (fake's on_call hook):
- remote_delete_between_two_pull_lists_is_invisible_this_run_then_reconciles — mid-run server delete converges next run
- remote_create_landing_mid_pull_is_pulled_in_the_same_run — server growth mid-run picked up same run

NOTES:
- Phase map of one `run()`: (1) inflight-create recovery = recover_inflight_creates (orphan adoption by base snapshot; held id skipped; unresolved markers hold their creates); (2) list-create push + title adoption = push_list_creates (skipped whole while held_create_id is set); (3) task CREATE pass = the loop in push_all (dependency-ordered, once-per-run attempted set, held id skipped) + push_create; (4) update/delete pass = push_update / push_delete (skipping rows with unresolved inflight markers); 412 conflicted-copy creation = resolve_conflict (+ reconcile::conflicted_copy, #118/D8 base-snapshot merge); (5) pending-move drain = push_moves + move_refs/plan_move + revert_local_move + apply_move_response (P5 two-rung degradation ladder); (6) list rename/delete push = push_list_mutations (after task ops so tombstones push first); (7) PULL pass = pull_all (list upsert/adoption, list ghost detection + rehome_before_dropping, dirty/inflight skip sets) → pull_list (pull_batch ordering, unknown-parent detach, per-list-complete ghost removal via remove_ghosts); (8) D7 third-level flatten = execute's post-pull loop → reconcile::third_level_ids → repair_third_level (+ promote_local_if_nested / promote_and_detach), running over ALL lists after EVERY sync.
- There is NO attention/backoff mechanism in this file — retry is purely "row stays dirty, next run retries"; permanent rejections (PushFailure::Reject) re-push and re-fail every run forever by design (#146), surfaced only via SyncOutcome.errors. Fatal classes (Unauthorized/AuthExpired, non-transient unknowns via Abort) abort the whole run on first sight.
- Every *decision* lives in `super::reconcile` (pure, per RFC-009 rows); the engine only observes and applies. A porter must keep that split: engine.rs is deliberately branch-free on policy.
- Cross-file coupling: reconcile (ConflictResolution, CreateFailure, DeleteAction, ListDeleteAction, ListPullAction, ListRenameFailure, MoveAdoption, MoveFailure, MoveIntent, MoveRefs, PullRowAction, PushFailure, RefState, RefetchFailure, UpdateFailure, InflightBase, PullRowContext, plus fns third_level_ids/create_is_eligible/parent_is_pushable/mutation_is_pushable/adoptable_list/on_list_rename_error/plan_list_delete/find_orphan(_by_base)/plan_move/move_previous_id/on_move_error/move_adoption/create_previous_anchor/create_payload/on_create_error/update_patch/on_update_error/on_conflict_refetch_error/only_local_diverged/same_content/resolve_conflict/conflicted_copy/plan_delete/rehome_target/pull_batch/plan_pull_row/plan_list_pull); api (ApiError with is_transient, GoogleTasksClient, InMemoryClient in tests); store (Store: write_sync_log, all_lists, list_tasks, drain_dirty(_lists), inflight_creates, inflight_base_local_updated, base_snapshot, find_task_any, finish_create, clear_inflight_create, record_inflight_create, delete_task_hard, delete_list_hard(_if_clean), remap_list_id, mark_list_clean, upsert_list/task, upsert_remote_list/task, apply_pushed_task, refresh_task_meta, clear_move, pending_moves, rehome_unpushed_tasks, has_unpushed_tasks, clean_list_ids, clean_task_ids_for_list, dirty_ids, remove_ghost_task; PendingMove, StoredTask, StoredTaskList, SyncState); model (Task, TaskList, BaseSnapshot); uuid for conflicted-copy ids.
- Key invariants stated in doc comments: invariant #1 (at most one nesting level) is ABSOLUTE and locally enforced even on read-only syncs (#137) and even when the pull is skipped (#150); P2/D2 (remote events never destroy never-pushed work → rehome or revive the list); P4 delete-wins with FK subtree cascade (D3 auto-promotion REJECTED); P5 degrade-never-wedge for moves; P6 etag must never outrun content (response bodies adopted; refused/failed placements drop the CLEAN row's etag, dirty rows keep theirs for If-Match); P7 convergence/fixpoint; P8 at-least-once create safety via durable inflight markers + base-snapshot orphan adoption; creates attempted at most once per run; list creates held while any create is held (a list-id remap would invalidate the held row); ghost removal only on a COMPLETE per-list page walk; web_view_link NULL forces a one-time re-pull backfill; move endpoint has no etag (last-writer-wins) and tasklist PATCH ignores If-Match (D6 — lists can never fork conflicted copies).
- run() writes the sync_log row ALWAYS, success or failure (counters + duration + optional error string).


## src/sync/reconcile.rs (2382)
PURPOSE: Pure `(state, observation) → action` sync decision core (RFC-009): every conflict-matrix choice, no IO/async/store/client.
PUBLIC SURFACE:
- RefState (enum: Missing/Local/Synced) — push-pipeline progress of a referenced task id
- RefState::of(Option<&StoredTask>) -> Self — classify a row by etag presence
- PushFailure (enum: Retry/Reject/Abort) — how a failed row push resolves
- push_failure(&ApiError) -> PushFailure — classify one row's push failure
- UpdateFailure (enum: ResolveConflict/DeleteLocal/Failed(PushFailure)) — what a failed content-update does
- on_update_error(&ApiError) -> UpdateFailure — 412→conflict, 404→delete-local, else generic (§B)
- ConflictResolution (enum: AdoptRemote/ConflictedCopy) — how a 412 resolves
- resolve_conflict(&Task, &Task) -> ConflictResolution — typed-content-equal adopts remote; divergent forks copy (P3/D1)
- RefetchFailure (enum: DeleteLocal/StayDirty/Abort) — failed 412 refetch outcome
- on_conflict_refetch_error(&ApiError) -> RefetchFailure — 404 delete-local, transient stay-dirty, else abort
- update_patch(&StoredTask) -> TaskPatch — canonicalize due, clear notes as "", build PATCH
- conflicted_copy(&StoredTask, &Task, String) -> StoredTask — surviving local edit as unpushed "(conflicted copy)" create
- DeleteAction (enum: HardDeleteLocal/Failed(PushFailure)) — delete push outcome
- plan_delete(Option<&ApiError>) -> DeleteAction — success or 404 hard-deletes; else generic (§D, P4)
- create_is_eligible(pending_op, id, attempted, unresolved_inflight, held) -> bool — id-only create gate: no retry, no inflight, no held id (§G)
- mutation_is_pushable(id, unresolved_inflight) -> bool — update/delete waits while own create unresolved
- parent_is_pushable(Option<RefState>) -> bool — subtask create waits for synced parent
- create_previous_anchor(&StoredTask, &[StoredTask]) -> Option<String> — last synced same-parent sibling to anchor insert
- create_payload(&StoredTask, Option<String>) -> NewTask — insert payload with canonicalized due, anchor
- CreateFailure (enum: KeepInflight/ClearInflight(PushFailure)) — failed create's marker fate
- on_create_error(&ApiError) -> CreateFailure — transient keeps inflight marker; else clears (§G)
- find_orphan(local, remote, known_local_ids) -> Option<&Task> — committed create by CURRENT content + same parent (#145)
- find_orphan_by_base(base, parent, remote, known_local_ids) -> Option<&Task> — committed create by BASE snapshot; tolerates completed-parent cascade (#122)
- base_matches_create(base, parent, r) -> bool (PRIVATE) — base-vs-remote match; parent identity, typed content, cascade-tolerant status
- MoveRefs (struct: task, parent, previous, task_has_children, parent_is_subtask) — a pending move's ref states
- MoveIntent (enum: Send{keep_previous}/Drop/Refuse/Wait) — what to do with a pending move
- plan_move(MoveRefs) -> MoveIntent — degrade-never-wedge move planner (§E/§F, P5, invariant #1)
- move_previous_id(&PendingMove, MoveIntent) -> Option<String> — previous id to send per plan
- MoveAdoption (enum: Body/MetaOnly) — how much of move response to adopt
- move_adoption(Option<&StoredTask>) -> MoveAdoption — clean row adopts body; dirty keeps edit (P6)
- MoveFailure (enum: DropPreviousAndRetry/DropIntent/Retry/Abort/RejectAndDrop) — failed move outcome
- on_move_error(&ApiError, sent_previous) -> MoveFailure — 404 ambiguity ladder; else push_failure mapping
- adoptable_list(title, remote, tracked_local_ids) -> Option<&TaskList> — same-title untracked remote list to adopt (§I)
- ListRenameFailure (enum: DeleteLocal/Failed(PushFailure)) — failed list rename outcome
- on_list_rename_error(&ApiError) -> ListRenameFailure — 404 delete-local, else generic
- ListDeleteAction (enum: DeleteLocal/Retry/Abort/Revive) — list delete push outcome
- plan_list_delete(Option<&ApiError>) -> ListDeleteAction — success/404 delete; reject revives list (§I)
- rehome_target(&[StoredTaskList], dying_list_id) -> Option<&StoredTaskList> — deterministic default-list target for unpushed rows of remotely-deleted list (§G3, D2)
- InflightBase (struct: base, parent) — in-flight create's base snapshot + remote parent id
- pull_batch(Vec<Task>, dirty_ids, &[InflightBase]) -> Vec<Task> — filter dirty + inflight orphans, order parents first (§A)
- PullRowContext (struct: local_etags, batch_ids, known_local) — inputs for plan_pull_row
- PullRowAction (enum: Skip/Upsert/UpsertDetached) — what a pulled row does locally
- plan_pull_row(&Task, &PullRowContext) -> PullRowAction — etag skip; detach child with absent parent (FK safety)
- third_level_ids(&[StoredTask]) -> Vec<String> — grandchildren under CLEAN subtask parents, for D7 repair
- is_up_to_date(id, remote_etag, local_etags) -> bool — matching non-null etags means skip
- ListPullAction (enum: KeepLocal/AdoptLocalCreate{local_id}/Upsert{changed}) — remote list reconciliation
- plan_list_pull(&TaskList, &[StoredTaskList]) -> ListPullAction — dirty keeps local; title-match adopts create; else upsert (§A/§I)
- same_content(&Task, &Task) -> bool — title/notes/due/status equal, normalization-tolerant; never position/parent/etag
- only_local_diverged(&Task, &BaseSnapshot) -> bool — remote typed content equals base (status excluded) (#118)
- same_typed_content(&Task, &Task) -> bool — title/notes/due only (checkbox ignored, D1)
- order_parents_first(Vec<Task>) -> Vec<Task> — Kahn-style topo order; cycles appended, never dropped
- const DEFAULT_LIST_TITLE = "My Tasks" (PRIVATE) — re-home preference; matches state.rs::ensure_default_list
TESTS (in-file #[cfg(test)] mod tests — single module; helpers task/stored/ids/list/stored_list/refs/child):
- push_failure_classification — transient retry, auth abort, 400 reject
- update_412_resolves_a_conflict — 412 maps to ResolveConflict
- update_404_hard_deletes_local_delete_wins — PATCH 404 deletes locally (P4)
- update_other_errors_defer_to_push_failure — other errors use push_failure mapping
- conflict_with_identical_content_adopts_remote_no_copy — identical content absorbs etag drift
- conflict_ignores_due_normalization_and_empty_notes — normalization never manufactures a copy
- conflict_ignores_position_and_parent_so_a_remote_move_makes_no_copy — remote move never forks copy
- conflict_with_divergent_title_preserves_both — divergent title forks conflicted copy
- status_only_divergence_resolves_remote_wins_no_copy — D1: checkbox-only diff, remote wins
- status_divergence_alongside_content_divergence_still_preserves_both — D1 narrow; typed diff still forks
- d1_does_not_leak_into_orphan_adoption — top-level adoption keeps status strict
- only_local_diverged_true_for_a_bare_remote_reorder — structural/status changes aren't typed divergence
- find_orphan_by_base_adopts_despite_a_mid_flight_edit — base matches when live content drifted
- find_orphan_by_base_tolerates_the_completed_parent_cascade — subtask cascade status tolerated; top-level strict
- find_orphan_requires_matching_parent — wrong-parent same-content rows never adopted
- find_orphan_by_base_requires_matching_parent — base-layer adoption keys on parent identity
- pull_batch_pulls_a_foreign_duplicate_under_a_different_parent — foreign duplicate pulled, not withheld
- conflict_refetch_failures — 404 delete, transient stay-dirty, else abort
- update_patch_canonicalizes_due_and_clears_notes — bare date canonicalized; notes cleared as ""
- update_patch_degrades_an_unparseable_due_to_clear — bad due sent as clear
- conflicted_copy_is_an_unpushed_create_that_keeps_the_local_edit — copy is dirty pending create
- delete_succeeds_and_404_counts_as_success — 404 equals success for delete
- delete_wins_in_both_directions — P4 pinned; no-parameter design is the pin
- delete_failures_defer_to_push_failure — delete errors use push_failure mapping
- create_eligibility_gate — attempted/inflight/held ids block creates
- a_mutation_waits_while_its_own_create_is_unresolved_in_flight — unresolved create blocks its mutations
- subtask_create_waits_for_an_unpushed_parent — local/missing parent blocks child push
- ref_state_reads_etag_presence — RefState classification by etag
- subtask_create_anchors_after_its_last_synced_sibling — anchor is last synced same-parent sibling
- create_payload_canonicalizes_due_and_carries_the_anchor — payload canonicalization plus previous anchor
- transient_create_failure_keeps_the_inflight_marker — transient keeps marker; others clear
- orphan_adoption_is_scoped_to_content_and_unknown_ids — no dedup of legal duplicates
- move_with_all_ids_synced_is_sent_whole — synced refs send whole move
- move_whose_target_parent_vanished_is_dropped — missing target parent drops intent
- move_whose_previous_vanished_degrades_to_the_reparent — missing previous keeps reparent only
- move_waits_while_any_named_id_is_still_local — unsynced ids hold the intent
- a_vanished_previous_does_not_rescue_an_unsynced_parent — degraded move still waits on parent
- move_previous_id_follows_the_plan — previous id sent only when kept
- move_adopts_the_body_only_for_a_clean_row — dirty row keeps its pending edit
- move_failures — 404/transient/auth/reject move mappings
- a_move_404_is_ambiguous_only_while_a_previous_was_sent — drop-previous-and-retry ladder scoping
- a_demote_that_would_create_a_third_level_is_refused — invariant #1 enforced client-side
- a_promote_or_reorder_of_a_parent_task_is_still_allowed — refusal is depth, not children
- list_create_adopts_a_same_title_remote_list_once — adopt once, never collide tracked ids
- list_rename_failures — 404 delete-local; others generic
- list_delete_outcomes — success/404 delete, transient retry, reject revives
- pull_batch_skips_dirty_rows_and_inflight_orphans — dirty and orphan rows withheld
- pull_batch_skips_an_inflight_orphan_edited_during_the_window — base match withholds drifted orphan
- pull_batch_skips_a_completed_subtask_orphan_under_a_completed_parent — cascade-tolerant withholding
- pull_batch_orders_parents_before_children_at_any_depth — topological pull order
- order_parents_first_appends_a_cycle_instead_of_dropping_it — cycles never drop rows
- pull_row_skips_only_on_a_matching_etag — null local etag never skips
- pull_row_detaches_a_child_whose_parent_is_nowhere_yet — detach preserves FK; relinks later
- list_pull_preserves_a_locally_renamed_list — dirty list keeps local intent
- list_pull_adopts_an_unpushed_local_create_by_title — offline bootstrap adopted by title
- list_pull_adopts_a_remote_rename_even_when_the_etag_is_unchanged — lists compared by title, not etag (D6)
- rehome_target_prefers_the_default_list — "My Tasks" wins as target
- rehome_target_falls_back_to_the_first_list_deterministically — alphabetical, id-tiebroken fallback
- rehome_target_skips_lists_that_cannot_keep_the_work — local-only and tombstoned excluded
- rehome_target_never_returns_the_dying_list — dying list excluded from candidates
- list_pull_reports_whether_anything_changed — changed flag on visible metadata diff
- conflicted_copy_stacks_its_suffix_and_survives_an_empty_title — suffix stacks; empty title safe
- content_comparison_treats_empty_notes_as_cleared_notes — Some("") equals None for notes
- same_content_covers_exactly_title_notes_due_status — field coverage pinned exactly
- third_level_ids_flags_only_the_grandchild — only C in P>T>C flagged
- third_level_ids_is_empty_for_a_legal_one_level_tree — happy shape needs no repair
- third_level_ids_ignores_a_row_whose_parent_is_absent — detached child not a grandchild
- third_level_ids_skips_an_optimistic_demote_of_the_middle_row — dirty middle never triggers repair
- third_level_ids_flags_a_still_queued_subtask_create_under_a_clean_subtask — queued create still flagged
- third_level_ids_flags_every_clean_row_below_the_first_level — four-deep chain fully flagged
NOTES:
- Extraction-only module: every branch moved verbatim from engine.rs; section markers (§A/§B/…) index designs/RFC-009-sync-conflict-matrix.md. Engine keeps observe/apply; this module is decide.
- Cross-file coupling: crate::api::ApiError (is_transient()), crate::model (Task, TaskList, NewTask, TaskPatch, TaskStatus, BaseSnapshot), crate::store (StoredTask, StoredTaskList, PendingMove, SyncState), crate::dates::normalize_due; DEFAULT_LIST_TITLE mirrors state.rs::ensure_default_list; repair driver is engine::SyncEngine::repair_third_level; delete unconditionality also pinned in api::http (delete_task_sends_no_if_match).
- Principles referenced throughout: P2 (never destroy unpushed local edit), P3 (nothing silently discarded — conflicted copy), P4 (delete wins both directions, unconditional DELETE), P5 (moves degrade, never wedge), P6 (adopt response body, not just etag). Decisions D1 (status-only conflict = remote wins), D2 (re-home to default list), D6 (list rename remote-wins, compared by title not etag), D7 (pull-side third-level repair). Invariant #1: subtasks strictly one level — Google does NOT enforce it (probe 3: deep move returns 200), so plan_move refuses and third_level_ids repairs.
- CONFLICT-DECISION MATRIX MAP (which function implements which row):
  - Local-only change (push paths): update_patch + on_update_error (§B/§C content edit); create_is_eligible/parent_is_pushable/create_previous_anchor/create_payload/on_create_error (§G create); plan_delete (§D delete); plan_move/move_previous_id/on_move_error/move_adoption (§E/§F position+parent moves); adoptable_list/on_list_rename_error/plan_list_delete (§I list ops).
  - Remote-only change (pull paths): pull_batch + plan_pull_row + is_up_to_date + order_parents_first (§A row pull); plan_list_pull (§A/§I list pull, D6 remote-wins rename); third_level_ids (§F residual / §G race — remote demote creates illegal depth, D7).
  - Both-changed (conflict rows): on_update_error(PreconditionFailed) routes to resolve_conflict — same_typed_content equal → AdoptRemote (status-only: D1 remote wins), divergent → ConflictedCopy built by conflicted_copy (P3); only_local_diverged handles the 412-caused-by-move/cascade case (#118: keep and re-push local typed edit, adopt remote status); on_conflict_refetch_error covers the refetch leg.
  - Deletes crossing edits (P4): on_update_error(NotFound) + on_conflict_refetch_error(NotFound) → DeleteLocal (remote delete beats local edit); plan_delete ignores everything but the error (local delete beats remote edit — unconditional); plan_move Drop (target parent deleted) and MoveFailure::DropIntent/DropPreviousAndRetry (subject/previous deleted, ambiguous-404 ladder); on_list_rename_error(NotFound) → DeleteLocal; rehome_target (remote list delete × local unpushed rows, D2/P2); ListDeleteAction::Revive (server refuses local list delete).
  - Create races / crash recovery: find_orphan (current content), find_orphan_by_base + base_matches_create (base snapshot, #122 mid-flight edit, #145 parent identity, completed-parent cascade), InflightBase + pull_batch withholding (pull must not front-run recovery), mutation_is_pushable (mutations wait behind unresolved create marker), plan_list_pull::AdoptLocalCreate (list-level adoption).
- Oddities a porter must know: Google task deletes are SOFT — a PATCH to a remotely-deleted task returns 200 (ghost detection happens on the pull, not in on_update_error; its 404 branch actually means the LIST died). Move 404 is ambiguous (previous-not-found vs subject-gone) — resolved by experiment, not guess. Google 400s bare dates and local UUIDs ("Invalid task ID", permanent). "" clears due/notes. Conflicted-copy suffix stacks and is not idempotent (intended). rehome ordering key is (title != "My Tasks", title, id) for determinism. UpsertDetached drops the etag on purpose so the row re-links next pull.
