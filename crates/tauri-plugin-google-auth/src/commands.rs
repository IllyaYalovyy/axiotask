use tauri::{AppHandle, Runtime};

use crate::models::{AuthorizeRequest, AuthorizeResponse};
use crate::GoogleAuthExt;

#[tauri::command]
pub(crate) async fn authorize<R: Runtime>(
    app: AppHandle<R>,
    payload: AuthorizeRequest,
) -> crate::Result<AuthorizeResponse> {
    app.google_auth().authorize(payload)
}

#[tauri::command]
pub(crate) async fn sign_out<R: Runtime>(app: AppHandle<R>) -> crate::Result<()> {
    app.google_auth().sign_out()
}
