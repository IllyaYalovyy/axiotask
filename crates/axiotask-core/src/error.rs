//! Crate-wide error type.

use thiserror::Error;

/// Result alias used throughout the crate.
pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Top-level error variants surfaced by the core crate.
#[derive(Debug, Error)]
pub enum Error {
    /// A Google Tasks API call failed.
    #[error(transparent)]
    Api(#[from] crate::api::ApiError),

    /// An OAuth / token-store operation failed.
    #[error(transparent)]
    Auth(#[from] crate::auth::AuthError),

    /// A persistence operation failed.
    #[error(transparent)]
    Store(#[from] crate::store::StoreError),

    /// A sync run failed.
    #[error(transparent)]
    Sync(#[from] crate::sync::SyncError),

    /// JSON (de)serialization failed.
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    /// Catch-all wrapper. Use sparingly.
    #[error("{0}")]
    Other(String),
}
