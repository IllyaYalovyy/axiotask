//! OAuth 2.0 PKCE login flow for desktop apps.
//!
//! Spawns a loopback HTTP server on an ephemeral port, opens the consent URL
//! in the user's browser, waits for the redirect, and exchanges the code for
//! tokens.

use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use url::Url;

use super::error::AuthError;
use super::pkce::{Pkce, random_state};
use super::store::{StoredTokens, TokenStore};

/// Configuration for the OAuth flow.
#[derive(Debug, Clone)]
pub struct OAuthConfig {
    /// Google OAuth client ID (public, embedded in the app).
    pub client_id: String,
    /// Google OAuth client secret (required even for Desktop apps).
    pub client_secret: String,
    /// Scopes to request.
    pub scopes: Vec<String>,
    /// Authorization endpoint.
    pub auth_url: String,
    /// Token endpoint.
    pub token_url: String,
}

impl OAuthConfig {
    /// Default config for Google Tasks.
    pub fn google_tasks(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            scopes: vec!["https://www.googleapis.com/auth/tasks".into()],
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".into(),
            token_url: "https://oauth2.googleapis.com/token".into(),
        }
    }
}

/// Run the full PKCE login flow. Returns stored tokens on success.
pub async fn login(
    config: &OAuthConfig,
    store: &Arc<dyn TokenStore>,
) -> Result<StoredTokens, AuthError> {
    let pkce = Pkce::generate();
    let state_param = random_state();

    // Bind loopback server on ephemeral port.
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| AuthError::Redirect(e.to_string()))?;
    let port = listener
        .local_addr()
        .map_err(|e| AuthError::Redirect(e.to_string()))?
        .port();
    let redirect_uri = format!("http://127.0.0.1:{port}");

    // Build consent URL.
    let auth_url = format!(
        "{}?client_id={}&redirect_uri={}&response_type=code&scope={}&state={}&code_challenge={}&code_challenge_method={}",
        config.auth_url,
        urlencoding::encode(&config.client_id),
        urlencoding::encode(&redirect_uri),
        urlencoding::encode(&config.scopes.join(" ")),
        urlencoding::encode(&state_param),
        urlencoding::encode(&pkce.challenge),
        pkce.method,
    );

    // Open browser.
    open::that(&auth_url).map_err(|e| AuthError::Redirect(format!("open browser: {e}")))?;

    // Wait for redirect.
    let (mut stream, _) = listener
        .accept()
        .await
        .map_err(|e| AuthError::Redirect(e.to_string()))?;

    let mut buf = vec![0u8; 4096];
    let n = stream
        .read(&mut buf)
        .await
        .map_err(|e| AuthError::Redirect(e.to_string()))?;
    let request = String::from_utf8_lossy(&buf[..n]);

    // Parse the GET request line for the code and state.
    let path = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .ok_or_else(|| AuthError::Redirect("no request path".into()))?;

    let full_url = format!("http://127.0.0.1:{port}{path}");
    let parsed = Url::parse(&full_url).map_err(|e| AuthError::Redirect(e.to_string()))?;

    let code = parsed
        .query_pairs()
        .find(|(k, _)| k == "code")
        .map(|(_, v)| v.to_string())
        .ok_or(AuthError::UserDenied)?;

    let returned_state = parsed
        .query_pairs()
        .find(|(k, _)| k == "state")
        .map(|(_, v)| v.to_string())
        .ok_or(AuthError::StateMismatch)?;

    if returned_state != state_param {
        return Err(AuthError::StateMismatch);
    }

    // Send a success response to the browser.
    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h1>Login successful!</h1><p>You can close this tab.</p></body></html>";
    let _ = stream.write_all(response.as_bytes()).await;

    // Exchange code for tokens.
    let tokens = exchange_code(config, &code, &redirect_uri, &pkce.verifier).await?;
    store.save(&tokens)?;
    Ok(tokens)
}

async fn exchange_code(
    config: &OAuthConfig,
    code: &str,
    redirect_uri: &str,
    verifier: &str,
) -> Result<StoredTokens, AuthError> {
    let client = reqwest::Client::new();
    let resp = client
        .post(&config.token_url)
        .form(&[
            ("client_id", config.client_id.as_str()),
            ("client_secret", config.client_secret.as_str()),
            ("code", code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirect_uri),
        ])
        .send()
        .await
        .map_err(|e| AuthError::TokenEndpoint(e.to_string()))?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(AuthError::TokenEndpoint(format!("status error: {body}")));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| AuthError::TokenEndpoint(e.to_string()))?;

    let access_token = body["access_token"]
        .as_str()
        .ok_or_else(|| AuthError::TokenEndpoint("no access_token".into()))?
        .to_string();
    let refresh_token = body["refresh_token"]
        .as_str()
        .ok_or_else(|| AuthError::TokenEndpoint("no refresh_token".into()))?
        .to_string();
    let expires_in = body["expires_in"].as_i64().unwrap_or(3600);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    Ok(StoredTokens {
        access_token,
        refresh_token,
        access_expires_at: Some(now + expires_in),
        scope: config.scopes.join(" "),
    })
}
