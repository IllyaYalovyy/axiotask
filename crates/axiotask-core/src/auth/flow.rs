//! OAuth 2.0 PKCE login flow (desktop).
//!
//! Desktop spawns a loopback HTTP server on an ephemeral port, opens the consent
//! URL in the user's browser, waits for the redirect, and exchanges the code for
//! tokens. The three building blocks — [`build_auth_url`], [`parse_redirect`],
//! and the code exchange — are pure/isolated so they stay unit-testable.
//!
//! Android does NOT use this flow. Google rejects custom-scheme and loopback
//! redirects on Android, so on-device sign-in goes through Play Services'
//! `AuthorizationClient` instead — see `designs/RFC-010-android-auth-play-services.md`
//! and [`super::token_provider`].

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
    /// Default config for Google Tasks (desktop).
    ///
    /// Desktop uses a Google "Desktop app" OAuth client, which carries a client
    /// secret and sends it on the token exchange even under PKCE.
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

/// Build the OAuth 2.0 consent URL. Pure — the desktop loopback flow passes its
/// ephemeral `http://127.0.0.1:<port>` redirect here.
pub fn build_auth_url(
    config: &OAuthConfig,
    redirect_uri: &str,
    challenge: &str,
    method: &str,
    state: &str,
) -> String {
    format!(
        "{}?client_id={}&redirect_uri={}&response_type=code&scope={}&state={}&code_challenge={}&code_challenge_method={}",
        config.auth_url,
        urlencoding::encode(&config.client_id),
        urlencoding::encode(redirect_uri),
        urlencoding::encode(&config.scopes.join(" ")),
        urlencoding::encode(state),
        urlencoding::encode(challenge),
        method,
    )
}

