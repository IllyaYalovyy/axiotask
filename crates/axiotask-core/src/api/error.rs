//! Typed errors surfaced by [`super::GoogleTasksClient`].

use std::time::Duration;
use thiserror::Error;

/// API-level errors. The sync engine matches on these to decide whether to
/// retry, refresh tokens, or give up.
#[derive(Debug, Error)]
pub enum ApiError {
    /// The request was rejected because the access token was missing,
    /// expired, or revoked. Caller should refresh and retry once.
    #[error("unauthorized")]
    Unauthorized,

    /// The target row no longer exists on the server.
    #[error("not found")]
    NotFound,

    /// Optimistic-concurrency failure (e.g. `If-Match` etag mismatch).
    /// Caller should pull, merge, and retry.
    #[error("precondition failed (etag mismatch)")]
    PreconditionFailed,

    /// Server is rate-limiting. Honor the optional `retry_after` hint.
    #[error("rate limited (retry after {retry_after:?})")]
    RateLimited {
        /// Suggested delay before retrying.
        retry_after: Option<Duration>,
    },

    /// Server returned a 5xx; transient.
    #[error("server error: {status}")]
    Server {
        /// HTTP status code.
        status: u16,
    },

    /// Network / transport failure.
    #[error("network: {0}")]
    Network(String),

    /// Anything else — non-retryable by default.
    #[error("other: {0}")]
    Other(String),
}

impl ApiError {
    /// Whether the caller should retry after a short delay.
    pub fn is_transient(&self) -> bool {
        matches!(
            self,
            Self::RateLimited { .. } | Self::Server { .. } | Self::Network(_)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transient_classification() {
        assert!(ApiError::Server { status: 503 }.is_transient());
        assert!(ApiError::RateLimited { retry_after: None }.is_transient());
        assert!(ApiError::Network("connect refused".into()).is_transient());
        assert!(!ApiError::Unauthorized.is_transient());
        assert!(!ApiError::NotFound.is_transient());
        assert!(!ApiError::PreconditionFailed.is_transient());
        assert!(!ApiError::Other("bad json".into()).is_transient());
    }
}
