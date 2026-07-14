//! HTTP wrapper that puts the current access token onto outbound requests and
//! refreshes it (once) when the server says `401`.

use std::sync::Arc;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::Method;

use super::store::{StoredTokens, TokenStore};

/// Why a token refresh failed — the split the sync engine needs to pick
/// between "retry later" and "make the user sign in again".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefreshError {
    /// The grant itself is dead (`invalid_grant`: token expired or revoked,
    /// `invalid_client`, `unauthorized_client`). No retry will ever succeed;
    /// the user must go through the OAuth flow again.
    Denied(String),
    /// Network trouble, a 5xx from the token endpoint, an unparseable
    /// response — worth retrying later with the same refresh token.
    Transient(String),
}

impl std::fmt::Display for RefreshError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Denied(m) => write!(f, "refresh denied: {m}"),
            Self::Transient(m) => write!(f, "refresh failed: {m}"),
        }
    }
}

/// Interpret a token-endpoint refresh response.
///
/// OAuth error responses carry a machine-readable `error` code in the JSON
/// body (RFC 6749 §5.2); that code — not the HTTP status — decides whether
/// the grant is dead or the failure is retryable. Google returns
/// `invalid_grant` with HTTP 400 both for expired/revoked tokens (permanent)
/// and never for transient conditions, so grant-level codes map to
/// [`RefreshError::Denied`] and everything else to `Transient`.
///
/// `refresh_token` is carried over unless the response rotates it (Google
/// normally omits it on refresh). Pure so it is unit-testable; the caller
/// does the HTTP.
pub fn parse_refresh_response(
    http_status: u16,
    body: &str,
    refresh_token: String,
    scope_fallback: &str,
    now_epoch: i64,
) -> Result<StoredTokens, RefreshError> {
    let json: serde_json::Value = serde_json::from_str(body).unwrap_or(serde_json::Value::Null);
    if let Some(code) = json["error"].as_str() {
        let desc = json["error_description"].as_str().unwrap_or("");
        let msg = if desc.is_empty() { code.to_string() } else { format!("{code}: {desc}") };
        return Err(match code {
            "invalid_grant" | "invalid_client" | "unauthorized_client" => {
                RefreshError::Denied(msg)
            }
            _ => RefreshError::Transient(msg),
        });
    }
    if !(200..300).contains(&http_status) {
        let head: String = body.chars().take(200).collect();
        return Err(RefreshError::Transient(format!(
            "token endpoint returned {http_status}: {head}"
        )));
    }
    let access_token = json["access_token"]
        .as_str()
        .ok_or_else(|| RefreshError::Transient("token response has no access_token".into()))?
        .to_string();
    let expires_in = json["expires_in"].as_i64().unwrap_or(3600);
    Ok(StoredTokens {
        access_token,
        // Adopt a rotated refresh token if the server sent one.
        refresh_token: json["refresh_token"]
            .as_str()
            .map(str::to_string)
            .unwrap_or(refresh_token),
        access_expires_at: Some(now_epoch + expires_in),
        scope: json["scope"].as_str().unwrap_or(scope_fallback).to_string(),
    })
}

/// Function used to acquire a fresh access token, given the current refresh
/// token. Returns the new bundle (which may include a rotated refresh token).
///
/// Boxed and stored as `Arc` so the wrapper itself is `Clone`-friendly.
pub type RefreshFn = Arc<
    dyn Fn(String) -> futures::future::BoxFuture<'static, Result<StoredTokens, RefreshError>>
        + Send
        + Sync,
>;

/// Authenticated `reqwest`-style client.
///
/// Holds the most recent access token in memory and writes any rotation back
/// to the [`TokenStore`]. On a `401` it refreshes once and replays the request.
#[derive(Clone)]
pub struct AuthedClient {
    http: reqwest::Client,
    tokens: Arc<Mutex<StoredTokens>>,
    store: Arc<dyn TokenStore>,
    refresh: RefreshFn,
}

impl AuthedClient {
    /// Construct from current tokens, a store to persist refreshes to, and a
    /// refresh function that knows how to talk to the token endpoint.
    pub fn new(
        http: reqwest::Client,
        tokens: StoredTokens,
        store: Arc<dyn TokenStore>,
        refresh: RefreshFn,
    ) -> Self {
        Self {
            http,
            tokens: Arc::new(Mutex::new(tokens)),
            store,
            refresh,
        }
    }

    /// Current access token (snapshot).
    pub fn access_token(&self) -> String {
        self.tokens.lock().unwrap().access_token.clone()
    }

