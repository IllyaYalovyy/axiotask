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

impl SyncError {
    /// Whether this run failure is expected to clear itself on a later run
    /// without any user action (a network blip, a 5xx, a rate-limit). The
    /// scheduler retries these silently at the base cadence. Everything else —
    /// store corruption, a schema mismatch, a non-retryable API rejection, an
    /// internal invariant — is *permanent*: it fails identically on every
    /// retry until something changes, so the scheduler backs off and surfaces
    /// it instead of churning.
    ///
    /// In practice the engine already swallows transient API errors and
    /// returns `Ok` (a partial run), so a transient `SyncError` rarely reaches
    /// the scheduler; classifying it correctly keeps the backoff/attention path
    /// from ever mis-firing on one that does.
    pub fn is_transient(&self) -> bool {
        matches!(self, Self::Api(e) if e.is_transient())
    }

    /// Whether this failure means the stored session is dead and the user must
    /// sign in again (`invalid_grant`). This is its own UI state (needs-reauth)
    /// — neither a silent transient retry nor the generic "needs attention".
    pub fn is_auth_expired(&self) -> bool {
        matches!(self, Self::Api(crate::api::ApiError::AuthExpired(_)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ApiError;

    #[test]
    fn transient_only_for_retryable_api_errors() {
        assert!(SyncError::Api(ApiError::Server { status: 503 }).is_transient());
        assert!(SyncError::Api(ApiError::Network("reset".into())).is_transient());
        assert!(SyncError::Api(ApiError::RateLimited).is_transient());

        // Permanent API rejections are NOT transient.
        assert!(!SyncError::Api(ApiError::Other("bad json".into())).is_transient());
        assert!(!SyncError::Api(ApiError::NotFound).is_transient());
        assert!(!SyncError::Api(ApiError::PreconditionFailed).is_transient());
        // A dead session is its own state, not a transient.
        assert!(!SyncError::Api(ApiError::AuthExpired("invalid_grant".into())).is_transient());
        // Store/internal failures fail identically forever — permanent.
        assert!(!SyncError::Internal("bug".into()).is_transient());
    }

    #[test]
    fn auth_expired_detected_only_for_dead_session() {
        assert!(SyncError::Api(ApiError::AuthExpired("invalid_grant".into())).is_auth_expired());
        assert!(!SyncError::Api(ApiError::Unauthorized).is_auth_expired());
        assert!(!SyncError::Api(ApiError::Server { status: 500 }).is_auth_expired());
        assert!(!SyncError::Internal("bug".into()).is_auth_expired());
    }
}