/// Parse the desktop loopback redirect URL, validate the CSRF `state`, and
/// return the authorization `code`.
///
/// The redirect is a loopback URL — `http://127.0.0.1:<port>/?code=…&state=…`.
/// An explicit `?error=…` (the user pressed *Deny*) is [`AuthError::UserDenied`].
/// A returned state that does not match `expected_state` is
/// [`AuthError::StateMismatch`] (possible CSRF or a stale redirect) and the code
/// is rejected even when one is present.
pub fn parse_redirect(redirect_url: &str, expected_state: &str) -> Result<String, AuthError> {
    let parsed = Url::parse(redirect_url).map_err(|e| AuthError::Redirect(e.to_string()))?;

    // An explicit provider error (typically `error=access_denied`) means the
    // user declined consent — surface that rather than a generic "no code".
    if parsed.query_pairs().any(|(k, _)| k == "error") {
        return Err(AuthError::UserDenied);
    }

    let code = parsed
        .query_pairs()
        .find(|(k, _)| k == "code")
        .map(|(_, v)| v.into_owned())
        .ok_or(AuthError::UserDenied)?;

    let returned_state = parsed
        .query_pairs()
        .find(|(k, _)| k == "state")
        .map(|(_, v)| v.into_owned())
        .ok_or(AuthError::StateMismatch)?;

    if returned_state != expected_state {
        return Err(AuthError::StateMismatch);
    }

    Ok(code)
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
    let auth_url = build_auth_url(
        config,
        &redirect_uri,
        &pkce.challenge,
        pkce.method,
        &state_param,
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
    let code = parse_redirect(&full_url, &state_param)?;

    // Send a success response to the browser.
    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h1>Login successful!</h1><p>You can close this tab.</p></body></html>";
    let _ = stream.write_all(response.as_bytes()).await;

    // Exchange code for tokens.
    let tokens = exchange_code(config, &code, &redirect_uri, &pkce.verifier).await?;
    store.save(&tokens)?;
    Ok(tokens)
}

/// Exchange an authorization code for tokens against the desktop "Desktop app"
/// OAuth client, which requires its client secret on the exchange even under
/// PKCE.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::store::InMemoryTokenStore;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, Request, ResponseTemplate};

    const DESKTOP_CLIENT_ID: &str =
        "61486741888-a5alhtbcm86e3e0gd8s9a0j01gn6sum7.apps.googleusercontent.com";

    fn form_fields(req: &Request) -> Vec<(String, String)> {
        url::form_urlencoded::parse(&req.body)
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect()
    }

    // --- redirect parsing (desktop loopback) --------------------------------

    #[test]
    fn parse_redirect_extracts_code_from_desktop_loopback_url() {
        let url = "http://127.0.0.1:54321/?code=desk-code-123&state=st-abc";
        assert_eq!(parse_redirect(url, "st-abc").unwrap(), "desk-code-123");
    }

    #[test]
    fn parse_redirect_rejects_state_mismatch_even_with_a_valid_code() {
        // CSRF guard (invariant: a returned state that isn't ours is rejected
        // regardless of a present code).
        let url = "http://127.0.0.1:54321/?code=attacker-code&state=WRONG";
        assert!(matches!(
            parse_redirect(url, "expected-state"),
            Err(AuthError::StateMismatch)
        ));
    }

    #[test]
    fn parse_redirect_reports_user_denied_on_error_param() {
        let url = "http://127.0.0.1:54321/?error=access_denied&state=st";
        assert!(matches!(parse_redirect(url, "st"), Err(AuthError::UserDenied)));
    }

    #[test]
    fn parse_redirect_reports_user_denied_when_no_code_present() {
        let url = "http://127.0.0.1:54321/?state=st";
        assert!(matches!(parse_redirect(url, "st"), Err(AuthError::UserDenied)));
    }

    // --- consent URL --------------------------------------------------------

    #[test]
    fn build_auth_url_carries_loopback_redirect_pkce_and_state() {
        let config = OAuthConfig::google_tasks(DESKTOP_CLIENT_ID, "secret");
        let url = build_auth_url(
            &config,
            "http://127.0.0.1:54321",
            "the-challenge",
            "S256",
            "the-state",
        );
        // Redirect URI is percent-encoded (the `:` and `/` become %3A / %2F).
        assert!(
            url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321"),
            "loopback redirect not encoded in consent URL: {url}"
        );
        assert!(url.contains("code_challenge=the-challenge"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("state=the-state"));
        assert!(url.contains(&format!(
            "client_id={}",
            urlencoding::encode(DESKTOP_CLIENT_ID)
        )));
    }

    // --- token exchange -----------------------------------------------------

    #[tokio::test]
    async fn desktop_login_exchanges_code_and_sends_the_client_secret() {
        // The full loopback flow's exchange: a "Desktop app" client must send
        // `client_secret` on the code exchange even under PKCE, and the tokens
        // must actually persist to the store.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at-desktop",
                "refresh_token": "rt-desktop",
                "expires_in": 3600,
            })))
            .mount(&server)
            .await;

        let mut config = OAuthConfig::google_tasks("desktop-id", "desktop-secret");
        config.token_url = format!("{}/token", server.uri());
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());

        // Drive the private exchange directly (the loopback server half is not
        // unit-testable without a browser); this is exactly what `login` calls
        // once it has parsed the code from the loopback redirect.
        let tokens = exchange_code(&config, "the-code", "http://127.0.0.1:0", "the-verifier")
            .await
            .expect("exchange should succeed against a live token endpoint");
        store.save(&tokens).unwrap();

        assert_eq!(tokens.access_token, "at-desktop");
        assert_eq!(tokens.refresh_token, "rt-desktop");
        assert!(store.load().unwrap().is_some(), "tokens must be stored");

        let req = &server.received_requests().await.unwrap()[0];
        let fields = form_fields(req);
        assert!(
            fields
                .iter()
                .any(|(k, v)| k == "client_secret" && v == "desktop-secret"),
            "desktop exchange must send client_secret, got: {fields:?}"
        );
        assert!(
            fields
                .iter()
                .any(|(k, v)| k == "code_verifier" && v == "the-verifier")
        );
    }
}
