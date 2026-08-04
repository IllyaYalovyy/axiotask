use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

use crate::models::{AuthorizeRequest, AuthorizeResponse};

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "com.axiotask.plugin.googleauth";

/// Register the Android plugin and return the handle used to call into Kotlin.
pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<GoogleAuth<R>> {
    #[cfg(target_os = "android")]
    let handle = api.register_android_plugin(PLUGIN_IDENTIFIER, "GoogleAuthPlugin")?;
    #[cfg(not(target_os = "android"))]
    let handle = {
        // iOS is a non-goal (RFC-010 NG1). This keeps the mobile module coherent
        // if it is ever compiled for a non-Android mobile target.
        let _ = api;
        return Err(crate::Error::Message(
            "google-auth is only implemented on Android".into(),
        ));
    };
    Ok(GoogleAuth(handle))
}

/// Handle to the Kotlin plugin over Play Services `AuthorizationClient`.
pub struct GoogleAuth<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> GoogleAuth<R> {
    /// Acquire an access token for the `tasks` scope. See [`AuthorizeRequest`].
    pub fn authorize(&self, payload: AuthorizeRequest) -> crate::Result<AuthorizeResponse> {
        self.0
            .run_mobile_plugin("authorize", payload)
            .map_err(Into::into)
    }

    /// Drop the account association so the next sign-in shows the picker.
    pub fn sign_out(&self) -> crate::Result<()> {
        self.0.run_mobile_plugin("signOut", ()).map_err(Into::into)
    }
}
