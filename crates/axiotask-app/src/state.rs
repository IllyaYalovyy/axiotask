//! Application state: store, sync engine, and background scheduler.

use std::path::PathBuf;
use std::sync::Arc;
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

/// Shared application state managed by Tauri.
pub struct AppState {
    pub store: Store,
    client: Arc<Mutex<Arc<dyn GoogleTasksClient>>>,
    token_store: Arc<dyn TokenStore>,
    oauth_config: OAuthConfig,
    sync_notify: Arc<Notify>,
    /// Serializes sync runs — only one sync executes at a time (RFC-004).
    sync_guard: Arc<Mutex<()>>,
    push_enabled: bool,
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
            push_enabled: config.sync.push_enabled,
        };
        state.ensure_default_list().await;
        Ok(state)
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
            push_enabled,
        };
        state.ensure_default_list().await;
        Ok(state)
    }

    /// Whether we have stored tokens (user is logged in).
    pub fn is_authenticated(&self) -> bool {
        matches!(self.token_store.load(), Ok(Some(_)))
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
        let now = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
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
            if self.is_authenticated() {
                if let Err(e) = self.run_sync_if_authed().await {
                    tracing::warn!("background sync failed: {e}");
                }
            }
        }
    }

    /// Run sync immediately. Does not check authentication — use `run_sync_if_authed` for guarded access.
    ///
    /// Serialized via `sync_guard`: if another sync is in progress, this call
    /// waits for it to finish before running. Prevents double-push races.
    pub async fn run_sync(&self) -> Result<SyncOutcome, axiotask_core::sync::SyncError> {
        let _guard = self.sync_guard.lock().await;
        tracing::info!("running sync (push_enabled={})...", self.push_enabled);
        let client = self.client.lock().await.clone();
        let engine = SyncEngine::with_push(client, self.store.clone(), self.push_enabled);
        let result = engine.run().await;
        match &result {
            Ok(o) => tracing::info!("sync complete: pulled={}, pushed={}, conflicts={}", o.pulled, o.pushed, o.conflicts),
            Err(e) => tracing::error!("sync failed: {e}"),
        }
        result
    }

    /// Run sync only if the user is authenticated. Returns an error if not signed in.
    pub async fn run_sync_if_authed(&self) -> Result<SyncOutcome, String> {
        if !self.is_authenticated() {
            return Err("not authenticated".into());
        }
        self.run_sync().await.map_err(|e| e.to_string())
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
        list.local_updated = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
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
            list.local_updated = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
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

        let now = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();

        // Create the task in the target list with a fresh local id.
        let mut new_task = old.clone();
        new_task.task.id = uuid::Uuid::new_v4().to_string();
        new_task.task.parent = None; // top-level in the new list
        new_task.task.etag = None; // brand-new remote row
        new_task.list_id = target_list_id.to_string();
        new_task.sync_state = axiotask_core::store::SyncState::Dirty;
        new_task.pending_op = Some("create".into());
        new_task.local_updated = now.clone();
        self.store.upsert_task(&new_task).await.map_err(|e| e.to_string())?;

        // Remove the task from the old list.
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
    #[cfg(test)]
    pub fn push_enabled(&self) -> bool {
        self.push_enabled
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

/// Default database path: `$XDG_DATA_HOME/axiotask/axiotask.sqlite`
pub fn default_db_path() -> PathBuf {
    let data = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    data.join("axiotask").join("axiotask.sqlite")
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
