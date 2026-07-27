//! axiotask desktop app entry point.
//!
//! Wires Tauri, the local store, and the sync engine together.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod state;

#[cfg(test)]
#[path = "commands_test.rs"]
mod commands_test;

#[cfg(test)]
#[path = "sync_property_test.rs"]
mod sync_property_test;

use std::sync::Arc;

use state::{AppState, default_db_path};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

/// Emits a `sync-updated` Tauri event after every sync run so the frontend can
/// reflect background syncs — not just manual "Sync now" — including failures.
struct TauriSyncNotifier {
    app: tauri::AppHandle,
}

impl state::SyncNotifier for TauriSyncNotifier {
    fn notify_sync(&self, status: &state::SyncStatus) {
        use tauri::Emitter;
        let view = commands::SyncStatusView::from(status);
        if let Err(e) = self.app.emit("sync-updated", view) {
            tracing::warn!("failed to emit sync-updated event: {e}");
        }
    }
}

/// Builds the initialization script that hands a fatal startup error to the
/// frontend. Injected before any page script runs, so `main.js` can render it
/// (`window.__STARTUP_ERROR__`) instead of loading a dead app. The message is
/// JSON-encoded, so quotes/newlines/markup in a `StoreError` are always safely
/// quoted rather than breaking the script.
fn startup_error_script(message: &str) -> String {
    format!(
        "window.__STARTUP_ERROR__ = {};",
        serde_json::to_string(message).unwrap_or_else(|_| "\"axiotask could not start\"".into())
    )
}

