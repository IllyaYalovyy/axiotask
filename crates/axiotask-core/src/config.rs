//! Application configuration.
//!
//! Loaded from `~/.config/axiotask/config.toml` (XDG) or the platform
//! equivalent. Falls back to defaults if the file doesn't exist.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Base application name, used for the per-user config/data directories.
pub const APP_NAME: &str = "axiotask";

/// Environment variable that selects an isolated instance. When set to a
/// non-empty value (e.g. `AXIOTASK_PREFIX=dev`), every per-user location —
/// config, database, auth tokens, and backups — is namespaced under
/// `axiotask-<prefix>` instead of `axiotask`, so a development or test instance
/// runs fully isolated from the production instance on the same machine.
pub const INSTANCE_ENV: &str = "AXIOTASK_PREFIX";

/// Validate an instance prefix. Allowed: ASCII letters, digits, `-` and `_`,
/// up to 64 chars. This both keeps directory names tidy and prevents path
/// traversal (no `/`, `\`, `.`), so the prefix can be trusted in a path.
fn sanitize_prefix(raw: &str) -> Result<String, String> {
    if raw.is_empty() {
        return Err("must not be empty".into());
    }
    if raw.len() > 64 {
        return Err("must be at most 64 characters".into());
    }
    if !raw
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!(
            "{raw:?} contains invalid characters (allowed: letters, digits, '-', '_')"
        ));
    }
    Ok(raw.to_string())
}

/// The active instance prefix from [`INSTANCE_ENV`], or `None` for the default
/// (production) instance.
///
/// If the variable is set but invalid this **panics** rather than returning
/// `None`: silently falling back to the default would point an instance the
/// user intended to isolate at the production config and data, which is exactly
/// the accident this feature exists to prevent.
pub fn instance_prefix() -> Option<String> {
    match std::env::var(INSTANCE_ENV) {
        Ok(raw) if raw.trim().is_empty() => None,
        Ok(raw) => Some(
            sanitize_prefix(raw.trim()).unwrap_or_else(|e| panic!("invalid {INSTANCE_ENV}: {e}")),
        ),
        Err(_) => None,
    }
}

/// Directory name for the active instance: `axiotask`, or `axiotask-<prefix>`
/// when [`INSTANCE_ENV`] selects an isolated instance.
pub fn app_dir_name() -> String {
    app_dir_name_for(instance_prefix().as_deref())
}

/// Pure helper behind [`app_dir_name`] — testable without the environment.
fn app_dir_name_for(prefix: Option<&str>) -> String {
    match prefix {
        Some(p) => format!("{APP_NAME}-{p}"),
        None => APP_NAME.to_string(),
    }
}

/// Top-level application configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    /// Google OAuth settings.
    pub google: GoogleConfig,
    /// Sync behavior.
    pub sync: SyncConfig,
}

/// Google API credentials and settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct GoogleConfig {
    /// OAuth client ID.
    pub client_id: String,
    /// OAuth client secret.
    pub client_secret: String,
    /// OAuth scopes.
    pub scopes: Vec<String>,
}

/// Sync settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SyncConfig {
    /// Whether to push local changes to Google.
    pub push_enabled: bool,
    /// Auto-sync on startup.
    pub auto_sync_on_start: bool,
}

impl Default for GoogleConfig {
    fn default() -> Self {
        Self {
            client_id: String::new(),
            client_secret: String::new(),
            scopes: vec!["https://www.googleapis.com/auth/tasks".into()],
        }
    }
}

impl Default for SyncConfig {
    fn default() -> Self {
        Self {
            push_enabled: false,
            auto_sync_on_start: true,
        }
    }
}

impl AppConfig {
    /// Load config from the default path, or return defaults if not found.
    pub fn load() -> Self {
        let path = Self::default_path();
        Self::load_from(&path).unwrap_or_default()
    }

    /// Load from a specific path.
    pub fn load_from(path: &std::path::Path) -> Option<Self> {
        let content = std::fs::read_to_string(path).ok()?;
        toml::from_str(&content).ok()
    }

