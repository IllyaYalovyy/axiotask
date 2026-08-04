//! OAuth 2.0 (PKCE) for desktop, plus the small HTTP wrapper that puts the
//! access token onto outbound requests and refreshes it on `401`.
//!
//! See `designs/RFC-001-auth-oauth-pkce.md`.

mod client;
mod error;
pub mod flow;
mod pkce;
mod store;
mod token_provider;

pub use client::{AuthedClient, RefreshError, RefreshFn, parse_refresh_response};
pub use error::AuthError;
pub use flow::{OAuthConfig, build_auth_url, login, parse_redirect};
pub use pkce::{Pkce, PkceParams, random_state};
pub use store::{InMemoryTokenStore, KeyringTokenStore, StoredTokens, TokenStore};
pub use token_provider::{
    FakeTokenProvider, MobileTokenProvider, TokenProviderError, provider_refresh_fn,
};
