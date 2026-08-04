//! Android on-device token provider (RFC-010).
//!
//! On Android the app does not own OAuth tokens. Google Play Services holds the
//! grant and hands out short-lived access tokens on demand through its
//! `AuthorizationClient`. This module defines the platform-agnostic seam the app
//! plugs that mechanism into: a [`MobileTokenProvider`] trait the real Kotlin
//! plugin implements, a [`FakeTokenProvider`] so the flow is unit-testable
//! without a device, and [`provider_refresh_fn`] which adapts any provider to
//! the existing [`RefreshFn`] seam that [`AuthedClient`](super::AuthedClient)
//! already refreshes on `401`.
//!
//! Desktop auth (loopback PKCE with a real refresh token, RFC-001) is untouched
//! and never uses this module.

use std::sync::Arc;

use async_trait::async_trait;

use super::client::{RefreshError, RefreshFn};
use super::store::StoredTokens;

/// The single scope the app ever asks Play Services for.
const TASKS_SCOPE: &str = "https://www.googleapis.com/auth/tasks";

/// Why an on-device token acquisition failed.
///
/// The split is exactly the one the sync engine needs: a revoked/absent grant
/// is permanent (the user must sign in again), everything else is worth a later
/// retry with no user action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenProviderError {
    /// Play Services needs user interaction — the account picker or a fresh
    /// consent — but the call was non-interactive (background sync), or the
    /// grant was revoked from Google's side. Outside a sign-in gesture this is
    /// the Android shape of a dead session: it maps to
    /// [`RefreshError::Denied`], which the API layer turns into `AuthExpired`
    /// and the app surfaces as `needs_reauth`.
    InteractionRequired,
    /// A transient failure: Play Services missing/updating, a GMS error, or no
    /// network. Worth retrying later without bothering the user — maps to
    /// [`RefreshError::Transient`].
    Unavailable(String),
}

impl std::fmt::Display for TokenProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InteractionRequired => {
                write!(f, "interactive sign-in required")
            }
            Self::Unavailable(m) => write!(f, "authorization unavailable: {m}"),
        }
    }
}

/// A source of Google access tokens for the `tasks` scope on Android.
///
/// Implemented for real by the in-repo `tauri-plugin-google-auth` plugin over
/// Play Services' `AuthorizationClient`, and by [`FakeTokenProvider`] in tests.
///
/// There is deliberately no refresh-token concept here: Play Services owns the
/// grant, so the app only ever asks for a *fresh access token*. The `sign_out`
/// method drops the account association so the next `authorize` shows the
/// picker.
#[async_trait]
pub trait MobileTokenProvider: Send + Sync {
    /// Acquire a fresh access token for the `tasks` scope.
    ///
    /// `interactive == false` MUST NOT show any UI — it is used by background
    /// sync and by the `401` refresh path, where popping consent would be a
    /// bug. It returns a token silently when the grant is live and
    /// [`TokenProviderError::InteractionRequired`] when it is not.
    ///
    /// `interactive == true` is the sign-in gesture: it may launch the account
    /// picker + consent (the `PendingIntent`) and await its result.
    async fn authorize(&self, interactive: bool) -> Result<String, TokenProviderError>;

    /// Drop the account association so the next sign-in shows the picker.
    async fn sign_out(&self) -> Result<(), TokenProviderError>;
}

/// Adapt a [`MobileTokenProvider`] to the [`RefreshFn`] the
/// [`AuthedClient`](super::AuthedClient) refreshes with on `401`.
///
/// The incoming refresh-token argument is ignored on purpose: Android has no
/// refresh token, so the "refresh" is a **non-interactive** `authorize()` — a
/// silent Play Services token fetch that must never show UI mid-sync. The
/// returned bundle carries an empty refresh token and no known expiry
/// (`access_expires_at: None`), so [`AuthedClient`](super::AuthedClient) never
/// pre-emptively refreshes and instead asks the provider again only when the
/// server actually returns `401` — matching Play Services' own model, where a
/// fresh token is always one silent call away.
pub fn provider_refresh_fn(provider: Arc<dyn MobileTokenProvider>) -> RefreshFn {
    Arc::new(move |_ignored_refresh_token: String| {
        let provider = provider.clone();
        Box::pin(async move {
            match provider.authorize(false).await {
                Ok(access_token) => Ok(StoredTokens {
                    access_token,
                    // No refresh token exists on Android — Play Services owns
                    // the grant. Nothing is ever persisted from this bundle.
                    refresh_token: String::new(),
                    // Unknown expiry → treated as not-expired, so refresh
                    // happens reactively on 401, never on a timer.
                    access_expires_at: None,
                    scope: TASKS_SCOPE.to_string(),
                }),
                // A silent authorize demanding interaction is a dead session:
                // reuse the existing Denied → AuthExpired → needs_reauth path.
                Err(TokenProviderError::InteractionRequired) => Err(RefreshError::Denied(
                    "Google sign-in needs to be renewed".to_string(),
                )),
                Err(TokenProviderError::Unavailable(m)) => Err(RefreshError::Transient(m)),
            }
        })
    })
}

/// A scripted [`MobileTokenProvider`] for tests (no device, no Play Services).
///
/// Mirrors the real plugin's contract closely enough to exercise every branch:
/// a live grant (interactive and silent), a grant that needs interaction, and a
/// transient outage. `authorize` records how many times it was called and with
/// what `interactive` flag so a test can prove background sync never asked for
/// UI.
pub struct FakeTokenProvider {
    outcome: std::sync::Mutex<FakeOutcome>,
    /// Every `authorize(interactive)` call, in order.
    calls: std::sync::Mutex<Vec<bool>>,
    signed_out: std::sync::atomic::AtomicBool,
}

