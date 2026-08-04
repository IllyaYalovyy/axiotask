use serde::{Deserialize, Serialize};

/// Request for an access token for the `tasks` scope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizeRequest {
    /// `true` allows the account picker + consent sheet (the sign-in gesture);
    /// `false` must never show UI (background sync / the `401` refresh path).
    pub interactive: bool,
}

/// Result of an authorize call.
///
/// `access_token` is present when Play Services returned a token. When a
/// non-interactive call needs user interaction (no account yet, or the grant was
/// revoked) it returns `needs_interaction: true` with no token, rather than an
/// error — the Rust side maps that to `InteractionRequired`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorizeResponse {
    pub access_token: Option<String>,
    #[serde(default)]
    pub needs_interaction: bool,
}
