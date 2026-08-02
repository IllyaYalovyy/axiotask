//! OAuth 2.0 (PKCE) for desktop, plus the small HTTP wrapper that puts the
//! access token onto outbound requests and refreshes it on `401`.
//!
//! See `designs/RFC-001-auth-oauth-pkce.md`.

mod client;
mod error;
pub mod flow;
mod pkce;
mod store;

pub use client::{AuthedClient, RefreshError, RefreshFn, parse_refresh_response};
pub use error::AuthError;
pub use flow::{
    MOBILE_REDIRECT_URI, OAuthConfig, build_auth_url, complete_mobile_login, login, parse_redirect,
};
pub use pkce::{Pkce, PkceParams, random_state};
pub use store::{InMemoryTokenStore, KeyringTokenStore, StoredTokens, TokenStore};
