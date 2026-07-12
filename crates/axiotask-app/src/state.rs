//! Application state: store, sync engine, and background scheduler.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::{Mutex, Notify};

use axiotask_core::api::{GoogleTasksClient, HttpClient, InMemoryClient};
use axiotask_core::auth::{
    AuthedClient, InMemoryTokenStore, OAuthConfig, RefreshFn, StoredTokens,
    TokenStore,
};
use axiotask_core::store::Store;
use axiotask_core::sync::{SyncEngine, SyncOutcome};

/// Debounce window: coalesce rapid mutations into a single sync.
const SYNC_DEBOUNCE: Duration = Duration::from_secs(2);
/// Periodic sync interval to catch remote changes.
const SYNC_PERIOD: Duration = Duration::from_secs(60);

/// File-based token store. Persists tokens as JSON to a file.
struct FileTokenStore {
    path: std::path::PathBuf,
}

impl FileTokenStore {
    fn new(path: &std::path::Path) -> Self {
        Self { path: path.to_owned() }
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
    /// Number of successful syncs since the app started.
    pub total_syncs: u64,
    /// Message from the most recent sync failure, cleared on the next success.
    pub last_error: Option<String>,
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
    /// True while the user is actively editing a task in the UI. Pushes are
    /// held during editing so a create's id remap can't invalidate the id the
    /// UI is operating on (pull is unaffected — it skips locally-dirty rows).
    editing: AtomicBool,
    /// Whether to sync automatically on startup. Persisted; display-only after
    /// launch (it only governs the startup sync).
    auto_sync_on_start: AtomicBool,
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
        let oauth_config = OAuthConfig::google_tasks(&config.google.client_id, &config.google.client_secret);

        let token_store: Arc<dyn TokenStore> =
            Arc::new(FileTokenStore::new(&db_path.parent().unwrap().join("tokens.json")));

        // Try to restore existing session.
        let client: Arc<dyn GoogleTasksClient> = match token_store.load() {
            Ok(Some(tokens)) => {
                tracing::info!("restored auth session from keyring");
                Arc::new(build_http_client(tokens, token_store.clone(), &oauth_config))
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
            editing: AtomicBool::new(false),
            auto_sync_on_start: AtomicBool::new(config.sync.auto_sync_on_start),
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
            editing: AtomicBool::new(false),
            auto_sync_on_start: AtomicBool::new(true),
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
                self.store.upsert_list(&l).await.map_err(|e| e.to_string())?;
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
                    && self.store.find_task_any(p).await.map_err(|e| e.to_string())?.is_none()
                {
                    t.task.parent = None;
                }
                t.task.etag = None;
                t.task.web_view_link = None;
                t.sync_state = axiotask_core::store::SyncState::Dirty;
                t.pending_op = Some("create".into());
                t.local_updated = now.clone();
                self.store.upsert_task(&t).await.map_err(|e| e.to_string())?;
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
        let Ok(lists) = self.store.all_lists().await else { return };
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

        // Verify tokens persisted
        match self.token_store.load() {
            Ok(Some(_)) => tracing::info!("tokens persisted successfully"),
            Ok(None) => tracing::error!("tokens NOT persisted after login!"),
            Err(e) => tracing::error!("token store read error: {e}"),
        }
        Ok(())
    }

    /// Sign out: clear tokens and switch back to in-memory (offline) client.
    pub fn logout(&self) -> Result<(), String> {
        self.token_store.clear().map_err(|e| e.to_string())?;
        // Switch to offline client (block_on is fine here — quick operation)
        let offline: Arc<dyn GoogleTasksClient> = Arc::new(InMemoryClient::new());
        *tauri::async_runtime::block_on(self.client.lock()) = offline;
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
            wait_for_sync_trigger(&self.sync_notify, SYNC_DEBOUNCE, SYNC_PERIOD).await;
            if self.is_authenticated()
                && let Err(e) = self.run_sync_if_authed().await
            {
                tracing::warn!("background sync failed: {e}");
            }
        }
    }

    /// Run sync immediately. Does not check authentication — use `run_sync_if_authed` for guarded access.
    ///
    /// Serialized via `sync_guard`: if another sync is in progress, this call
    /// waits for it to finish before running. Prevents double-push races.
    pub async fn run_sync(&self) -> Result<SyncOutcome, axiotask_core::sync::SyncError> {
        let _guard = self.sync_guard.lock().await;
        // While the user is mid-edit, hold only CREATE pushes: a create remaps a
        // local id to the server id, which would invalidate the id the UI is
        // holding for the row being edited. Committed edits (completing a
        // subtask, renaming a synced task) reuse the existing id and MUST keep
        // pushing — otherwise anything changed with the detail panel open would
        // never sync. Pull always runs.
        let editing = self.editing.load(Ordering::Relaxed);
        let push_enabled = self.push_enabled.load(Ordering::Relaxed);
        tracing::info!("running sync (push_enabled={push_enabled}, hold_creates={editing})...");
        let client = self.client.lock().await.clone();
        let engine = SyncEngine::with_push(client, self.store.clone(), push_enabled)
            .hold_creates(editing);
        let result = engine.run().await;
        // Record status/stats and notify the UI of the outcome.
        let snapshot = {
            let mut status = self.sync_status.lock().await;
            match &result {
                Ok(o) => {
                    tracing::info!(
                        "sync complete: pulled={}, pushed={}, conflicts={}",
                        o.pulled, o.pushed, o.conflicts
                    );
                    // Real UTC instant (Timestamp is UTC). Zoned::now() would
                    // format local time but label it "Z", making the UI read the
                    // last-synced time as hours in the past off-UTC.
                    status.last_synced = Some(
                        jiff::Timestamp::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    );
                    status.last_pulled = o.pulled;
                    status.last_pushed = o.pushed;
                    status.last_conflicts = o.conflicts;
                    status.last_deleted = o.deleted;
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
                    tracing::error!("sync failed: {e}");
                    status.last_error = Some(e.to_string());
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

    /// Mark whether the user is actively editing a task (pauses pushes).
    pub fn set_editing(&self, editing: bool) {
        self.editing.store(editing, Ordering::Relaxed);
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
        self.store.upsert_list(&stored).await.map_err(|e| e.to_string())?;
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
        let mut list = lists.into_iter().find(|l| l.list.id == id).ok_or("list not found")?;
        list.list.title = title.to_string();
        list.sync_state = axiotask_core::store::SyncState::Dirty;
        if list.pending_op.as_deref() != Some("create") {
            list.pending_op = Some("update".into());
        }
        list.local_updated = axiotask_core::dates::now_utc_string();
        self.store.upsert_list(&list).await.map_err(|e| e.to_string())?;
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
            self.store.delete_task_hard(&t.task.id).await.map_err(|e| e.to_string())?;
        }
        if list.list.etag.is_some() {
            list.sync_state = axiotask_core::store::SyncState::Deleted;
            list.pending_op = Some("delete".into());
            list.local_updated = axiotask_core::dates::now_utc_string();
            self.store.upsert_list(&list).await.map_err(|e| e.to_string())?;
        } else {
            self.store.delete_list_hard(id).await.map_err(|e| e.to_string())?;
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
    pub async fn move_task_to_list(
        &self,
        id: &str,
        target_list_id: &str,
    ) -> Result<(), String> {
        // Locate the task across all lists.
        let lists = self.store.all_lists().await.map_err(|e| e.to_string())?;
        let mut found: Option<axiotask_core::store::StoredTask> = None;
        for list in &lists {
            let tasks = self.store.list_tasks(&list.list.id).await.map_err(|e| e.to_string())?;
            if let Some(t) = tasks.into_iter().find(|t| t.task.id == id) {
                found = Some(t);
                break;
            }
        }
        let Some(old) = found else {
            return Err(format!("task {id} not found"));
        };

        if old.list_id == target_list_id {
            return Ok(()); // already there
        }

        let now = axiotask_core::dates::now_utc_string();
        let siblings = self.store.list_tasks(&old.list_id).await.map_err(|e| e.to_string())?;

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
            self.store.upsert_task(&copy).await.map_err(|e| e.to_string())?;
            recreated.push((node.task.id.clone(), copy.task.id.clone()));
            for child in siblings.iter().filter(|t| t.task.parent.as_deref() == Some(&node.task.id)) {
                frontier.push((child.clone(), Some(copy.task.id.clone())));
            }
        }

        // Remove the old subtree: hard-delete descendants locally (the
        // server cascades them when the root's delete lands), then tombstone
        // or hard-delete the root itself.
        for (old_id, _) in recreated.iter().skip(1) {
            self.store.delete_task_hard(old_id).await.map_err(|e| e.to_string())?;
        }
        if old.task.etag.is_some() {
            // Synced row → tombstone so the delete reaches the server.
            let mut tomb = old;
            tomb.sync_state = axiotask_core::store::SyncState::Deleted;
            tomb.pending_op = Some("delete".into());
            tomb.local_updated = now;
            self.store.upsert_task(&tomb).await.map_err(|e| e.to_string())?;
        } else {
            // Never synced → hard delete.
            self.store.delete_task_hard(id).await.map_err(|e| e.to_string())?;
        }

        self.schedule_sync();
        Ok(())
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
        self.store.pending_push_count().await.map_err(|e| e.to_string())
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
                .map_err(|e| e.to_string())?;
            let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
            let access_token = body["access_token"]
                .as_str()
                .ok_or("no access_token")?
                .to_string();
            let expires_in = body["expires_in"].as_i64().unwrap_or(3600);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            Ok(StoredTokens {
                access_token,
                refresh_token,
                access_expires_at: Some(now + expires_in),
                scope: "https://www.googleapis.com/auth/tasks".into(),
            })
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
                if holder.is_empty() { String::new() } else { format!(", pid {holder}") },
            ))
        }
        Err(std::fs::TryLockError::Error(e)) => {
            Err(format!("lock {}: {e}", lock_path.display()))
        }
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
            "notes.txt",                  // ignored: wrong name
            "axiotask-backup-old.bak",    // ignored: wrong extension
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