/// What the fake returns from the next `authorize`.
#[derive(Clone)]
enum FakeOutcome {
    /// A live grant: hand out this access token (silently or interactively).
    Token(String),
    /// The grant needs interaction (revoked, or first sign-in never happened).
    NeedsInteraction,
    /// A transient outage.
    Unavailable(String),
}

impl FakeTokenProvider {
    /// A provider with a live grant that returns `token` on every `authorize`.
    pub fn with_token(token: impl Into<String>) -> Self {
        Self::new(FakeOutcome::Token(token.into()))
    }

    /// A provider whose grant needs interactive sign-in (revoked / never done).
    pub fn needs_interaction() -> Self {
        Self::new(FakeOutcome::NeedsInteraction)
    }

    /// A provider that is transiently unavailable (e.g. Play Services updating).
    pub fn unavailable(msg: impl Into<String>) -> Self {
        Self::new(FakeOutcome::Unavailable(msg.into()))
    }

    fn new(outcome: FakeOutcome) -> Self {
        Self {
            outcome: std::sync::Mutex::new(outcome),
            calls: std::sync::Mutex::new(Vec::new()),
            signed_out: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Switch the outcome future `authorize` calls will return (e.g. simulate a
    /// grant coming alive after an interactive sign-in).
    pub fn set_token(&self, token: impl Into<String>) {
        *self.outcome.lock().unwrap() = FakeOutcome::Token(token.into());
    }

    /// The `interactive` flag of every `authorize` call so far, in order.
    pub fn calls(&self) -> Vec<bool> {
        self.calls.lock().unwrap().clone()
    }

    /// Whether `sign_out` was invoked.
    pub fn was_signed_out(&self) -> bool {
        self.signed_out.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[async_trait]
impl MobileTokenProvider for FakeTokenProvider {
    async fn authorize(&self, interactive: bool) -> Result<String, TokenProviderError> {
        self.calls.lock().unwrap().push(interactive);
        match self.outcome.lock().unwrap().clone() {
            FakeOutcome::Token(t) => Ok(t),
            FakeOutcome::NeedsInteraction => Err(TokenProviderError::InteractionRequired),
            FakeOutcome::Unavailable(m) => Err(TokenProviderError::Unavailable(m)),
        }
    }

    async fn sign_out(&self) -> Result<(), TokenProviderError> {
        self.signed_out
            .store(true, std::sync::atomic::Ordering::Relaxed);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::client::RefreshError;

    #[tokio::test]
    async fn silent_refresh_fetches_a_fresh_token_without_ui() {
        // The 401 path: AuthedClient calls the RefreshFn, which must ask the
        // provider NON-interactively and hand back the fresh access token. A
        // background refresh that popped consent would be a bug.
        let provider = Arc::new(FakeTokenProvider::with_token("fresh-access"));
        let refresh = provider_refresh_fn(provider.clone());

        let tokens = refresh("ignored-refresh-token".to_string())
            .await
            .expect("a live grant refreshes silently");

        assert_eq!(tokens.access_token, "fresh-access");
        assert!(
            tokens.refresh_token.is_empty(),
            "Android has no refresh token — nothing to persist (RFC-010 G4)"
        );
        assert_eq!(tokens.access_expires_at, None, "expiry is reactive on 401");
        assert_eq!(
            provider.calls(),
            vec![false],
            "the refresh path must ask the provider silently, never interactively"
        );
    }

    #[tokio::test]
    async fn silent_refresh_needing_interaction_is_denied_not_transient() {
        // needs_reauth mapping: a silent authorize that demands interaction is a
        // dead session (grant revoked / never granted). It must surface as
        // Denied so the API layer maps it to AuthExpired → needs_reauth, NOT as
        // a transient blip that would retry forever.
        let provider = Arc::new(FakeTokenProvider::needs_interaction());
        let refresh = provider_refresh_fn(provider);

        let err = refresh("ignored".to_string())
            .await
            .expect_err("a revoked grant must fail the refresh");

        assert!(
            matches!(err, RefreshError::Denied(_)),
            "interaction-required outside a gesture is a dead session, got {err:?}"
        );
    }

    #[tokio::test]
    async fn silent_refresh_when_unavailable_is_transient() {
        // Play Services updating / no network: retry later, do NOT force the
        // user to sign in again.
        let provider = Arc::new(FakeTokenProvider::unavailable("gms updating"));
        let refresh = provider_refresh_fn(provider);

        let err = refresh("ignored".to_string())
            .await
            .expect_err("an outage must fail the refresh");

        assert!(
            matches!(err, RefreshError::Transient(_)),
            "a transient outage must stay retryable, got {err:?}"
        );
    }

    #[tokio::test]
    async fn interactive_authorize_is_the_sign_in_gesture() {
        // The sign-in gesture asks interactively and gets a token.
        let provider = FakeTokenProvider::needs_interaction();
        // Before sign-in, a silent probe reports interaction required...
        assert_eq!(
            provider.authorize(false).await,
            Err(TokenProviderError::InteractionRequired)
        );
        // ...the gesture completes and the grant comes alive.
        provider.set_token("after-consent");
        assert_eq!(provider.authorize(true).await, Ok("after-consent".into()));
        assert_eq!(
            provider.calls(),
            vec![false, true],
            "records both the silent probe and the interactive gesture"
        );
    }

    #[tokio::test]
    async fn sign_out_is_recorded() {
        let provider = FakeTokenProvider::with_token("t");
        assert!(!provider.was_signed_out());
        provider.sign_out().await.unwrap();
        assert!(provider.was_signed_out());
    }
}
