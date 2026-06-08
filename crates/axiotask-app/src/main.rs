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
use tauri::Manager;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tauri::Builder::default()
        .setup(|app| {
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

            // Auto-sync once on startup if authenticated
            let sync_state = state.clone();
            tauri::async_runtime::spawn(async move {
                if sync_state.is_authenticated() {
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