/// Surfaces a fatal startup failure (store `WipeAborted`, or any `open()`
/// error) in a minimal window instead of vanishing. A release build has no
/// console and `windows_subsystem = "windows"` swallows a panic, so this is the
/// only way the user learns why the app refused to start. No state is managed
/// and no sync is wired: this window is the whole app until it is closed, and
/// the process then exits.
fn show_startup_error(
    app: &tauri::App,
    window_title: &str,
    message: &str,
) -> tauri::Result<tauri::WebviewWindow> {
    tracing::error!("app failed to start: {message}");
    WebviewWindowBuilder::new(app, "startup-error", WebviewUrl::default())
        .title(format!("{window_title} — startup error"))
        .inner_size(560.0, 380.0)
        .resizable(true)
        .initialization_script(startup_error_script(message))
        .build()
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    // Resolve the instance once, up front. This validates AXIOTASK_PREFIX (it
    // panics here with a clear message if malformed, before any data dir is
    // touched) and lets us label the window and the frontend storage.
    let instance = axiotask_core::config::instance_prefix();
    if let Some(p) = &instance {
        tracing::info!("starting isolated instance '{p}' (axiotask-{p})");
    } else {
        tracing::info!("starting default instance");
    }
    let window_title = match &instance {
        Some(p) => format!("axiotask ({p})"),
        None => "axiotask".to_string(),
    };

    // Single-instance guard (#48): refuse to start on a data directory another
    // process already owns — two processes would double-push the same dirty
    // rows and duplicate tasks on Google. Must happen before anything opens
    // the database. The lock lives as long as the process; the kernel releases
    // it on any kind of exit.
    let instance_lock = match state::acquire_instance_lock(&default_db_path()) {
        Ok(f) => f,
        Err(e) => {
            tracing::error!("{e}");
            eprintln!("axiotask: {e}");
            std::process::exit(1);
        }
    };
    // Hold the fd (and with it the flock) for the process lifetime.
    std::mem::forget(instance_lock);
    // Injected before any page script so the frontend can namespace its
    // localStorage per instance. JSON-encoded so it is always safely quoted.
    let init_script = format!(
        "window.__AXIOTASK_PREFIX__ = {};",
        serde_json::to_string(&instance).unwrap_or_else(|_| "null".into())
    );

    tauri::Builder::default()
        .setup(move |app| {
            let db_path = default_db_path();
            if let Some(parent) = db_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }

            // Block on state init — this runs before the window loads content.
            let app_state = match tauri::async_runtime::block_on(AppState::new(&db_path)) {
                Ok(s) => s,
                Err(e) => {
                    show_startup_error(app, &window_title, &e)?;
                    return Ok(());
                }
            };
            let state = Arc::new(app_state);
            app.manage(state.clone());

            // Wire the Tauri event emitter so background syncs surface in the UI.
            state.set_sync_notifier(Arc::new(TauriSyncNotifier {
                app: app.handle().clone(),
            }));

            // Build the main window in code (rather than tauri.conf.json) so the
            // title reflects the instance and the prefix is injected before the
            // frontend runs.
            WebviewWindowBuilder::new(app, "main", WebviewUrl::default())
                .title(&window_title)
                .inner_size(1000.0, 700.0)
                .resizable(true)
                .initialization_script(&init_script)
                .build()?;

            // Auto-sync once on startup if authenticated and enabled in config
            let sync_state = state.clone();
            tauri::async_runtime::spawn(async move {
                if sync_state.is_authenticated() && sync_state.auto_sync_on_start() {
                    tracing::info!("auto-sync on startup...");
                    if let Err(e) = sync_state.run_sync_if_authed().await {
                        tracing::warn!("startup sync failed: {e}");
                    }
                }
            });

            // Background sync loop: debounced on mutation + periodic.
            let loop_state = state.clone();
            tauri::async_runtime::spawn(async move {
                loop_state.run_sync_loop().await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_tasklists,
            commands::create_list,
            commands::rename_list,
            commands::delete_list,
            commands::list_tasks,
            commands::create_task,
            commands::rename_task,
            commands::toggle_complete,
            commands::delete_task,
            commands::undo_delete,
            commands::set_due,
            commands::set_notes,
            commands::move_task,
            commands::move_to_list,
            commands::reorder_task,
            commands::clear_completed,
            commands::sync_now,
            commands::fresh_sync,
            commands::auth_status,
            commands::auth_login,
            commands::auth_logout,
            commands::open_url,
            commands::export_backup,
            commands::import_backup,
            commands::get_settings,
            commands::set_push_enabled,
            commands::set_editing,
            commands::set_auto_sync,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::startup_error_script;

    /// The user must see the actual failure reason. A real WipeAborted message
    /// (quotes, parentheses, a full sentence) must survive into the injected
    /// global verbatim after JSON decoding — not be truncated or mangled.
    #[test]
    fn startup_error_script_carries_the_message_verbatim() {
        let message = "Refusing to reset the local store after a schema change: it holds \
             local-only or unsynced changes (\"dirty\") not yet saved to Google. Your data \
             has been left untouched.";
        let script = startup_error_script(message);

        let json = script
            .strip_prefix("window.__STARTUP_ERROR__ = ")
            .and_then(|s| s.strip_suffix(';'))
            .expect("script shape: window.__STARTUP_ERROR__ = <json>;");
        let decoded: String = serde_json::from_str(json).expect("value must be valid JSON");
        assert_eq!(decoded, message);
    }

    /// The script is injected via the webview's script API (not spliced into an
    /// HTML `<script>` tag), so the risk is a JS *syntax* break: a raw quote or
    /// newline in the message would terminate the string literal early and
    /// leave the app with no error at all. Those must be escaped and the message
    /// must round-trip intact.
    #[test]
    fn startup_error_script_escapes_js_string_breakers() {
        let message = "open db: \"boom\" happened\non line two";
        let script = startup_error_script(message);

        assert!(
            !script.contains('\n'),
            "a raw newline would break the JS statement: {script}"
        );
        let json = script
            .strip_prefix("window.__STARTUP_ERROR__ = ")
            .and_then(|s| s.strip_suffix(';'))
            .expect("script shape");
        let decoded: String = serde_json::from_str(json).expect("valid JSON");
        assert_eq!(decoded, message, "message must round-trip intact");
    }
}