    /// Default config file path (instance-aware via [`INSTANCE_ENV`]).
    pub fn default_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(app_dir_name())
            .join("config.toml")
    }

    /// Write a default config file if none exists.
    pub fn write_default_if_missing() {
        let path = Self::default_path();
        Self::write_default_if_missing_at(&path);
    }

    /// Write a default config file at the given path if it doesn't exist.
    pub fn write_default_if_missing_at(path: &std::path::Path) {
        if path.exists() {
            return;
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let default = Self::default_toml();
        let _ = std::fs::write(path, default);
    }

    /// Returns the embedded default config TOML content.
    pub fn default_toml() -> &'static str {
        include_str!("../config.default.toml")
    }

    /// Persist the `[sync]` settings to `path`, preserving the rest of the
    /// file — existing formatting, comments, and the `[google]` credentials.
    ///
    /// Uses `toml_edit` so a user's hand-written config (including the helpful
    /// comments from the default template) survives a settings change made in
    /// the app. If the file does not exist yet it is created from the embedded
    /// default template first, so the comments are present either way.
    pub fn save_sync_to(path: &std::path::Path, sync: &SyncConfig) -> std::io::Result<()> {
        let text =
            std::fs::read_to_string(path).unwrap_or_else(|_| Self::default_toml().to_string());
        // Fall back to the default template if the existing file is malformed,
        // rather than silently dropping the user's settings into a blank doc.
        let mut doc = text
            .parse::<toml_edit::DocumentMut>()
            .or_else(|_| Self::default_toml().parse::<toml_edit::DocumentMut>())
            .expect("embedded default config is valid TOML");

        if !doc.contains_key("sync") {
            doc["sync"] = toml_edit::table();
        }
        doc["sync"]["push_enabled"] = toml_edit::value(sync.push_enabled);
        doc["sync"]["auto_sync_on_start"] = toml_edit::value(sync.auto_sync_on_start);

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, doc.to_string())
    }

    /// Persist the `[sync]` settings to the default config path.
    pub fn save_sync(sync: &SyncConfig) -> std::io::Result<()> {
        Self::save_sync_to(&Self::default_path(), sync)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn app_dir_name_default_and_prefixed() {
        assert_eq!(app_dir_name_for(None), "axiotask");
        assert_eq!(app_dir_name_for(Some("dev")), "axiotask-dev");
        assert_eq!(app_dir_name_for(Some("qa_2")), "axiotask-qa_2");
    }

    #[test]
    fn sanitize_prefix_accepts_safe_names() {
        assert_eq!(sanitize_prefix("dev").unwrap(), "dev");
        assert_eq!(sanitize_prefix("Test-1_b").unwrap(), "Test-1_b");
    }

    #[test]
    fn sanitize_prefix_rejects_unsafe_names() {
        // Empty, path separators, traversal, spaces, and over-length all fail —
        // a malformed prefix must never resolve to a usable directory name.
        assert!(sanitize_prefix("").is_err());
        assert!(sanitize_prefix("../prod").is_err());
        assert!(sanitize_prefix("a/b").is_err());
        assert!(sanitize_prefix("a\\b").is_err());
        assert!(sanitize_prefix("with space").is_err());
        assert!(sanitize_prefix("dot.dot").is_err());
        assert!(sanitize_prefix(&"x".repeat(65)).is_err());
    }

    #[test]
    fn default_google_config_has_empty_credentials() {
        let cfg = GoogleConfig::default();
        assert!(cfg.client_id.is_empty());
        assert!(cfg.client_secret.is_empty());
    }

    #[test]
    fn default_google_config_has_tasks_scope() {
        let cfg = GoogleConfig::default();
        assert_eq!(cfg.scopes, vec!["https://www.googleapis.com/auth/tasks"]);
    }

    #[test]
    fn default_sync_config_has_push_disabled() {
        let cfg = SyncConfig::default();
        assert!(!cfg.push_enabled);
    }

    #[test]
    fn default_sync_config_has_auto_sync_enabled() {
        let cfg = SyncConfig::default();
        assert!(cfg.auto_sync_on_start);
    }

    #[test]
    fn load_from_missing_file_returns_none() {
        let path = std::path::Path::new("/nonexistent/path/config.toml");
        assert!(AppConfig::load_from(path).is_none());
    }

    #[test]
    fn load_from_valid_toml() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            r#"
[google]
client_id = "my-id"
client_secret = "my-secret"
scopes = ["https://www.googleapis.com/auth/tasks"]

[sync]
push_enabled = false
auto_sync_on_start = false
"#,
        )
        .unwrap();

        let cfg = AppConfig::load_from(&path).unwrap();
        assert_eq!(cfg.google.client_id, "my-id");
        assert_eq!(cfg.google.client_secret, "my-secret");
        assert!(!cfg.sync.push_enabled);
        assert!(!cfg.sync.auto_sync_on_start);
    }

    #[test]
    fn load_from_partial_toml_uses_defaults() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            r#"
