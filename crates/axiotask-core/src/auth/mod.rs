//! OAuth 2.0 (PKCE) for desktop, plus the small HTTP wrapper that puts the
//! access token onto outbound requests and refreshes it on `401`.
//!
//! See `designs/RFC-001-auth-oauth-pkce.md`.

mod client;
mod error;
pub mod flow;
mod pkce;
mod store;

pub use client::{AuthedClient, RefreshFn};
pub use error::AuthError;
pub use flow::{OAuthConfig, login};
pub use pkce::{Pkce, PkceParams, random_state};
pub use store::{InMemoryTokenStore, KeyringTokenStore, StoredTokens, TokenStore};
