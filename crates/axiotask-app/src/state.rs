//! Application state: store, sync engine, and background scheduler.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Duration;

use tokio::sync::{Mutex, Notify};

use axiotask_core::api::{GoogleTasksClient, HttpClient, InMemoryClient};
use axiotask_core::auth::{
    AuthedClient, InMemoryTokenStore, OAuthConfig, RefreshFn, StoredTokens, TokenStore,
};
use axiotask_core::store::Store;
use axiotask_core::sync::{SyncEngine, SyncOutcome};

/// Debounce window: coalesce rapid mutations into a single sync.
const SYNC_DEBOUNCE: Duration = Duration::from_secs(2);
/// Periodic sync interval to catch remote changes.
const SYNC_PERIOD: Duration = Duration::from_secs(60);
/// Ceiling for the exponential backoff applied after a *permanent* sync
/// failure. A dead schema or corrupt store fails identically on every retry,
/// so the periodic cadence stretches from [`SYNC_PERIOD`] up to this cap
/// instead of hammering the same failure every minute forever.
const SYNC_MAX_BACKOFF: Duration = Duration::from_secs(60 * 60);

/// The periodic delay before the next background sync, given how many
/// consecutive *permanent* failures have occurred. `streak == 0` (healthy, or
/// only transient failures) keeps the base cadence; each permanent failure
/// doubles the delay, capped at [`SYNC_MAX_BACKOFF`]. A mutation trigger still
/// fires promptly (see [`wait_for_sync_trigger`]) — only the idle polling
/// cadence backs off, which is exactly the "retry the same failure every 60s
/// forever" churn this replaces.
fn backoff_period(base: Duration, streak: u32, cap: Duration) -> Duration {
    if streak == 0 {
        return base;
    }
    // 2^streak, saturating: at streak 1 the delay doubles, and a large streak
    // can never overflow the shift or the multiply — it just pins to the cap.
    let factor = 1u64.checked_shl(streak).unwrap_or(u64::MAX);
    let secs = base.as_secs().saturating_mul(factor);
    Duration::from_secs(secs).min(cap)
}

/// How to log one permanent sync failure, and what to remember for the next run.
struct PermanentFailureLog {
    /// Log this occurrence at ERROR (a first-time or *changed* failure) rather
    /// than DEBUG (an identical repeat that would otherwise spam the log every
    /// cadence tick).
    log_at_error: bool,
    /// The full typed detail (`SyncError::to_string`): written to the log AND
    /// kept as the dedup key for the next run. May carry raw SQL — never shown
    /// to the user.
    raw_detail: String,
    /// The sanitized, user-safe message for `last_error` (#128).
    user_msg: String,
}

/// Decide how to log a permanent sync failure and dedup it against the last one.
///
/// Dedup is keyed on the RAW typed detail, NOT the sanitized display message
/// (#131). Every store failure sanitizes to one calm sentence and every internal
/// failure to another (see [`sync_user_message`]), so two *distinct* root causes
/// routinely collapse to identical user-facing text. Keying the dedup on that
/// sanitized text would swallow a genuinely new failure as a "repeat" and bury
/// it at DEBUG. Keying on the raw detail gives every distinct failure its own
/// first-time ERROR line, while an *identical* failure that repeats every
/// cadence tick still drops to DEBUG so it stops burying everything else.
fn classify_permanent_failure(
    prev_attention: bool,
    prev_raw_error: Option<&str>,
    e: &axiotask_core::sync::SyncError,
) -> PermanentFailureLog {
    let raw_detail = e.to_string();
    let log_at_error = !prev_attention || prev_raw_error != Some(raw_detail.as_str());
    PermanentFailureLog {
        log_at_error,
        raw_detail,
        user_msg: sync_user_message(e),
    }
}

/// A user-safe description of a sync failure (#128, #135).
///
/// The `last_error` this produces is rendered verbatim in the "Sync failed"
/// toast and the Properties dialog. Anything that carries internal detail is
/// replaced with a calm sentence pointing at the log — the full typed error is
/// still written to the log at the call site:
///
/// - A store failure carries raw sqlx text ("sql: no such column: …").
/// - An internal error carries an assertion/bug string.
/// - `ApiError::Network` carries raw reqwest text, which can embed the full
///   request URL and its query params (#135).
///
/// The remaining API failures (5xx, rate-limit, precondition, …) are already
/// human and carry no internals, so their text is kept — the user still sees
/// "server error: 503" rather than a generic sentence.
fn sync_user_message(e: &axiotask_core::sync::SyncError) -> String {
    use axiotask_core::api::ApiError;
    use axiotask_core::sync::SyncError;
    match e {
        SyncError::Store(_) => {
            "Sync hit a local database problem — the details are in the log.".into()
        }
        SyncError::Internal(_) => {
            "Sync hit an unexpected internal error — the details are in the log.".into()
        }
        SyncError::Api(ApiError::Network(_)) => {
            "Can't reach Google right now — the details are in the log.".into()
        }
        SyncError::Api(_) => e.to_string(),
    }
}

/// File-based token store. Persists tokens as JSON to a file.
struct FileTokenStore {
    path: std::path::PathBuf,
}

impl FileTokenStore {
    fn new(path: &std::path::Path) -> Self {
        Self {
            path: path.to_owned(),
        }
    }
}

impl TokenStore for FileTokenStore {
    fn load(&self) -> Result<Option<StoredTokens>, axiotask_core::auth::AuthError> {
        match std::fs::read_to_string(&self.path) {
            Ok(s) => {
                let tokens: StoredTokens = serde_json::from_str(&s)
                    .map_err(|e| axiotask_core::auth::AuthError::Format(e.to_string()))?;
                Ok(Some(tokens))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(axiotask_core::auth::AuthError::Keyring(e.to_string())),
        }
    }

    fn save(&self, tokens: &StoredTokens) -> Result<(), axiotask_core::auth::AuthError> {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let json = serde_json::to_string_pretty(tokens)
            .map_err(|e| axiotask_core::auth::AuthError::Format(e.to_string()))?;
        std::fs::write(&self.path, json)
            .map_err(|e| axiotask_core::auth::AuthError::Keyring(e.to_string()))
    }

    fn clear(&self) -> Result<(), axiotask_core::auth::AuthError> {
        match std::fs::remove_file(&self.path) {
            Ok(()) | Err(_) => Ok(()),
        }
    }
}

/// Outcome of a [`AppState::restore_backup`] call, surfaced to the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RestoreSummary {
    /// Number of task lists written.
    pub lists: usize,
    /// Number of tasks written.
    pub tasks: usize,
}

/// Live sync status and running stats, surfaced to the Properties dialog.
///
/// Updated after every sync run (success or failure) so the UI can show when
/// the last sync happened, what it did, how many have run this session, and
/// the most recent error (if any).
#[derive(Debug, Clone, Default)]
pub struct SyncStatus {
    /// RFC-3339 timestamp of the last *successful* sync, if any.
    pub last_synced: Option<String>,
    /// Counts from the last successful sync.
    pub last_pulled: u32,
    pub last_pushed: u32,
    pub last_conflicts: u32,
    pub last_deleted: u32,
    /// Task rows changed in these list ids during the most recent successful
    /// sync. Lets the UI refresh affected lists instead of reloading all tasks.
    pub changed_list_ids: Vec<String>,
    /// List metadata or membership changed; the UI must reload list metadata.
    pub lists_changed: bool,
    /// Number of successful syncs since the app started.
    pub total_syncs: u64,
    /// Message from the most recent sync failure, cleared on the next success.
    /// This is the *sanitized*, user-safe text (#128) — it is what the UI shows.
    pub last_error: Option<String>,
    /// The RAW typed detail (`SyncError::to_string`) of the most recent
    /// *permanent* failure, kept ONLY to dedup log lines across cadence ticks
    /// (#131). Distinct from [`Self::last_error`]: two different root causes can
    /// sanitize to the same calm sentence, so the dedup key must be the raw
    /// detail or a genuinely new failure would be swallowed as a "repeat" and
    /// logged at DEBUG. May carry raw SQL, so it is never surfaced to the UI
    /// (it is deliberately absent from `SyncStatusView`). Cleared on success.
    pub last_raw_error: Option<String>,
    /// A *permanent* (non-transient, non-auth) failure is stuck — store
    /// corruption, a schema mismatch, a deserialization bug. Retrying is
    /// pointless until something changes, so the scheduler has backed off and
    /// the UI surfaces `last_error` as a "sync needs attention" state the user
    /// can act on. Distinct from a transient blip (silently retried, this stays
    /// false) and from a dead session ([`Self::needs_reauth`], its own state).
    /// Cleared by the first successful run.
    pub needs_attention: bool,
    /// The stored session is dead (token refresh permanently denied) — the
    /// user must sign in again. Mirrored into every status snapshot so the
    /// `sync-updated` event carries it and the main window can surface a
    /// re-auth action, not just an error string.
    pub needs_reauth: bool,
}

