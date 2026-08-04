//! axiotask app wiring shared by the desktop binary and the mobile entry point.
//!
//! Wires Tauri, the local store, and the sync engine together. `main.rs` is a
//! thin desktop shim over [`run`]; on Android the same [`run`] is the
//! `tauri::mobile_entry_point`, called from the generated `TauriActivity`.

mod commands;
#[cfg(target_os = "android")]
mod play_services_auth;
mod state;

#[cfg(test)]
#[path = "commands_test.rs"]
mod commands_test;

#[cfg(test)]
#[path = "sync_property_test.rs"]
mod sync_property_test;

use std::sync::Arc;

use state::AppState;
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

/// Resolves the SQLite path for this platform.
///
/// Desktop derives the base from `dirs::data_dir()` (the XDG/OS data root).
/// Android has no such root — the only per-app writable location comes from
/// Tauri's path resolver, so mobile roots the same layout at
/// `app.path().app_data_dir()`. Without this the app cannot open its store and
/// never starts.
// Fallible signature kept in parity with the mobile variant, whose path
// resolution can genuinely fail; on desktop it never does.
#[cfg(desktop)]
#[allow(clippy::unnecessary_wraps)]
fn resolve_db_path(_app: &tauri::App) -> Result<std::path::PathBuf, String> {
    Ok(state::default_db_path())
}

#[cfg(mobile)]
fn resolve_db_path(app: &tauri::App) -> Result<std::path::PathBuf, String> {
    let base = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("resolve app data dir: {e}"))?;
    Ok(state::db_path_in(&base))
}

/// Installs the process-global `tracing` subscriber for this platform.
///
/// Desktop keeps the default `fmt` writer (stdout), byte-for-byte what it was
/// before this split. Android discards process stdout, so that same writer would
/// make every on-device log invisible — the first device bug would be
/// undebuggable (#157). There the identical `fmt` subscriber is pointed at
/// logcat through `paranoid_android::AndroidLogMakeWriter`, so
/// `tracing::{info,warn,error}!` calls surface in `adb logcat` under the
/// `axiotask` tag. ANSI is disabled on Android because logcat renders escape
/// codes as literal noise; the env filter (`RUST_LOG`, default `info`) is shared,
/// so log lines read the same on both platforms.
fn init_tracing() {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    #[cfg(target_os = "android")]
    tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_ansi(false)
        .with_writer(paranoid_android::AndroidLogMakeWriter::new(
            "axiotask".to_owned(),
        ))
        .init();

    #[cfg(not(target_os = "android"))]
    tracing_subscriber::fmt().with_env_filter(env_filter).init();
}

/// Shared entry point for both the desktop binary and the Android app.
///
/// Desktop-only startup workarounds (the single-instance advisory-lock guard,
/// which prevents two processes from double-pushing the same dirty rows) are
/// `#[cfg(desktop)]`-gated: Android already guarantees a single process per
/// app, and its data dir is resolved through the Tauri path resolver rather
/// than `dirs`. The Tauri builder itself is identical on both platforms, so the
/// desktop path is byte-for-byte what it was before this split.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
#[allow(clippy::too_many_lines)]
pub fn run() {
    init_tracing();

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
    // it on any kind of exit. Desktop-only: Android runs one process per app
    // and has no shared data root to contend over.
    #[cfg(desktop)]
    {
        let instance_lock = match state::acquire_instance_lock(&state::default_db_path()) {
            Ok(f) => f,
            Err(e) => {
                tracing::error!("{e}");
                eprintln!("axiotask: {e}");
                std::process::exit(1);
            }
        };
        // Hold the fd (and with it the flock) for the process lifetime.
        std::mem::forget(instance_lock);
    }

    // Injected before any page script so the frontend can namespace its
    // localStorage per instance. JSON-encoded so it is always safely quoted.
    let init_script = format!(
        "window.__AXIOTASK_PREFIX__ = {};",
        serde_json::to_string(&instance).unwrap_or_else(|_| "null".into())
    );

    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default();

    // Android sign-in (RFC-010): Google Play Services owns the grant, reached
    // through the in-repo `tauri-plugin-google-auth` plugin. There is no
    // browser, redirect, or deep link. Desktop uses the loopback flow and
    // registers no plugin here, so its builder is byte-identical to before.
    #[cfg(target_os = "android")]
    {
        builder = builder.plugin(tauri_plugin_google_auth::init());
    }

    builder
        .setup(move |app| {
            let db_path = match resolve_db_path(app) {
                Ok(p) => p,
                Err(e) => {
                    show_startup_error(app, &window_title, &e)?;
                    return Ok(());
                }
            };
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
            commands::undo_set_due,
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
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        // Flush pending pushes when the app is quitting. The background sync
        // loop dies with the process and mutations are debounced by 2s, so a
        // change made and then immediately quit would otherwise be stranded in
        // local storage until the next launch. `ExitRequested` fires on every
        // quit path (last window closed, Cmd+Q, tray quit), so this catches
        // them all; we block the exit on a bounded final sync so the push
        // completes before the process goes away. On the startup-error path no
        // state is managed, so `try_state` returns `None` and we just exit.
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event
                && let Some(state) = app_handle.try_state::<Arc<AppState>>()
            {
                let state = state.inner().clone();
                tauri::async_runtime::block_on(state.flush_on_exit());
            }
        });
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