[google]
client_id = "partial-id"
"#,
        )
        .unwrap();

        let cfg = AppConfig::load_from(&path).unwrap();
        assert_eq!(cfg.google.client_id, "partial-id");
        assert!(cfg.google.client_secret.is_empty());
        assert!(cfg.sync.auto_sync_on_start); // default
    }

    #[test]
    fn write_default_creates_file_when_missing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("axiotask").join("config.toml");
        assert!(!path.exists());

        AppConfig::write_default_if_missing_at(&path);

        assert!(path.exists());
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("[google]"));
        assert!(content.contains("[sync]"));
        assert!(content.contains("client_id"));
    }

    #[test]
    fn write_default_does_not_overwrite_existing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        let custom = "# my custom config\n";
        std::fs::write(&path, custom).unwrap();

        AppConfig::write_default_if_missing_at(&path);

        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content, custom);
    }

    #[test]
    fn default_toml_is_parseable() {
        let content = AppConfig::default_toml();
        let cfg: AppConfig = toml::from_str(content).unwrap();
        assert!(cfg.google.client_id.is_empty());
        assert!(!cfg.sync.push_enabled);
    }

    #[test]
    fn save_sync_round_trips_values() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        let sync = SyncConfig {
            push_enabled: true,
            auto_sync_on_start: false,
        };
        AppConfig::save_sync_to(&path, &sync).unwrap();

        let cfg = AppConfig::load_from(&path).unwrap();
        assert!(cfg.sync.push_enabled);
        assert!(!cfg.sync.auto_sync_on_start);
    }

    #[test]
    fn save_sync_preserves_credentials_and_comments() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "# my hand-written config\n\
             [google]\n\
             client_id = \"keep-me\"\n\
             client_secret = \"secret-too\"\n\
             scopes = [\"https://www.googleapis.com/auth/tasks\"]\n\n\
             [sync]\n\
             # push comment\n\
             push_enabled = false\n",
        )
        .unwrap();

        AppConfig::save_sync_to(
            &path,
            &SyncConfig {
                push_enabled: true,
                ..Default::default()
            },
        )
        .unwrap();

        let raw = std::fs::read_to_string(&path).unwrap();
        // Credentials and comments survive the write.
        assert!(raw.contains("client_id = \"keep-me\""));
        assert!(raw.contains("client_secret = \"secret-too\""));
        assert!(raw.contains("# my hand-written config"));
        assert!(raw.contains("# push comment"));
        // And the toggled value is persisted.
        let cfg = AppConfig::load_from(&path).unwrap();
        assert!(cfg.sync.push_enabled);
        assert_eq!(cfg.google.client_id, "keep-me");
    }

    #[test]
    fn save_sync_creates_file_from_template_when_missing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("config.toml");
        AppConfig::save_sync_to(
            &path,
            &SyncConfig {
                push_enabled: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(path.exists());
        let raw = std::fs::read_to_string(&path).unwrap();
        // Created from the documented template, so the helpful comments exist.
        assert!(raw.contains("[google]"));
        assert!(raw.contains("push_enabled = true"));
    }
}