/// Notified after every sync run so the UI can react to background syncs, not
/// just manual "Sync now" clicks. The background loop otherwise updates status
/// silently and the UI goes stale. Abstracted behind a trait so sync
/// observability is unit-testable without a Tauri runtime (production wires a
/// Tauri event emitter; tests inject a recording spy).
pub trait SyncNotifier: Send + Sync {
    /// Called once after each sync run, with the resulting status snapshot
    /// (success updates counts/`last_synced`; failure sets `last_error`).
    fn notify_sync(&self, status: &SyncStatus);
}

/// Default notifier: does nothing. Used in tests and before the Tauri emitter
/// is wired at startup.
struct NoopSyncNotifier;
impl SyncNotifier for NoopSyncNotifier {
    fn notify_sync(&self, _status: &SyncStatus) {}
}

/// Shared application state managed by Tauri.
pub struct AppState {
    pub store: Store,
    client: Arc<Mutex<Arc<dyn GoogleTasksClient>>>,
    token_store: Arc<dyn TokenStore>,
    oauth_config: OAuthConfig,
    sync_notify: Arc<Notify>,
    /// Serializes sync runs — only one sync executes at a time (RFC-004).
    sync_guard: Arc<Mutex<()>>,
    /// Whether local changes are pushed to Google. Mutable at runtime via the
    /// Properties dialog (read-only vs. read-write sync) and persisted to the
    /// config file. Read on every sync run.
    push_enabled: AtomicBool,
    /// The id of the one task the UI is actively holding — the inline editor's
    /// row, or the open detail panel's task. Its CREATE push is held so an id
    /// remap can't invalidate the id the UI operates on. Every OTHER create
    /// still pushes, so a subtask created inside an open detail panel syncs
    /// (its own id remap never touches the parent id the panel holds). `None`
    /// when nothing is being edited. Pull is unaffected — it skips dirty rows.
    held_create_id: std::sync::Mutex<Option<String>>,
    /// Whether to sync automatically on startup. Persisted; display-only after
    /// launch (it only governs the startup sync).
    auto_sync_on_start: AtomicBool,
    /// Set when token refresh is permanently denied (`invalid_grant`: the
    /// refresh token expired or was revoked). Gates the background sync loop —
    /// retrying with a dead grant fails identically forever and spams the
    /// token endpoint. Cleared on re-login, logout, or a successful sync.
    /// Manual "Sync now" is deliberately NOT gated, so the user can always
    /// force a re-check.
    needs_reauth: AtomicBool,
    /// Count of consecutive *permanent* (non-transient, non-auth) sync
    /// failures. Drives the scheduler's exponential backoff
    /// ([`backoff_period`]) and is reset to 0 by the first successful run. A
    /// transient failure or a dead session leaves it untouched (they have
    /// their own handling), so a network blip never stretches the cadence.
    attention_streak: AtomicU32,
    /// Path to the config file, so settings changes persist to the right place.
    config_path: PathBuf,
    /// Path to the SQLite database (shown in the Properties dialog).
    db_path: PathBuf,
    /// Last sync outcome and running stats.
    sync_status: Mutex<SyncStatus>,
    /// Notified after each sync run (Tauri event emitter in production, no-op in
    /// tests until a spy is installed). Set once at startup.
    sync_notifier: std::sync::RwLock<Arc<dyn SyncNotifier>>,
}

impl AppState {
    /// Build state from a database path. Attempts to restore auth from keyring.
    pub async fn new(db_path: &std::path::Path) -> Result<Self, String> {
        // Ensure config file exists with defaults
        axiotask_core::config::AppConfig::write_default_if_missing();

        let pool = axiotask_core::store::open(db_path)
            .await
            .map_err(|e| e.to_string())?;
        let store = Store::new(pool);

        let config = axiotask_core::config::AppConfig::load();
        let oauth_config =
            OAuthConfig::google_tasks(&config.google.client_id, &config.google.client_secret);

        let token_store: Arc<dyn TokenStore> = Arc::new(FileTokenStore::new(
            &db_path.parent().unwrap().join("tokens.json"),
        ));

        // Try to restore existing session.
        let client: Arc<dyn GoogleTasksClient> = match token_store.load() {
            Ok(Some(tokens)) => {
                tracing::info!("restored auth session from tokens.json");
                Arc::new(build_http_client(
                    tokens,
                    token_store.clone(),
                    &oauth_config,
                ))
            }
            Ok(None) => {
                tracing::info!("no stored tokens, starting in offline mode");
                Arc::new(InMemoryClient::new())
            }
            Err(e) => {
                tracing::warn!("keyring error: {e}, starting in offline mode");
                Arc::new(InMemoryClient::new())
            }
        };

        let state = Self {
            store,
            client: Arc::new(Mutex::new(client)),
            token_store,
            oauth_config,
            sync_notify: Arc::new(Notify::new()),
            sync_guard: Arc::new(Mutex::new(())),
            push_enabled: AtomicBool::new(config.sync.push_enabled),
            held_create_id: std::sync::Mutex::new(None),
            auto_sync_on_start: AtomicBool::new(config.sync.auto_sync_on_start),
            needs_reauth: AtomicBool::new(false),
            attention_streak: AtomicU32::new(0),
            config_path: axiotask_core::config::AppConfig::default_path(),
            db_path: db_path.to_owned(),
            sync_status: Mutex::new(SyncStatus::default()),
            sync_notifier: std::sync::RwLock::new(Arc::new(NoopSyncNotifier)),
        };
        state.ensure_default_list().await;
        Ok(state)
    }

    /// Install the notifier called after each sync run. Called once at startup
    /// (main.rs) to wire the Tauri event emitter; tests use it to inject a spy.
    pub fn set_sync_notifier(&self, notifier: Arc<dyn SyncNotifier>) {
        *self.sync_notifier.write().unwrap() = notifier;
    }

    /// Build state with an in-memory database (for tests).
    #[allow(dead_code)]
    pub async fn new_memory(client: Arc<dyn GoogleTasksClient>) -> Result<Self, String> {
        Self::new_memory_inner(client, false).await
    }

    /// Build push-enabled in-memory state (for tests that exercise push).
    #[cfg(test)]
    pub async fn new_memory_with_push(client: Arc<dyn GoogleTasksClient>) -> Result<Self, String> {
        Self::new_memory_inner(client, true).await
    }

    #[allow(dead_code)]
    async fn new_memory_inner(
        client: Arc<dyn GoogleTasksClient>,
        push_enabled: bool,
    ) -> Result<Self, String> {
        let pool = axiotask_core::store::open_memory()
            .await
            .map_err(|e| e.to_string())?;
        let store = Store::new(pool);
        let token_store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());
        let oauth_config = OAuthConfig::google_tasks("test-client-id", "test-secret");

