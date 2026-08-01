//! axiotask desktop app entry point.
//!
//! A thin shim over [`axiotask_app::run`], which holds the Tauri wiring shared
//! with the Android `mobile_entry_point`. All startup logic lives in the lib so
//! the two entry points cannot drift.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    axiotask_app::run();
}
