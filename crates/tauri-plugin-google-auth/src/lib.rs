//! Tauri plugin: Google sign-in on Android via Play Services
//! `AuthorizationClient` (RFC-010).
//!
//! Exposes two operations to the Rust app through the [`GoogleAuthExt`] trait
//! (and, symmetrically, to the webview as `authorize`/`sign_out` commands):
//!
//! - `authorize(interactive)` — get an access token for the `tasks` scope.
//!   Interactive calls may show Google's account picker + consent; silent calls
//!   never show UI and report `needs_interaction` when they cannot proceed.
//! - `sign_out()` — drop the account association so the next sign-in shows the
//!   picker.
//!
//! Android is the only real target; the desktop implementation is an
//! unsupported stub so the crate stays coherent on every platform.

use tauri::{
    Manager, Runtime,
    plugin::{Builder, TauriPlugin},
};

mod commands;
mod error;
mod models;

pub use error::{Error, Result};
pub use models::{AuthorizeRequest, AuthorizeResponse};

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

#[cfg(desktop)]
use desktop::GoogleAuth;
#[cfg(mobile)]
use mobile::GoogleAuth;

/// Access to the google-auth APIs from any Tauri [`Manager`] (e.g. `AppHandle`).
pub trait GoogleAuthExt<R: Runtime> {
    fn google_auth(&self) -> &GoogleAuth<R>;
}

impl<R: Runtime, T: Manager<R>> GoogleAuthExt<R> for T {
    fn google_auth(&self) -> &GoogleAuth<R> {
        self.state::<GoogleAuth<R>>().inner()
    }
}

/// Initialize the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("google-auth")
        .invoke_handler(tauri::generate_handler![
            commands::authorize,
            commands::sign_out
        ])
        .setup(|app, api| {
            #[cfg(mobile)]
            let google_auth = mobile::init(app, api)?;
            #[cfg(desktop)]
            let google_auth = desktop::init(app, api)?;
            app.manage(google_auth);
            Ok(())
        })
        .build()
}
