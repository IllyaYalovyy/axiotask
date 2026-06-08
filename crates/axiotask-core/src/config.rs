//! Application configuration.
//!
//! Loaded from `~/.config/axiotask/config.toml` (XDG) or the platform
//! equivalent. Falls back to defaults if the file doesn't exist.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

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
    /// **Experimental.** Enable full sync, which drops the local cache and
    /// re-pulls all tasks and lists from Google on the next sync. Disabled by
    /// default; behavior may change in a future release.
    pub full_sync_enabled: bool,
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
            full_sync_enabled: false,
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

    /// Default config file path.
    pub fn default_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("axiotask")
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

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
    fn default_sync_config_has_full_sync_disabled() {
        let cfg = SyncConfig::default();
        assert!(!cfg.full_sync_enabled);
    }

    #[test]
    fn load_from_toml_reads_full_sync_enabled() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            r#"
[sync]
full_sync_enabled = true
"#,
        )
        .unwrap();

        let cfg = AppConfig::load_from(&path).unwrap();
        assert!(cfg.sync.full_sync_enabled);
    }

    #[test]
    fn default_toml_keeps_full_sync_disabled() {
        let content = AppConfig::default_toml();
        let cfg: AppConfig = toml::from_str(content).unwrap();
        assert!(!cfg.sync.full_sync_enabled);
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
}
