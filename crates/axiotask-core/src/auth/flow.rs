//! OAuth 2.0 PKCE login flow.
//!
//! Two redirect strategies share one code path:
//!
//! - **Desktop** spawns a loopback HTTP server on an ephemeral port, opens the
//!   consent URL in the user's browser, waits for the redirect, and exchanges
//!   the code for tokens.
//! - **Mobile** has no loopback server. It opens consent in the system browser
//!   and receives the code through a custom-scheme redirect
//!   ([`MOBILE_REDIRECT_URI`]) that the OS routes back into the app via a
//!   registered intent-filter (deep link). The app then calls
//!   [`complete_mobile_login`] with the delivered URL.
//!
//! The three pure building blocks — [`build_auth_url`], [`parse_redirect`], and
//! the code exchange — are shared, so the desktop and mobile flows request and
//! parse tokens identically; only how the redirect is delivered differs.

use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use url::Url;

use super::error::AuthError;
use super::pkce::{Pkce, random_state};
use super::store::{StoredTokens, TokenStore};

/// Custom-scheme redirect URI for the Android app.
///
/// Google returns the authorization code to this URI; Android routes it back
/// into the app through the `com.axiotask.app` intent-filter declared in the
/// manifest. There is no loopback server on mobile, so this custom scheme is
/// how the code re-enters the process.
pub const MOBILE_REDIRECT_URI: &str = "com.axiotask.app:/oauth2redirect";

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

    /// Config for the Android app: a **public** client id with **no secret**.
    ///
    /// Mobile OAuth clients are public — a secret embedded in the APK can't be
    /// kept secret — so Google's Android client type has none, and the token
    /// exchange must NOT send a `client_secret`. PKCE alone protects the code
    /// exchange. An empty `client_secret` here makes the exchange omit the field
    /// entirely (see [`exchange_code`]).
    pub fn google_tasks_mobile(client_id: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: String::new(),
            scopes: vec!["https://www.googleapis.com/auth/tasks".into()],
            auth_url: "https://accounts.google.com/o/oauth2/v2/auth".into(),
            token_url: "https://oauth2.googleapis.com/token".into(),
        }
    }
}

/// Build the OAuth 2.0 consent URL. Pure — the same builder serves the desktop
/// loopback redirect and the mobile custom-scheme redirect; only `redirect_uri`
/// differs between them.
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

/// Parse an OAuth redirect URL, validate the CSRF `state`, and return the
/// authorization `code`.
///
/// Handles both redirect shapes with the same code path, because `url::Url`
/// parses either:
/// - desktop loopback — `http://127.0.0.1:<port>/?code=…&state=…`
/// - mobile custom scheme — `com.axiotask.app:/oauth2redirect?code=…&state=…`
///
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