        let state = Self {
            store,
            client: Arc::new(Mutex::new(client)),
            token_store,
            oauth_config,
            sync_notify: Arc::new(Notify::new()),
            sync_guard: Arc::new(Mutex::new(())),
            push_enabled: AtomicBool::new(push_enabled),
            held_create_id: std::sync::Mutex::new(None),
            auto_sync_on_start: AtomicBool::new(true),
            needs_reauth: AtomicBool::new(false),
            attention_streak: AtomicU32::new(0),
            // A throwaway temp path so settings writes in tests never touch the
            // real user config.
            config_path: std::env::temp_dir()
                .join(format!("axiotask-test-{}.toml", uuid::Uuid::new_v4())),
            db_path: PathBuf::from(":memory:"),
            sync_status: Mutex::new(SyncStatus::default()),
            sync_notifier: std::sync::RwLock::new(Arc::new(NoopSyncNotifier)),
        };
        state.ensure_default_list().await;
        Ok(state)
    }

    /// Whether we have stored tokens (user is logged in).
    pub fn is_authenticated(&self) -> bool {
        matches!(self.token_store.load(), Ok(Some(_)))
    }

    /// Whether the stored session is dead (refresh permanently denied) and the
    /// user must sign in again. See the `needs_reauth` field.
    pub fn needs_reauth(&self) -> bool {
        self.needs_reauth.load(Ordering::Relaxed)
    }

    /// Direct token-store access for tests (e.g. seeding a signed-in state).
    #[cfg(test)]
    pub fn token_store_for_test(&self) -> &Arc<dyn TokenStore> {
        &self.token_store
    }

    /// Collect every task list and its tasks into a lossless backup snapshot.
    ///
    /// Pure data gathering — no IO beyond the store reads — so it can be unit
    /// tested without a Tauri runtime or the filesystem. The caller decides
    /// how to serialize and where to write.
    pub async fn build_backup(&self) -> Result<axiotask_core::export::Backup, String> {
        let lists = self.store.all_lists().await.map_err(|e| e.to_string())?;
        let mut pairs = Vec::with_capacity(lists.len());
        for list in lists {
            let tasks = self
                .store
                .list_tasks(&list.list.id)
                .await
                .map_err(|e| e.to_string())?;
            pairs.push((list, tasks));
        }
        let now = axiotask_core::dates::now_utc_string();
        Ok(axiotask_core::export::Backup::build(now, pairs))
    }

    /// Restore a backup into the local store (the inverse of [`build_backup`]).
    ///
    /// Non-destructive merge: restore the lists and tasks from the backup that
    /// are MISSING locally, and leave everything that exists alone. Counts in
    /// the summary are the rows actually restored.
    ///
    /// Restored rows come back as fresh local CREATES (etag stripped, dirty),
    /// NOT with their saved sync metadata. Restoring them "clean" with their
    /// old etags is a trap: the primary reason to restore a backup is that the
    /// data no longer exists on the server — and the very next sync's ghost
    /// detection would see clean rows absent from the server and silently
    /// delete everything the restore just brought back. As creates they push
    /// back to Google instead. If we're signed in, a sync runs first so
    /// "missing" is judged against the server's current truth, not a stale
    /// cache (this also prevents duplicating tasks that still exist remotely).
    pub async fn restore_backup(
        &self,
        backup: axiotask_core::export::Backup,
    ) -> Result<RestoreSummary, String> {
        if self.is_authenticated() {
            // Best effort — an offline restore still works against the cache.
            if let Err(e) = self.run_sync().await {
                tracing::warn!("pre-restore sync failed (continuing offline): {e}");
            }
        }
        let now = axiotask_core::dates::now_utc_string();
        let mut summary = RestoreSummary { lists: 0, tasks: 0 };
        let existing_lists: std::collections::HashSet<String> = self
            .store
            .all_lists()
            .await
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|l| l.list.id)
            .collect();

        for (list, tasks) in backup.into_stored() {
            if !existing_lists.contains(&list.list.id) {
                let mut l = list.clone();
                l.list.etag = None;
                l.sync_state = if l.local_only {
                    axiotask_core::store::SyncState::Clean
                } else {
                    axiotask_core::store::SyncState::Dirty
                };
                l.pending_op = (!l.local_only).then(|| "create".to_string());
                l.local_updated = now.clone();
                self.store
                    .upsert_list(&l)
                    .await
                    .map_err(|e| e.to_string())?;
                summary.lists += 1;
            }
            // Backup order is parents-before-children (export walks the store's
            // ordering), so a restored child finds its restored parent.
            for task in &tasks {
                if self
                    .store
                    .find_task_any(&task.task.id)
                    .await
                    .map_err(|e| e.to_string())?
                    .is_some()
                {
                    continue;
                }
                let mut t = task.clone();
                // Re-parent to top level if the parent exists neither locally
                // nor in this backup's restored set (FK safety).
                if let Some(p) = &t.task.parent
                    && self
                        .store
                        .find_task_any(p)
                        .await
                        .map_err(|e| e.to_string())?
                        .is_none()
                {
                    t.task.parent = None;
                }
                t.task.etag = None;
                t.task.web_view_link = None;
                t.sync_state = axiotask_core::store::SyncState::Dirty;
                t.pending_op = Some("create".into());
                t.local_updated = now.clone();
                self.store
                    .upsert_task(&t)
                    .await
                    .map_err(|e| e.to_string())?;
                summary.tasks += 1;
            }
        }
        if summary.lists + summary.tasks > 0 {
            self.schedule_sync();
        }
        Ok(summary)
    }

    /// Create a default "My Tasks" list if no lists exist and user is not authenticated.
    async fn ensure_default_list(&self) {
        if self.is_authenticated() {
            return;
        }
        let Ok(lists) = self.store.all_lists().await else {
            return;
        };
        if !lists.is_empty() {
            return;
        }
        let id = uuid::Uuid::new_v4().to_string();
        let now = axiotask_core::dates::now_utc_string();
        let stored = axiotask_core::store::StoredTaskList {
            list: axiotask_core::model::TaskList {
                id,
                title: "My Tasks".into(),
                etag: None,
                updated: now.clone(),
            },
            sync_state: axiotask_core::store::SyncState::Dirty,
            local_updated: now,
            // Pending create; on first authenticated pull, the engine adopts
            // Google's existing "My Tasks" by title instead of duplicating.
            pending_op: Some("create".into()),
            local_only: false,
        };
        let _ = self.store.upsert_list(&stored).await;
    }

    /// Run the OAuth login flow (opens browser).
    pub async fn start_login(&self) -> Result<(), String> {
        tracing::info!("starting OAuth login flow...");
        let tokens = axiotask_core::auth::login(&self.oauth_config, &self.token_store)
            .await
            .map_err(|e| {
                tracing::error!("login failed: {e}");
                e.to_string()
            })?;

        tracing::info!("login successful, switching to HTTP client");
        // Switch to real HTTP client.
        let http_client = build_http_client(tokens, self.token_store.clone(), &self.oauth_config);
        *self.client.lock().await = Arc::new(http_client);
        // Fresh grant — background syncs may resume.
        self.needs_reauth.store(false, Ordering::Relaxed);

        // Verify tokens persisted
        match self.token_store.load() {
            Ok(Some(_)) => tracing::info!("tokens persisted successfully"),
            Ok(None) => tracing::error!("tokens NOT persisted after login!"),
            Err(e) => tracing::error!("token store read error: {e}"),
        }
        Ok(())
    }

    /// Sign out: clear tokens and switch back to in-memory (offline) client.
    /// Async because it awaits the client lock: a `block_on` here runs inside
    /// a Tauri async command on a tokio worker thread and panics the runtime
    /// ("Cannot start a runtime from within a runtime") — crashing the app on
    /// Sign out after the tokens were already cleared, leaving the UI
    /// believing it is still signed in.
    pub async fn logout(&self) -> Result<(), String> {
        self.token_store.clear().map_err(|e| e.to_string())?;
        // Switch to offline client.
        let offline: Arc<dyn GoogleTasksClient> = Arc::new(InMemoryClient::new());
        *self.client.lock().await = offline;
        // Signed out — the expired-session state no longer applies.
        self.needs_reauth.store(false, Ordering::Relaxed);
        Ok(())
    }

    /// Signal the background sync loop to run soon.
    pub fn schedule_sync(&self) {
        self.sync_notify.notify_one();
    }

    /// Run the background sync loop forever. Spawn this once at startup.
    ///
    /// Triggers a sync when either:
    /// - a mutation signals `sync_notify` (debounced by [`SYNC_DEBOUNCE`]), or
    /// - the periodic [`SYNC_PERIOD`] timer elapses.
    ///
    /// Only runs sync when authenticated; otherwise the trigger is a no-op.
    pub async fn run_sync_loop(self: Arc<Self>) {
        loop {
            // A run of permanent failures stretches the idle cadence (see
            // [`Self::next_sync_period`]); a mutation still triggers promptly
            // via `sync_notify`, so backing off never delays the user's own
            // changes — only the pointless re-poll of a stuck failure.
            let period = self.next_sync_period();
            wait_for_sync_trigger(&self.sync_notify, SYNC_DEBOUNCE, period).await;
            // A dead session fails identically on every attempt — don't churn
            // (and spam the token endpoint) until the user signs in again.
            // Manual "Sync now" stays available as an explicit re-check.
            if self.needs_reauth() {
                tracing::debug!("background sync skipped: session expired, waiting for re-login");
                continue;
            }
            // `run_sync` already logs the failure (once, not every tick) and
            // records the needs-attention state; nothing to add at WARN here or
            // a stuck sync would spam the log again from this layer.
            if self.is_authenticated()
                && let Err(e) = self.run_sync_if_authed().await
            {
                tracing::debug!("background sync failed: {e}");
            }
        }
    }

    /// The delay before the next *idle* periodic sync. The base cadence
    /// ([`SYNC_PERIOD`]) while healthy; after consecutive *permanent* failures
    /// it backs off exponentially up to [`SYNC_MAX_BACKOFF`], so a sync that
    /// fails identically every time stops re-polling every 60s. The streak (and
    /// thus the backoff) resets to the base cadence on the first success.
    pub(crate) fn next_sync_period(&self) -> Duration {
        let streak = self.attention_streak.load(Ordering::Relaxed);
        backoff_period(SYNC_PERIOD, streak, SYNC_MAX_BACKOFF)
    }

    /// Run sync immediately. Does not check authentication — use `run_sync_if_authed` for guarded access.
    ///
    /// Serialized via `sync_guard`: if another sync is in progress, this call
    /// waits for it to finish before running. Prevents double-push races.
    pub async fn run_sync(&self) -> Result<SyncOutcome, axiotask_core::sync::SyncError> {
        let _guard = self.sync_guard.lock().await;
        // While the user is mid-edit, hold ONLY the create of the exact row the
        // UI is holding: a create remaps a local id to the server id, which
        // would invalidate that id. Every other create still pushes — including
        // a subtask created inside an open detail panel (#85), whose own id
        // remap never touches the parent id the panel holds. Committed edits
        // (completing a subtask, renaming a synced task) reuse the existing id
        // and MUST keep pushing. Pull always runs.
        let held_create_id = self.held_create_id.lock().unwrap().clone();
        let push_enabled = self.push_enabled.load(Ordering::Relaxed);
        tracing::info!(
            "running sync (push_enabled={push_enabled}, held_create_id={held_create_id:?})..."
        );
        let client = self.client.lock().await.clone();
        let engine = SyncEngine::with_push(client, self.store.clone(), push_enabled)
            .hold_create_id(held_create_id);
        let result = engine.run().await;
        // Record status/stats and notify the UI of the outcome.
        let snapshot = {
            let mut status = self.sync_status.lock().await;
            match &result {
                Ok(o) => {
                    tracing::info!(
                        "sync complete: pulled={}, pushed={}, conflicts={}",
                        o.pulled,
                        o.pushed,
                        o.conflicts
                    );
                    status.last_synced = Some(axiotask_core::dates::now_utc_string());
                    // A working sync proves the session is alive again (e.g.
                    // after re-login, or a mis-flagged transient).
                    self.needs_reauth.store(false, Ordering::Relaxed);
                    status.needs_reauth = false;
                    // A success also clears any "needs attention" backoff — the
                    // stuck failure resolved, so the idle cadence returns to
                    // base ([`Self::next_sync_period`]).
                    self.attention_streak.store(0, Ordering::Relaxed);
                    status.needs_attention = false;
                    // The stuck failure resolved: forget its raw dedup key so a
                    // later, identical permanent failure re-logs at ERROR (#131).
                    status.last_raw_error = None;
                    status.last_pulled = o.pulled;
                    status.last_pushed = o.pushed;
                    status.last_conflicts = o.conflicts;
                    status.last_deleted = o.deleted;
                    status.changed_list_ids.clone_from(&o.changed_list_ids);
                    status.lists_changed = o.lists_changed;
                    status.total_syncs += 1;
                    // A row the server rejected stays dirty and would retry
                    // silently forever — tell the user instead of hiding it
                    // behind a green "synced" state.
                    status.last_error = (o.errors > 0).then(|| {
                        format!(
                            "{} change{} rejected by the server (kept locally, will retry)",
                            o.errors,
                            if o.errors == 1 { "" } else { "s" }
                        )
                    });
                }
                Err(e) => {
                    status.changed_list_ids.clear();
                    status.lists_changed = false;
                    if e.is_auth_expired() {
                        // The refresh token is dead — stop the background
                        // retry churn and tell the user what to actually do.
                        // This is its own state, distinct from the generic
                        // needs-attention backoff (the loop already gates
                        // background runs on `needs_reauth`), so clear that
                        // streak rather than compounding two backoffs.
                        tracing::error!("sync failed: session expired — sign in again");
                        self.needs_reauth.store(true, Ordering::Relaxed);
                        status.needs_reauth = true;
                        self.attention_streak.store(0, Ordering::Relaxed);
                        status.needs_attention = false;
                        status.last_error =
                            Some("Google session expired — sign in again to resume sync".into());
                    } else if e.is_transient() {
                        // A blip that clears itself (network / 5xx / rate-limit)
                        // — keep retrying silently at the base cadence. This is
                        // the "transient behavior unchanged" path: no attention,
                        // no backoff, the streak is left untouched. The full
                        // typed error (a `Network` variant embeds raw reqwest
                        // text with the request URL) goes to the log; the user
                        // only ever sees the sanitized sentence (#135).
                        tracing::warn!("transient sync failure, will retry: {e}");
                        status.last_error = Some(sync_user_message(e));
                    } else {
                        // Permanent: fails identically on every retry until
                        // something changes. Surface it as "needs attention" and
                        // back the idle cadence off. Log at ERROR only the first
                        // time a DISTINCT failure appears — keyed on the RAW
                        // typed detail, not the sanitized display text (#131) —
                        // so a stuck sync repeating the same failure drops to
                        // DEBUG and stops reprinting every cadence tick, while a
                        // genuinely new root cause still gets its own ERROR line.
                        // Full typed detail (may carry raw SQL) goes to the log;
                        // the user only ever sees the sanitized message (#128).
                        let log = classify_permanent_failure(
                            status.needs_attention,
                            status.last_raw_error.as_deref(),
                            e,
                        );
                        if log.log_at_error {
                            tracing::error!("sync failed (needs attention): {}", log.raw_detail);
                        } else {
                            tracing::debug!(
                                "sync still failing (unchanged, backing off): {}",
                                log.raw_detail
                            );
                        }
                        let streak = self.attention_streak.fetch_add(1, Ordering::Relaxed) + 1;
                        tracing::debug!("permanent sync-failure streak now {streak}");
                        status.needs_attention = true;
                        status.last_raw_error = Some(log.raw_detail);
                        status.last_error = Some(log.user_msg);
                    }
                }
            }
            status.clone()
        };
        // Background syncs are otherwise invisible to the UI; tell it what
        // happened so it can refresh and surface any error.
        let notifier = self.sync_notifier.read().unwrap().clone();
        notifier.notify_sync(&snapshot);
        result
    }

    /// A snapshot of the current sync status and running stats.
    pub async fn sync_status(&self) -> SyncStatus {
        self.sync_status.lock().await.clone()
    }

    /// Record the id of the task the UI is holding (inline editor row or open
    /// detail panel), or `None` when nothing is being edited. Only that one
    /// task's create push is held; every other create still syncs.
    pub fn set_editing_task(&self, id: Option<String>) {
        *self.held_create_id.lock().unwrap() = id;
    }

    /// Run sync only if the user is authenticated. Returns an error if not signed in.
    pub async fn run_sync_if_authed(&self) -> Result<SyncOutcome, String> {
        if !self.is_authenticated() {
            return Err("not authenticated".into());
        }
        self.run_sync().await.map_err(|e| e.to_string())
    }

    /// Create a new task list.
    ///
    /// A `local_only` list lives solely in the local cache: it is never pushed
    /// to, pulled from, or reconciled against Google. It is stored `Clean` with
    /// no pending op so the sync engine ignores it entirely. A normal list is
    /// stored as a pending `create` and pushed on the next sync.
    pub async fn create_list(
        &self,
        title: &str,
        local_only: bool,
    ) -> Result<axiotask_core::store::StoredTaskList, String> {
        use axiotask_core::store::SyncState;
        let id = uuid::Uuid::new_v4().to_string();
        let now = axiotask_core::dates::now_utc_string();
        let (sync_state, pending_op) = if local_only {
            (SyncState::Clean, None)
        } else {
            (SyncState::Dirty, Some("create".to_string()))
        };
        let stored = axiotask_core::store::StoredTaskList {
            list: axiotask_core::model::TaskList {
                id,
                title: title.to_string(),
                etag: None,
                updated: now.clone(),
            },
            sync_state,
            local_updated: now,
            pending_op,
            local_only,
        };
        self.store
            .upsert_list(&stored)
            .await
            .map_err(|e| e.to_string())?;
        // Local-only lists never sync, so don't bother waking the loop for them.
        if !local_only {
            self.schedule_sync();
        }
        Ok(stored)
    }

    /// Rename a list. Preserves a pending `create` (rename folds in); otherwise
    /// marks `update` to push via `patch_tasklist`.
    pub async fn rename_list(&self, id: &str, title: &str) -> Result<(), String> {
        let lists = self.store.all_lists().await.map_err(|e| e.to_string())?;
        let mut list = lists
            .into_iter()
            .find(|l| l.list.id == id)
            .ok_or("list not found")?;
        list.list.title = title.to_string();
        list.sync_state = axiotask_core::store::SyncState::Dirty;
        if list.pending_op.as_deref() != Some("create") {
            list.pending_op = Some("update".into());
        }
        list.local_updated = axiotask_core::dates::now_utc_string();
        self.store
            .upsert_list(&list)
            .await
            .map_err(|e| e.to_string())?;
        self.schedule_sync();
        Ok(())
    }

    /// Delete a list. If it was ever synced (has an etag) it is tombstoned so
    /// the deletion reaches Google (which cascades to its tasks); otherwise it
    /// is hard-deleted locally. Local task rows are removed either way.
    pub async fn delete_list(&self, id: &str) -> Result<(), String> {
        let lists = self.store.all_lists().await.map_err(|e| e.to_string())?;
        let Some(mut list) = lists.into_iter().find(|l| l.list.id == id) else {
            return Ok(()); // already gone
        };
        // Remove local task rows (server cascades on its side).
        for t in self.store.list_tasks(id).await.map_err(|e| e.to_string())? {
            self.store
                .delete_task_hard(&t.task.id)
                .await
                .map_err(|e| e.to_string())?;
        }
        if list.list.etag.is_some() {
            list.sync_state = axiotask_core::store::SyncState::Deleted;
            list.pending_op = Some("delete".into());
            list.local_updated = axiotask_core::dates::now_utc_string();
            self.store
                .upsert_list(&list)
                .await
                .map_err(|e| e.to_string())?;
        } else {
            self.store
                .delete_list_hard(id)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.schedule_sync();
        Ok(())
    }

    /// Move a task to a different list.
    ///
    /// Google Tasks has no native cross-list move, so this is implemented as
    /// delete-from-old + create-in-new. The new task gets a fresh local id;
    /// on sync the delete removes it from the old remote list and the create
    /// adds it to the new one. Avoids the 404-delete data-loss path that a
    /// naive `patch_task(new_list, ...)` would trigger.
    ///
    /// The task's WHOLE SUBTREE moves with it. Deleting a parent on Google
    /// deletes its children too (verified against the live API), and the
    /// local FK cascade mirrors that — so leaving subtasks behind would
    /// silently destroy them the moment the parent's delete pushed.
    /// Remove one original row after its subtree was recreated in another list.
    /// A row the server MAY hold is tombstoned, not hard-deleted: the server
    /// only cascades a moved subtree away once the ROOT's delete lands, and if a
    /// pull happens first (e.g. the root delete is still retrying after a
    /// transient) a hard-deleted row is RESURRECTED from the server, duplicating
    /// the moved subtree (P8). A tombstone pushes its own delete and the pull
    /// cannot re-add it; a redundant server cascade then 404s = success. A row
    /// the server has never seen is hard-deleted. `fallback` is the source-list
    /// snapshot to tombstone from (its absence — shouldn't happen — hard-deletes).
    async fn remove_moved_original(
        &self,
        old_id: &str,
        fallback: Option<&axiotask_core::store::StoredTask>,
        now: &str,
    ) -> Result<(), String> {
        let may_hold = self
            .store
            .server_may_hold(old_id)
            .await
            .map_err(|e| e.to_string())?;
        match (may_hold, fallback) {
            (true, Some(row)) => {
                let mut tomb = row.clone();
                tomb.sync_state = axiotask_core::store::SyncState::Deleted;
                tomb.pending_op = Some("delete".into());
                tomb.local_updated = now.to_string();
                self.store
                    .upsert_task(&tomb)
                    .await
                    .map_err(|e| e.to_string())?;
            }
            _ => {
                self.store
                    .delete_task_hard(old_id)
                    .await
                    .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    pub async fn move_task_to_list(
        &self,
        id: &str,
        target_list_id: &str,
    ) -> Result<String, String> {
        // Locate the task across all lists.
        let lists = self.store.all_lists().await.map_err(|e| e.to_string())?;
        let mut found: Option<axiotask_core::store::StoredTask> = None;
        for list in &lists {
            let tasks = self
                .store
                .list_tasks(&list.list.id)
                .await
                .map_err(|e| e.to_string())?;
            if let Some(t) = tasks.into_iter().find(|t| t.task.id == id) {
                found = Some(t);
                break;
            }
        }
        let Some(old) = found else {
            return Err(format!("task {id} not found"));
        };

        if old.list_id == target_list_id {
            return Ok(id.to_string()); // already there
        }

        let now = axiotask_core::dates::now_utc_string();
        let siblings = self
            .store
            .list_tasks(&old.list_id)
            .await
            .map_err(|e| e.to_string())?;

        // Recreate the subtree root in the target list under a fresh local id,
        // then each descendant level under its recreated parent's new id.
        let mut recreated: Vec<(String, String)> = Vec::new(); // (old_id, new_id)
        let mut frontier = vec![(old.clone(), None::<String>)];
        while let Some((node, new_parent)) = frontier.pop() {
            let mut copy = node.clone();
            copy.task.id = uuid::Uuid::new_v4().to_string();
            copy.task.parent = new_parent;
            copy.task.etag = None; // brand-new remote row
            copy.task.web_view_link = None;
            copy.list_id = target_list_id.to_string();
            copy.sync_state = axiotask_core::store::SyncState::Dirty;
            copy.pending_op = Some("create".into());
            copy.local_updated = now.clone();
            self.store
                .upsert_task(&copy)
                .await
                .map_err(|e| e.to_string())?;
            recreated.push((node.task.id.clone(), copy.task.id.clone()));
            for child in siblings
                .iter()
                .filter(|t| t.task.parent.as_deref() == Some(&node.task.id))
            {
                frontier.push((child.clone(), Some(copy.task.id.clone())));
            }
        }
        let new_root_id = recreated
            .iter()
            .find_map(|(old_id, new_id)| (old_id == id).then(|| new_id.clone()))
            .ok_or_else(|| format!("failed to recreate task {id}"))?;

        // Remove the old subtree: descendants first, then the root. Each row is
        // tombstoned if the server may hold it and hard-deleted otherwise (see
        // [`remove_moved_original`] — this is where the P8 anti-resurrection
        // lives). "May hold" on the root also covers its in-flight-create crash
        // window, so a committed original is never stranded in the source list.
        for (old_id, _) in recreated.iter().skip(1) {
            let fallback = siblings.iter().find(|t| &t.task.id == old_id);
            self.remove_moved_original(old_id, fallback, &now).await?;
        }
        self.remove_moved_original(id, Some(&old), &now).await?;

        self.schedule_sync();
        Ok(new_root_id)
    }

    /// Whether push is enabled (read-only mode if false).
    pub fn is_push_enabled(&self) -> bool {
        self.push_enabled.load(Ordering::Relaxed)
    }

    /// Whether auto-sync-on-startup is enabled.
    pub fn auto_sync_on_start(&self) -> bool {
        self.auto_sync_on_start.load(Ordering::Relaxed)
    }

    /// Path to the SQLite database (display-only).
    pub fn db_path(&self) -> &std::path::Path {
        &self.db_path
    }

    /// Path to the config file (display-only).
    pub fn config_path(&self) -> &std::path::Path {
        &self.config_path
    }

    /// OAuth scopes currently configured (display-only; what access the app
    /// has to the Google account).
    pub fn scopes(&self) -> Vec<String> {
        self.oauth_config.scopes.clone()
    }

    /// Number of local changes awaiting push (delegates to the store).
    pub async fn pending_push_count(&self) -> Result<u32, String> {
        self.store
            .pending_push_count()
            .await
            .map_err(|e| e.to_string())
    }

    /// Enable or disable pushing local changes to Google (read-write vs.
    /// read-only sync). Takes effect on the next sync and is persisted to the
    /// config file so the choice survives a restart.
    pub fn set_push_enabled(&self, enabled: bool) -> Result<(), String> {
        self.push_enabled.store(enabled, Ordering::Relaxed);
        self.persist_sync_settings()
    }

    /// Enable or disable the automatic sync on startup. Persisted to config.
    pub fn set_auto_sync_on_start(&self, enabled: bool) -> Result<(), String> {
        self.auto_sync_on_start.store(enabled, Ordering::Relaxed);
        self.persist_sync_settings()
    }

    /// Write the current in-memory sync settings to the config file, preserving
    /// the rest of the file (credentials and comments).
    fn persist_sync_settings(&self) -> Result<(), String> {
        let sync = axiotask_core::config::SyncConfig {
            push_enabled: self.push_enabled.load(Ordering::Relaxed),
            auto_sync_on_start: self.auto_sync_on_start.load(Ordering::Relaxed),
        };
        axiotask_core::config::AppConfig::save_sync_to(&self.config_path, &sync)
            .map_err(|e| format!("failed to save config: {e}"))
    }
}

/// Block until it's time to run a sync: either a debounced mutation trigger
/// or the periodic timer, whichever comes first.
///
/// On a mutation trigger, waits `debounce` to let a burst settle (coalescing
/// rapid mutations into one sync). Otherwise fires after `period`.
async fn wait_for_sync_trigger(notify: &Notify, debounce: Duration, period: Duration) {
    tokio::select! {
        () = notify.notified() => {
            tokio::time::sleep(debounce).await;
        }
        () = tokio::time::sleep(period) => {}
    }
}

fn build_http_client(
    tokens: StoredTokens,
    store: Arc<dyn TokenStore>,
    config: &OAuthConfig,
) -> HttpClient {
    let token_url = config.token_url.clone();
    let client_id = config.client_id.clone();
    let client_secret = config.client_secret.clone();
    let refresh: RefreshFn = Arc::new(move |refresh_token: String| {
        let token_url = token_url.clone();
        let client_id = client_id.clone();
        let client_secret = client_secret.clone();
        Box::pin(async move {
            use axiotask_core::auth::RefreshError;
            let client = reqwest::Client::new();
            let resp = client
                .post(&token_url)
                .form(&[
                    ("client_id", client_id.as_str()),
                    ("client_secret", client_secret.as_str()),
                    ("refresh_token", refresh_token.as_str()),
                    ("grant_type", "refresh_token"),
                ])
                .send()
                .await
                .map_err(|e| RefreshError::Transient(e.to_string()))?;
            let status = resp.status().as_u16();
            let body = resp
                .text()
                .await
                .map_err(|e| RefreshError::Transient(e.to_string()))?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            // Classifies invalid_grant & co. as Denied (permanent — the user
            // must sign in again) and everything else as Transient.
            axiotask_core::auth::parse_refresh_response(
                status,
                &body,
                refresh_token,
                "https://www.googleapis.com/auth/tasks",
                now,
            )
        })
    });

    let authed = AuthedClient::new(reqwest::Client::new(), tokens, store, refresh);
    HttpClient::new(authed)
}

/// Default database path: `$XDG_DATA_HOME/<app-dir>/axiotask.sqlite`, where
/// `<app-dir>` is instance-aware (`axiotask` or `axiotask-<prefix>`). The auth
/// `tokens.json` lives beside it, so isolating this directory isolates the
/// session too.
pub fn default_db_path() -> PathBuf {
    let data = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    data.join(axiotask_core::config::app_dir_name())
        .join("axiotask.sqlite")
}

/// Single-instance guard (#48): take an exclusive advisory lock on a file next
/// to the database, held for the process lifetime.
///
/// Two processes on the same DB are unsafe REGARDLESS of WAL: the sync mutex
/// is per-process, so both would drain the same dirty rows and double-push
/// creates (each remapping the local id to a different remote task — duplicates
/// on Google). The lock is scoped to the DATA DIRECTORY, which is exactly the
/// unit that must be exclusive — a `dev`-prefixed instance, the production
/// instance, and an e2e run under its own `XDG_DATA_HOME` all use different
/// directories and may run side by side. (This is why the single-instance
/// plugin is unsuitable: it keys on the app identifier over the session bus —
/// one global claim per machine, breaking exactly those workflows.)
///
/// The kernel releases the lock when the process dies, however it dies, so a
/// crash never leaves a stale guard. Returns the open file — the caller must
/// keep it alive for the lifetime of the process.
pub fn acquire_instance_lock(db_path: &std::path::Path) -> Result<std::fs::File, String> {
    let dir = db_path.parent().ok_or("db path has no parent directory")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("create data dir: {e}"))?;
    let lock_path = dir.join("instance.lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .map_err(|e| format!("open {}: {e}", lock_path.display()))?;
    match file.try_lock() {
        Ok(()) => {
            // Informational only — the flock is the guard, the pid is for humans.
            let _ = std::fs::write(&lock_path, format!("{}\n", std::process::id()));
            Ok(file)
        }
        Err(std::fs::TryLockError::WouldBlock) => {
            let holder = std::fs::read_to_string(&lock_path).unwrap_or_default();
            let holder = holder.trim();
            Err(format!(
                "another axiotask instance is already running on this data directory \
                 ({}{}). Close it first — two processes on one database would \
                 duplicate tasks on Google.",
                dir.display(),
                if holder.is_empty() {
                    String::new()
                } else {
                    format!(", pid {holder}")
                },
            ))
        }
        Err(std::fs::TryLockError::Error(e)) => Err(format!("lock {}: {e}", lock_path.display())),
    }
}

/// Default backup path: a timestamped JSON file under the instance's
/// `<app-dir>/backups/` directory. Timestamping keeps successive backups from
/// clobbering each other.
pub fn default_backup_path() -> PathBuf {
    let data = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    let stamp = jiff::Zoned::now().strftime("%Y%m%d-%H%M%S").to_string();
    data.join(axiotask_core::config::app_dir_name())
        .join("backups")
        .join(format!("axiotask-backup-{stamp}.json"))
}

/// The most recent backup file in the instance's backups directory, if any.
///
/// Backups are named `axiotask-backup-YYYYMMDD-HHMMSS.json`; the timestamp
/// makes the file names sort chronologically, so the lexicographically last
/// matching file is the newest. Used by the keyboard-driven restore so the
/// user can recover their latest backup without a file dialog.
pub fn latest_backup_path() -> Option<PathBuf> {
    let dir = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(axiotask_core::config::app_dir_name())
        .join("backups");
    latest_backup_in(&dir)
}

/// Find the newest `axiotask-backup-*.json` in `dir`. Split out from
/// [`latest_backup_path`] so the selection logic is unit-testable against an
/// arbitrary directory.
fn latest_backup_in(dir: &std::path::Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            let is_json = p
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("json"));
            let named = p
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("axiotask-backup-"));
            is_json && named
        })
        .max_by(|a, b| a.file_name().cmp(&b.file_name()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axiotask_core::auth::{StoredTokens, TokenStore};
    use tempfile::TempDir;

    fn sample_tokens() -> StoredTokens {
        StoredTokens {
            access_token: "at-123".into(),
            refresh_token: "rt-456".into(),
            access_expires_at: Some(1_700_000_000),
            scope: "https://www.googleapis.com/auth/tasks".into(),
        }
    }

    #[test]
    fn file_token_store_round_trips() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        let store = FileTokenStore::new(&path);

        assert!(store.load().unwrap().is_none());
        store.save(&sample_tokens()).unwrap();
        assert_eq!(store.load().unwrap().unwrap(), sample_tokens());
    }

    #[test]
    fn file_token_store_clear_removes_file() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.json");
        let store = FileTokenStore::new(&path);

        store.save(&sample_tokens()).unwrap();
        assert!(path.exists());
        store.clear().unwrap();
        assert!(!path.exists());
        assert!(store.load().unwrap().is_none());
    }

    #[test]
    fn file_token_store_creates_parent_dirs() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("dir").join("tokens.json");
        let store = FileTokenStore::new(&path);

        store.save(&sample_tokens()).unwrap();
        assert_eq!(store.load().unwrap().unwrap(), sample_tokens());
    }

    // ─── Backup file selection ───────────────────────────────────────────────

    #[test]
    fn latest_backup_in_picks_newest_by_timestamped_name() {
        let dir = TempDir::new().unwrap();
        for name in [
            "axiotask-backup-20260101-000000.json",
            "axiotask-backup-20260608-014500.json", // newest
            "axiotask-backup-20260301-120000.json",
            "notes.txt",               // ignored: wrong name
            "axiotask-backup-old.bak", // ignored: wrong extension
        ] {
            std::fs::write(dir.path().join(name), b"{}").unwrap();
        }
        let latest = latest_backup_in(dir.path()).expect("a backup");
        assert_eq!(
            latest.file_name().unwrap().to_str().unwrap(),
            "axiotask-backup-20260608-014500.json"
        );
    }

    #[test]
    fn latest_backup_in_returns_none_when_empty_or_missing() {
        let dir = TempDir::new().unwrap();
        assert!(latest_backup_in(dir.path()).is_none());
        assert!(latest_backup_in(&dir.path().join("does-not-exist")).is_none());
    }

    // ─── Sync failure messages the user sees (#128) ──────────────────────────

    #[test]
    fn permanent_store_failure_message_hides_sql_from_the_user() {
        use axiotask_core::store::StoreError;
        use axiotask_core::sync::SyncError;
        // A store failure during sync carries raw sqlx text. `last_error` is
        // rendered in the "Sync failed" toast and the Properties dialog, so it
        // must not carry that detail.
        let e = SyncError::Store(StoreError::Sql("no such column: foo".into()));
        assert!(e.to_string().contains("sql:"), "precondition: raw leaks");

        let shown = sync_user_message(&e);
        assert!(!shown.contains("sql:"), "no sql prefix: {shown}");
        assert!(!shown.contains("no such column"), "no sqlx detail: {shown}");
        assert!(
            shown.to_lowercase().contains("log"),
            "points at the log: {shown}"
        );
    }

    #[test]
    fn internal_sync_failure_message_is_calm() {
        use axiotask_core::sync::SyncError;
        let e = SyncError::Internal("assertion x != y failed".into());
        let shown = sync_user_message(&e);
        assert!(!shown.contains("assertion"), "no internal detail: {shown}");
        assert!(
            shown.to_lowercase().contains("log"),
            "points at the log: {shown}"
        );
    }

    #[test]
    fn api_sync_failures_keep_their_human_text() {
        use axiotask_core::api::ApiError;
        use axiotask_core::sync::SyncError;
        // API errors are already human and never carry SQL — keep them so the
        // user still sees "server error: 503" rather than a generic sentence.
        let e = SyncError::Api(ApiError::Server { status: 503 });
        assert_eq!(sync_user_message(&e), "server error: 503");
    }

    #[test]
    fn network_sync_failure_hides_the_reqwest_url_from_the_user() {
        use axiotask_core::api::ApiError;
        use axiotask_core::sync::SyncError;
        // #135: `ApiError::Network` embeds raw reqwest text, which can include
        // the full request URL (and query params). `last_error` is rendered
        // verbatim in the "Sync failed" toast, so it must carry NONE of that —
        // only a calm sentence. The full typed error still goes to the log.
        let raw = "error sending request for url \
                   (https://tasks.googleapis.com/tasks/v1/users/@me/lists?key=SECRET): \
                   connection reset by peer";
        let e = SyncError::Api(ApiError::Network(raw.into()));
        assert!(
            e.to_string().contains("https://"),
            "precondition: the raw error leaks the URL"
        );

        let shown = sync_user_message(&e);
        assert!(
            !shown.contains("https://"),
            "no URL reaches the user: {shown}"
        );
        assert!(
            !shown.contains("googleapis"),
            "no host reaches the user: {shown}"
        );
        assert!(
            !shown.contains("SECRET"),
            "no query param reaches the user: {shown}"
        );
        assert!(
            shown.to_lowercase().contains("google"),
            "the calm message names Google so the user knows what's unreachable: {shown}"
        );
    }

    // ─── Permanent-failure backoff / attention ───────────────────────────────

    #[test]
    fn backoff_period_stays_at_base_while_healthy() {
        let base = Duration::from_secs(60);
        let cap = Duration::from_secs(3600);
        // No permanent-failure streak → the plain periodic cadence.
        assert_eq!(backoff_period(base, 0, cap), base);
    }

    #[test]
    fn backoff_period_doubles_per_failure_then_pins_to_cap() {
        let base = Duration::from_secs(60);
        let cap = Duration::from_secs(3600);
        assert_eq!(backoff_period(base, 1, cap), Duration::from_secs(120));
        assert_eq!(backoff_period(base, 2, cap), Duration::from_secs(240));
        assert_eq!(backoff_period(base, 3, cap), Duration::from_secs(480));
        // 60 * 2^6 = 3840s would exceed the hour cap → pinned to the cap.
        assert_eq!(backoff_period(base, 6, cap), cap);
        // A pathologically large streak can never overflow the shift/multiply.
        assert_eq!(backoff_period(base, u32::MAX, cap), cap);
    }

    #[test]
    fn permanent_failure_logs_at_error_only_when_new_or_changed() {
        use axiotask_core::api::ApiError;
        use axiotask_core::sync::SyncError;
        let boom = SyncError::Api(ApiError::Other("boom".into()));
        let kaput = SyncError::Api(ApiError::Other("kaput".into()));
        let raw_boom = boom.to_string();
        // First failure of a healthy sync → log at ERROR.
        assert!(classify_permanent_failure(false, None, &boom).log_at_error);
        // Same error repeating while already in attention → DEBUG (no spam).
        assert!(!classify_permanent_failure(true, Some(&raw_boom), &boom).log_at_error);
        // A *different* permanent error while in attention → ERROR again.
        assert!(classify_permanent_failure(true, Some(&raw_boom), &kaput).log_at_error);
        // Re-entering attention after a clear (prev_attention false) → ERROR.
        assert!(classify_permanent_failure(false, Some(&raw_boom), &boom).log_at_error);
    }

    #[test]
    fn distinct_root_causes_relog_at_error_even_when_display_text_is_identical() {
        // #131: two DIFFERENT store failures both sanitize to the SAME calm
        // sentence (SQL is hidden from the user). The dedup must key on the RAW
        // typed detail, not that sanitized display text — otherwise the second,
        // genuinely-new root cause is swallowed as a "repeat" and buried at
        // DEBUG. It must earn its own first-time ERROR line.
        use axiotask_core::store::StoreError;
        use axiotask_core::sync::SyncError;
        let first = SyncError::Store(StoreError::Sql("no such column: foo".into()));
        let second = SyncError::Store(StoreError::Sql("no such table: bar".into()));

        let a = classify_permanent_failure(false, None, &first);
        assert!(a.log_at_error, "first distinct failure logs at ERROR");
        // Precondition the fix depends on: distinct raw, identical display.
        assert_ne!(a.raw_detail, second.to_string(), "raw details differ");
        assert_eq!(
            a.user_msg,
            classify_permanent_failure(false, None, &second).user_msg,
            "both sanitize to the same user-facing sentence",
        );

        // Now the second failure arrives while already in attention, with the
        // first failure's RAW detail remembered.
        let b = classify_permanent_failure(true, Some(&a.raw_detail), &second);
        assert!(
            b.log_at_error,
            "a distinct root cause must re-log at ERROR despite identical display text",
        );

        // …but an *identical* raw failure repeating stays DEBUG (no spam).
        let c = classify_permanent_failure(true, Some(&a.raw_detail), &first);
        assert!(!c.log_at_error, "identical raw repeat stays DEBUG");
        // And the raw detail is what reaches the log (carries the SQL), while the
        // user message hides it.
        assert!(
            a.raw_detail.contains("no such column: foo"),
            "raw kept for log"
        );
        assert!(
            !a.user_msg.contains("no such column"),
            "SQL hidden from user"
        );
    }

    // ─── End-to-end permanent-failure log dedup through run_sync (#131) ───────

    /// A thread-local tracing sink that records `(level, message)` for every
    /// event, so a test can assert the LEVEL a permanent failure was logged at.
    #[derive(Clone, Default)]
    struct CapturedLogs(Arc<std::sync::Mutex<Vec<(tracing::Level, String)>>>);

    impl CapturedLogs {
        fn count(&self, level: tracing::Level, needle: &str) -> usize {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter(|(l, m)| *l == level && m.contains(needle))
                .count()
        }
    }

    struct MsgVisitor(String);
    impl tracing::field::Visit for MsgVisitor {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            if field.name() == "message" {
                self.0 = format!("{value:?}");
            }
        }
    }

    struct CaptureLayer(CapturedLogs);
    impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for CaptureLayer {
        fn on_event(
            &self,
            event: &tracing::Event<'_>,
            _ctx: tracing_subscriber::layer::Context<'_, S>,
        ) {
            let mut v = MsgVisitor(String::new());
            event.record(&mut v);
            self.0
                .0
                .lock()
                .unwrap()
                .push((*event.metadata().level(), v.0));
        }
    }

    #[tokio::test]
    async fn permanent_failure_logs_error_once_then_debug_across_run_sync() {
        use axiotask_core::api::ApiError;
        use axiotask_core::api::in_memory::Method;
        use tracing_subscriber::layer::SubscriberExt;

        const BLORP: &str = "schema mismatch: tasks.blorp";
        const ZONK: &str = "schema mismatch: lists.zonk";

        // Capture logs on this test's thread (current-thread runtime, so every
        // run_sync await stays on it and nothing else races the sink).
        let logs = CapturedLogs::default();
        let subscriber = tracing_subscriber::registry().with(CaptureLayer(logs.clone()));
        let _guard = tracing::subscriber::set_default(subscriber);

        let client = Arc::new(InMemoryClient::new());
        client.seed_list("L1", "Inbox");
        let state = Arc::new(
            AppState::new_memory_with_push(client.clone())
                .await
                .unwrap(),
        );

        // The same permanent failure twice, then a genuinely different one.
        for _ in 0..2 {
            client.fail_next(Method::ListTaskLists, || ApiError::Other(BLORP.into()));
            state.run_sync().await.unwrap_err();
        }
        client.fail_next(Method::ListTaskLists, || ApiError::Other(ZONK.into()));
        state.run_sync().await.unwrap_err();

        // The user-visible state carries only the sanitized message (verbatim
        // for an API error) and flags "needs attention".
        let status = state.sync_status().await;
        assert!(status.needs_attention, "permanent failure needs attention");
        // An API error keeps its human text verbatim (#128 sanitizes only store
        // / internal detail); the display just carries the typed `other:` prefix.
        assert!(
            status
                .last_error
                .as_deref()
                .is_some_and(|m| m.contains(ZONK)),
            "user-visible error surfaces the failure text, got: {:?}",
            status.last_error
        );

        // First occurrence of each DISTINCT failure logs once at ERROR; the
        // identical repeat is muted to DEBUG so it stops spamming the log.
        assert_eq!(
            logs.count(tracing::Level::ERROR, BLORP),
            1,
            "first occurrence of a distinct failure logs exactly one ERROR"
        );
        assert_eq!(
            logs.count(tracing::Level::DEBUG, BLORP),
            1,
            "the identical repeat is muted to DEBUG"
        );
        assert_eq!(
            logs.count(tracing::Level::ERROR, ZONK),
            1,
            "a genuinely different failure earns its own ERROR line"
        );

        // A success clears attention AND the raw dedup key, so the SAME failure
        // recurring afterwards is treated as new and re-logs at ERROR.
        state.run_sync().await.unwrap();
        let recovered = state.sync_status().await;
        assert!(!recovered.needs_attention, "success clears attention");
        assert!(recovered.last_error.is_none(), "success clears the error");

        client.fail_next(Method::ListTaskLists, || ApiError::Other(BLORP.into()));
        state.run_sync().await.unwrap_err();
        assert_eq!(
            logs.count(tracing::Level::ERROR, BLORP),
            2,
            "after a clean sync, the same failure re-logs at ERROR (dedup key was reset)"
        );
    }

    // ─── Background sync trigger timing ──────────────────────────────────────

    #[tokio::test(start_paused = true)]
    async fn trigger_fires_after_debounce_on_mutation() {
        let notify = Notify::new();
        let debounce = Duration::from_secs(2);
        let period = Duration::from_secs(60);

        notify.notify_one(); // simulate a mutation
        let start = tokio::time::Instant::now();
        wait_for_sync_trigger(&notify, debounce, period).await;

        // Should fire after the debounce window, not the full period.
        assert_eq!(start.elapsed(), debounce);
    }

    #[tokio::test(start_paused = true)]
    async fn trigger_fires_after_period_when_idle() {
        let notify = Notify::new();
        let debounce = Duration::from_secs(2);
        let period = Duration::from_secs(60);

        let start = tokio::time::Instant::now();
        wait_for_sync_trigger(&notify, debounce, period).await;

        // No mutation → periodic timer fires.
        assert_eq!(start.elapsed(), period);
    }

    #[tokio::test(start_paused = true)]
    async fn rapid_mutations_coalesce_into_one_trigger() {
        let notify = Notify::new();
        let debounce = Duration::from_secs(2);
        let period = Duration::from_secs(60);

        // Burst of mutations before the trigger is awaited.
        notify.notify_one();
        notify.notify_one();
        notify.notify_one();

        let start = tokio::time::Instant::now();
        wait_for_sync_trigger(&notify, debounce, period).await;
        // First trigger fires after debounce.
        assert_eq!(start.elapsed(), debounce);

        // Notify permits coalesce: at most one is pending. The next wait
        // (no new mutations) falls through to the periodic timer.
        let start2 = tokio::time::Instant::now();
        wait_for_sync_trigger(&notify, debounce, period).await;
        assert_eq!(start2.elapsed(), period);
    }
}
