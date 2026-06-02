//! Errors specific to OAuth, token storage, and request authentication.

use thiserror::Error;

/// Auth-layer errors.
#[derive(Debug, Error)]
pub enum AuthError {
    /// Could not read or write the keychain.
    #[error("keyring: {0}")]
    Keyring(String),

    /// PKCE state parameter mismatched the value we generated — likely CSRF
    /// or stale redirect.
    #[error("state mismatch — possible CSRF")]
    StateMismatch,

    /// The user denied the OAuth consent screen.
    #[error("user denied consent")]
    UserDenied,

    /// Token endpoint returned an error response.
    #[error("token endpoint: {0}")]
    TokenEndpoint(String),

    /// The local redirect server failed to start or receive the redirect.
    #[error("redirect server: {0}")]
    Redirect(String),

    /// No tokens are stored — user has not signed in yet.
    #[error("not signed in")]
    NotSignedIn,

    /// JSON (de)serialization for stored tokens failed.
    #[error("token format: {0}")]
    Format(String),
}