    /// Whether the in-memory access token is past its expiry. Conservative —
    /// treats "no expiry known" as not-expired.
    pub fn is_access_expired(&self) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let t = self.tokens.lock().unwrap();
        t.access_expires_at.is_some_and(|exp| now >= exp)
    }

    /// Replace the in-memory tokens and persist them.
    pub fn replace_tokens(&self, new: StoredTokens) -> Result<(), super::AuthError> {
        *self.tokens.lock().unwrap() = new.clone();
        self.store.save(&new)
    }

    /// Force a refresh now. Useful for `refresh-on-401` paths and tests.
    ///
    /// A failure to persist the rotated tokens is reported as transient: the
    /// refresh itself succeeded and the new token is live in memory, so the
    /// caller may proceed and a later attempt can retry the write.
    pub async fn refresh_now(&self) -> Result<(), RefreshError> {
        let refresh_token = self.tokens.lock().unwrap().refresh_token.clone();
        let new = (self.refresh)(refresh_token).await?;
        self.replace_tokens(new)
            .map_err(|e| RefreshError::Transient(format!("persist: {e}")))?;
        Ok(())
    }

    fn make_request(&self, method: Method, url: &str) -> reqwest::RequestBuilder {
        self.http
            .request(method, url)
            .bearer_auth(self.access_token())
    }

    /// GET builder, pre-authenticated. Sending happens via `.send()` on the result.
    pub fn get(&self, url: &str) -> reqwest::RequestBuilder {
        self.make_request(Method::GET, url)
    }

    /// POST builder, pre-authenticated.
    pub fn post(&self, url: &str) -> reqwest::RequestBuilder {
        self.make_request(Method::POST, url)
    }

    /// PATCH builder, pre-authenticated.
    pub fn patch(&self, url: &str) -> reqwest::RequestBuilder {
        self.make_request(Method::PATCH, url)
    }

    /// DELETE builder, pre-authenticated.
    pub fn delete(&self, url: &str) -> reqwest::RequestBuilder {
        self.make_request(Method::DELETE, url)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::InMemoryTokenStore;

    fn fixed_refresh(new_access: &'static str) -> RefreshFn {
        Arc::new(move |_rt: String| {
            Box::pin(async move {
                Ok(StoredTokens {
                    access_token: new_access.into(),
                    refresh_token: "rt".into(),
                    access_expires_at: Some(i64::MAX),
                    scope: "tasks".into(),
                })
            })
        })
    }

    #[tokio::test]
    async fn refresh_now_updates_token_in_memory_and_in_store() {
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());
        let initial = StoredTokens {
            access_token: "old".into(),
            refresh_token: "rt".into(),
            access_expires_at: Some(0),
            scope: "tasks".into(),
        };
        store.save(&initial).unwrap();
        let client = AuthedClient::new(
            reqwest::Client::new(),
            initial,
            store.clone(),
            fixed_refresh("brand-new"),
        );
        assert_eq!(client.access_token(), "old");
        client.refresh_now().await.unwrap();
        assert_eq!(client.access_token(), "brand-new");
        assert_eq!(store.load().unwrap().unwrap().access_token, "brand-new");
    }

    #[test]
    fn refresh_response_invalid_grant_is_denied_not_transient() {
        // Google's exact body for an expired/revoked refresh token (verified
        // live 2026-07-14) — arrives with HTTP 400.
        let body = r#"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#;
        let err = parse_refresh_response(400, body, "rt".into(), "tasks", 0).unwrap_err();
        assert_eq!(
            err,
            RefreshError::Denied("invalid_grant: Token has been expired or revoked.".into())
        );
    }

    #[test]
    fn refresh_response_5xx_and_garbage_are_transient() {
        let err = parse_refresh_response(503, "<html>oops</html>", "rt".into(), "t", 0).unwrap_err();
        assert!(matches!(err, RefreshError::Transient(_)), "{err}");
        // 200 with a body missing access_token (proxy mangling, etc.)
        let err = parse_refresh_response(200, "{}", "rt".into(), "t", 0).unwrap_err();
        assert!(matches!(err, RefreshError::Transient(_)), "{err}");
        // OAuth error code other than the grant-level ones stays retryable.
        let err = parse_refresh_response(400, r#"{"error":"temporarily_unavailable"}"#, "rt".into(), "t", 0)
            .unwrap_err();
        assert!(matches!(err, RefreshError::Transient(_)), "{err}");
    }

    #[test]
    fn refresh_response_success_keeps_or_rotates_the_refresh_token() {
        // Google normally omits refresh_token on refresh — keep the old one.
        let kept = parse_refresh_response(
            200,
            r#"{"access_token":"new-at","expires_in":3599,"scope":"tasks"}"#,
            "old-rt".into(),
            "fallback",
            1_000,
        )
        .unwrap();
        assert_eq!(kept.access_token, "new-at");
        assert_eq!(kept.refresh_token, "old-rt");
        assert_eq!(kept.access_expires_at, Some(4_599));
        assert_eq!(kept.scope, "tasks");
        // ...but adopt a rotated one when present.
        let rotated = parse_refresh_response(
            200,
            r#"{"access_token":"at","refresh_token":"fresh-rt"}"#,
            "old-rt".into(),
            "fallback",
            0,
        )
        .unwrap();
        assert_eq!(rotated.refresh_token, "fresh-rt");
        assert_eq!(rotated.scope, "fallback");
    }

    #[test]
    fn is_access_expired_handles_unset_expiry_as_not_expired() {
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());
        let tokens = StoredTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            access_expires_at: None,
            scope: "".into(),
        };
        let client = AuthedClient::new(reqwest::Client::new(), tokens, store, fixed_refresh("x"));
        assert!(!client.is_access_expired());
    }
}
