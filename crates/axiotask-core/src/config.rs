//! Application configuration.
//!
//! Loaded from `~/.config/axiotask/config.toml` (XDG) or the platform
//! equivalent. Falls back to defaults if the file doesn't exist.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Top-level application configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
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

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            google: GoogleConfig::default(),
            sync: SyncConfig::default(),
        }
    }
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
        if path.exists() {
            return;
        }
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let default = include_str!("../config.default.toml");
        let _ = std::fs::write(&path, default);
    }
}