/// Complete a mobile PKCE login from the redirect URL the OS delivered via the
/// deep link.
///
/// The caller (the app's deep-link handler) opens the consent URL — see
/// [`build_auth_url`] with [`MOBILE_REDIRECT_URI`] — and hands the resulting
/// redirect URL here. This validates the CSRF `state`, exchanges the code for
/// tokens (no client secret — see [`OAuthConfig::google_tasks_mobile`]), and
/// persists them. On any failure NOTHING is stored, so a denied or tampered
/// redirect leaves the app cleanly signed out rather than half-authenticated.
pub async fn complete_mobile_login(
    config: &OAuthConfig,
    store: &Arc<dyn TokenStore>,
    redirect_url: &str,
    expected_state: &str,
    verifier: &str,
) -> Result<StoredTokens, AuthError> {
    let code = parse_redirect(redirect_url, expected_state)?;
    let tokens = exchange_code(config, &code, MOBILE_REDIRECT_URI, verifier).await?;
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
    // Desktop's "Desktop app" client requires the secret even under PKCE; the
    // Android client is public and has none. Send `client_secret` only when we
    // actually hold one, so the mobile exchange stays secret-free while the
    // desktop request is byte-for-byte what it always sent. Field order matches
    // the historical desktop form so the desktop wire is unchanged.
    let mut form: Vec<(&str, &str)> = vec![("client_id", config.client_id.as_str())];
    if !config.client_secret.is_empty() {
        form.push(("client_secret", config.client_secret.as_str()));
    }
    form.push(("code", code));
    form.push(("code_verifier", verifier));
    form.push(("grant_type", "authorization_code"));
    form.push(("redirect_uri", redirect_uri));

    let resp = client
        .post(&config.token_url)
        .form(&form)
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

    const MOBILE_CLIENT_ID: &str =
        "61486741888-a5alhtbcm86e3e0gd8s9a0j01gn6sum7.apps.googleusercontent.com";

    fn form_fields(req: &Request) -> Vec<(String, String)> {
        url::form_urlencoded::parse(&req.body)
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect()
    }

    // --- redirect parsing ---------------------------------------------------

    #[test]
    fn parse_redirect_extracts_code_from_desktop_loopback_url() {
        let url = "http://127.0.0.1:54321/?code=desk-code-123&state=st-abc";
        assert_eq!(parse_redirect(url, "st-abc").unwrap(), "desk-code-123");
    }

    #[test]
    fn parse_redirect_extracts_code_from_mobile_custom_scheme_url() {
        // The whole point of mobile OAuth: the code arrives on a custom-scheme
        // deep link, not a loopback URL. `url::Url` must parse it and yield the
        // same code the desktop path would.
        let url = "com.axiotask.app:/oauth2redirect?code=mob-code-xyz&state=st-mob";
        assert_eq!(parse_redirect(url, "st-mob").unwrap(), "mob-code-xyz");
    }

    #[test]
    fn parse_redirect_rejects_state_mismatch_even_with_a_valid_code() {
        // CSRF guard (invariant: a returned state that isn't ours is rejected
        // regardless of a present code).
        let url = "com.axiotask.app:/oauth2redirect?code=attacker-code&state=WRONG";
        assert!(matches!(
            parse_redirect(url, "expected-state"),
            Err(AuthError::StateMismatch)
        ));
    }

    #[test]
    fn parse_redirect_reports_user_denied_on_error_param() {
        let url = "com.axiotask.app:/oauth2redirect?error=access_denied&state=st";
        assert!(matches!(
            parse_redirect(url, "st"),
            Err(AuthError::UserDenied)
        ));
    }

    #[test]
    fn parse_redirect_reports_user_denied_when_no_code_present() {
        let url = "com.axiotask.app:/oauth2redirect?state=st";
        assert!(matches!(
            parse_redirect(url, "st"),
            Err(AuthError::UserDenied)
        ));
    }

    // --- consent URL --------------------------------------------------------

    #[test]
    fn build_auth_url_carries_mobile_redirect_pkce_and_state() {
        let config = OAuthConfig::google_tasks_mobile(MOBILE_CLIENT_ID);
        let url = build_auth_url(
            &config,
            MOBILE_REDIRECT_URI,
            "the-challenge",
            "S256",
            "the-state",
        );
        // Redirect URI is percent-encoded (the `:` and `/` become %3A / %2F).
        assert!(
            url.contains("redirect_uri=com.axiotask.app%3A%2Foauth2redirect"),
            "mobile redirect not encoded in consent URL: {url}"
        );
        assert!(url.contains("code_challenge=the-challenge"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("state=the-state"));
        assert!(url.contains(&format!(
            "client_id={}",
            urlencoding::encode(MOBILE_CLIENT_ID)
        )));
    }

    #[test]
    fn google_tasks_mobile_has_public_id_and_no_secret() {
        let config = OAuthConfig::google_tasks_mobile(MOBILE_CLIENT_ID);
        assert_eq!(config.client_id, MOBILE_CLIENT_ID);
        assert!(
            config.client_secret.is_empty(),
            "mobile OAuth client must carry NO secret (invariant #6 / public client)"
        );
        assert_eq!(config.scopes, vec!["https://www.googleapis.com/auth/tasks"]);
    }

    // --- token exchange -----------------------------------------------------

    #[tokio::test]
    async fn mobile_login_exchanges_code_without_a_client_secret() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at-mobile",
                "refresh_token": "rt-mobile",
                "expires_in": 3600,
            })))
            .mount(&server)
            .await;

        let mut config = OAuthConfig::google_tasks_mobile(MOBILE_CLIENT_ID);
        config.token_url = format!("{}/token", server.uri());
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());

        let tokens = complete_mobile_login(
            &config,
            &store,
            "com.axiotask.app:/oauth2redirect?code=mob-code&state=st",
            "st",
            "the-verifier",
        )
        .await
        .expect("mobile login should succeed against a live token endpoint");

        assert_eq!(tokens.access_token, "at-mobile");
        // Signed-in: tokens are actually persisted (not just returned).
        assert!(store.load().unwrap().is_some(), "tokens must be stored");

        // The exchange request must NOT carry a client secret — a public mobile
        // client has none, and sending an empty one would be rejected by Google.
        let req = &server.received_requests().await.unwrap()[0];
        let fields = form_fields(req);
        assert!(
            !fields.iter().any(|(k, _)| k == "client_secret"),
            "mobile token exchange must omit client_secret, got fields: {fields:?}"
        );
        assert!(
            fields
                .iter()
                .any(|(k, v)| k == "code_verifier" && v == "the-verifier")
        );
        assert!(
            fields
                .iter()
                .any(|(k, v)| k == "redirect_uri" && v == MOBILE_REDIRECT_URI),
            "exchange must echo the custom-scheme redirect_uri"
        );
    }

    #[tokio::test]
    async fn desktop_exchange_still_sends_the_client_secret() {
        // Byte-identical desktop wire: a config carrying a secret must still put
        // `client_secret` on the token request.
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at",
                "refresh_token": "rt",
                "expires_in": 3600,
            })))
            .mount(&server)
            .await;

        let mut config = OAuthConfig::google_tasks("desktop-id", "desktop-secret");
        config.token_url = format!("{}/token", server.uri());
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());

        // Reuse the shared completion helper as a driver for the exchange.
        complete_mobile_login(
            &config,
            &store,
            "http://127.0.0.1:0/?code=c&state=s",
            "s",
            "v",
        )
        .await
        .unwrap();

        let req = &server.received_requests().await.unwrap()[0];
        let fields = form_fields(req);
        assert!(
            fields
                .iter()
                .any(|(k, v)| k == "client_secret" && v == "desktop-secret"),
            "desktop exchange must send client_secret, got: {fields:?}"
        );
    }

    #[tokio::test]
    async fn failed_mobile_login_stores_nothing() {
        // Non-happy path + invariant #6: a tampered/denied redirect must leave
        // the app cleanly signed OUT — no half-written tokens — so a failed sign
        // in never masquerades as signed-in and never hides local data.
        let store: Arc<dyn TokenStore> = Arc::new(InMemoryTokenStore::new());
        let config = OAuthConfig::google_tasks_mobile(MOBILE_CLIENT_ID);

        let err = complete_mobile_login(
            &config,
            &store,
            "com.axiotask.app:/oauth2redirect?code=c&state=TAMPERED",
            "expected",
            "v",
        )
        .await
        .unwrap_err();

        assert!(matches!(err, AuthError::StateMismatch));
        assert!(
            store.load().unwrap().is_none(),
            "a failed login must not persist tokens"
        );
    }
}
