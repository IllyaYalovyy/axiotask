//! axiotask desktop app entry point.
//!
//! Wires Tauri, the local store, and the sync engine together.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod state;

#[cfg(test)]
#[path = "commands_test.rs"]
mod commands_test;

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

            // Block on state init — this runs before the window loads content
            let app_state = tauri::async_runtime::block_on(async {
                AppState::new(&db_path)
                    .await
                    .expect("failed to initialize app state")
            });
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
