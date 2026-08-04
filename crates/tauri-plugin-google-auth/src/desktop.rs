use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::{AuthorizeRequest, AuthorizeResponse};

/// Desktop is not a target for this plugin: desktop sign-in uses loopback PKCE
/// (RFC-001), not Play Services. This stub exists so the crate is coherent on
/// every platform; its methods always report unsupported.
pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<GoogleAuth<R>> {
    Ok(GoogleAuth(app.clone()))
}

pub struct GoogleAuth<R: Runtime>(#[allow(dead_code)] AppHandle<R>);

impl<R: Runtime> GoogleAuth<R> {
    pub fn authorize(&self, _payload: AuthorizeRequest) -> crate::Result<AuthorizeResponse> {
        Err(crate::Error::Message(
            "Play Services sign-in is Android-only".into(),
        ))
    }

    pub fn sign_out(&self) -> crate::Result<()> {
        Err(crate::Error::Message(
            "Play Services sign-in is Android-only".into(),
        ))
    }
}
