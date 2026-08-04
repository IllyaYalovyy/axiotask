//! Android-only bridge from the [`MobileTokenProvider`] seam to the in-repo
//! `tauri-plugin-google-auth` plugin (RFC-010).
//!
//! The plugin wraps Play Services' `AuthorizationClient`; this adapter turns its
//! sync, `AppHandle`-scoped calls into the async trait the rest of the app talks
//! to. Compiled ONLY for Android — Play Services exists nowhere else — so nothing
//! here is built on the desktop host or exercised by the desktop quality gate;
//! the device merge gate (G5) is what proves it against the real endpoint.

use async_trait::async_trait;
use tauri::AppHandle;

use axiotask_core::auth::{MobileTokenProvider, TokenProviderError};
use tauri_plugin_google_auth::{AuthorizeRequest, GoogleAuthExt};

/// A [`MobileTokenProvider`] backed by Play Services through the plugin.
pub struct PlayServicesTokenProvider {
    app: AppHandle,
}

impl PlayServicesTokenProvider {
    pub fn new(app: AppHandle) -> Self {
        Self { app }
    }
}

#[async_trait]
impl MobileTokenProvider for PlayServicesTokenProvider {
    async fn authorize(&self, interactive: bool) -> Result<String, TokenProviderError> {
        let app = self.app.clone();
        // The plugin call may block awaiting the account-picker `PendingIntent`
        // result (interactive) or a GMS round-trip (silent); keep it off the
        // async worker.
        let res = tauri::async_runtime::spawn_blocking(move || {
            app.google_auth()
                .authorize(AuthorizeRequest { interactive })
        })
        .await
        .map_err(|e| TokenProviderError::Unavailable(format!("join: {e}")))?;

        match res {
            Ok(resp) if resp.needs_interaction => Err(TokenProviderError::InteractionRequired),
            Ok(resp) => resp
                .access_token
                .ok_or_else(|| TokenProviderError::Unavailable("empty authorize response".into())),
            Err(e) => Err(TokenProviderError::Unavailable(e.to_string())),
        }
    }

    async fn sign_out(&self) -> Result<(), TokenProviderError> {
        let app = self.app.clone();
        tauri::async_runtime::spawn_blocking(move || app.google_auth().sign_out())
            .await
            .map_err(|e| TokenProviderError::Unavailable(format!("join: {e}")))?
            .map_err(|e| TokenProviderError::Unavailable(e.to_string()))
    }
}
