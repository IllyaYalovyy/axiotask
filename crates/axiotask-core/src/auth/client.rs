//! HTTP wrapper that puts the current access token onto outbound requests and
//! refreshes it (once) when the server says `401`.

use std::sync::Arc;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::Method;

use super::store::{StoredTokens, TokenStore};

/// Function used to acquire a fresh access token, given the current refresh
/// token. Returns the new bundle (which may include a rotated refresh token).
///
/// Boxed and stored as `Arc` so the wrapper itself is `Clone`-friendly.
pub type RefreshFn = Arc<
    dyn Fn(String) -> futures::future::BoxFuture<'static, Result<StoredTokens, String>>
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
    pub async fn refresh_now(&self) -> Result<(), String> {
        let refresh_token = self.tokens.lock().unwrap().refresh_token.clone();
        let new = (self.refresh)(refresh_token).await?;
        self.replace_tokens(new)
            .map_err(|e| format!("persist: {e}"))?;
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
