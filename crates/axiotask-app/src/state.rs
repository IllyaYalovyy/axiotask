//! Application state: store, sync engine, and background scheduler.

use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::{Mutex, Notify};

use axiotask_core::api::{GoogleTasksClient, HttpClient, InMemoryClient};
use axiotask_core::auth::{
    AuthedClient, InMemoryTokenStore, OAuthConfig, RefreshFn, StoredTokens,
    TokenStore,
};
use axiotask_core::store::Store;
use axiotask_core::sync::{SyncEngine, SyncOutcome};

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
        };
        state.ensure_default_list().await;
        Ok(state)
    }

    /// Build state with an in-memory database (for tests).
    #[allow(dead_code)]
    pub async fn new_memory(client: Arc<dyn GoogleTasksClient>) -> Result<Self, String> {
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

    /// Signal the background sync loop to run soon.
    pub fn schedule_sync(&self) {
        self.sync_notify.notify_one();
    }

    /// Run sync immediately.
    pub async fn run_sync(&self) -> Result<SyncOutcome, axiotask_core::sync::SyncError> {
        tracing::info!("running sync...");
        let client = self.client.lock().await.clone();
        let engine = SyncEngine::new(client, self.store.clone());
        let result = engine.run().await;
        match &result {
            Ok(o) => tracing::info!("sync complete: pulled={}, pushed={}, conflicts={}", o.pulled, o.pushed, o.conflicts),
            Err(e) => tracing::error!("sync failed: {e}"),
        }
        result
    }

    /// Get a handle to the notify for the background loop.
    pub fn sync_notify(&self) -> Arc<Notify> {
        self.sync_notify.clone()
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
