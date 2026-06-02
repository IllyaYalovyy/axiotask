//! Errors specific to a sync run.

use thiserror::Error;

/// What can go wrong during a sync. Most variants are recoverable on the next
/// run; `Store` failures are the only ones we treat as fatal.
#[derive(Debug, Error)]
pub enum SyncError {
    /// The underlying API call failed.
    #[error(transparent)]
    Api(#[from] crate::api::ApiError),

    /// Local persistence failed.
    #[error(transparent)]
    Store(#[from] crate::store::StoreError),

    /// Internal invariant violated. Should not happen in production.
    #[error("internal: {0}")]
    Internal(String),
}
