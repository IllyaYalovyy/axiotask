//! Android build scaffolding checks.
//!
//! Mobile UI behavior is covered by Vitest touch tests. These checks keep the
//! generated Android project and developer entry points in place so those
//! interactions can be validated on a real device.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

fn app_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read_json(path: &Path) -> Value {
    let raw = fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("{} should be readable: {err}", path.display()));
    serde_json::from_str(&raw)
        .unwrap_or_else(|err| panic!("{} should be valid JSON: {err}", path.display()))
}

#[test]
fn android_project_scaffolding_is_checked_in() {
    let root = app_root();

    for rel in [
        "gen/android/build.gradle.kts",
        "gen/android/settings.gradle",
        "gen/android/app/build.gradle.kts",
        "gen/android/app/src/main/AndroidManifest.xml",
        "gen/android/app/src/main/res/mipmap-hdpi/ic_launcher.png",
        "gen/android/app/src/main/res/mipmap-xxhdpi/ic_launcher_round.png",
        "gen/android/app/src/main/res/values/strings.xml",
    ] {
        assert!(
            root.join(rel).is_file(),
            "Android scaffold file `{rel}` should be checked in"
        );
    }
}

#[test]
fn android_build_uses_tauri_mobile_entry_points() {
    let root = app_root();
    let tauri_conf = read_json(&root.join("tauri.conf.json"));
    assert_eq!(
        tauri_conf["build"]["beforeDevCommand"].as_str(),
        Some("npm run dev")
    );
    assert_eq!(
        tauri_conf["build"]["beforeBuildCommand"].as_str(),
        Some("npm run build")
    );

    let package = read_json(&root.join("ui/package.json"));
    let scripts = package["scripts"]
        .as_object()
        .expect("ui/package.json scripts should be an object");

    assert_eq!(
        scripts.get("android:init").and_then(Value::as_str),
        Some("cd .. && cargo tauri android init --skip-targets-install")
    );
    assert_eq!(
        scripts.get("android:dev").and_then(Value::as_str),
        Some("cd .. && cargo tauri android dev")
    );
    assert_eq!(
        scripts.get("android:build").and_then(Value::as_str),
        Some("cd .. && cargo tauri android build")
    );

    let manifest = fs::read_to_string(root.join("gen/android/app/src/main/AndroidManifest.xml"))
        .expect("AndroidManifest.xml should be readable");
    assert!(
        manifest.contains("android.permission.INTERNET"),
        "Android dev builds need network access for the Tauri webview and Google Tasks sync"
    );

    let vite_config = fs::read_to_string(root.join("ui/vite.config.js"))
        .expect("vite.config.js should be readable");
    assert!(
        vite_config.contains("host: process.env.TAURI_DEV_HOST || false"),
        "Vite should listen on TAURI_DEV_HOST so Android devices can reach the dev server"
    );
}

/// The Android `TauriActivity` loads a cdylib named `axiotask_app` and calls its
/// exported `run` mobile entry point. The mobile-only branches below are not
/// compiled on this desktop host, so these string checks keep the wiring from
/// silently regressing — losing any one of them means Android cannot start.
#[test]
fn mobile_entry_point_and_data_dir_wiring_are_in_place() {
    let root = app_root();

    let cargo_toml = fs::read_to_string(root.join("Cargo.toml")).expect("Cargo.toml readable");
    assert!(
        cargo_toml.contains("name = \"axiotask_app\"") && cargo_toml.contains("\"cdylib\""),
        "the app must expose a cdylib named `axiotask_app` for the Android activity to load"
    );

    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).expect("src/lib.rs readable");
    assert!(
        lib_rs.contains("#[cfg_attr(mobile, tauri::mobile_entry_point)]"),
        "`run` must be the mobile entry point so Android has a Rust entry"
    );
    assert!(
        lib_rs.contains("#[cfg(mobile)]") && lib_rs.contains("app_data_dir()"),
        "mobile must resolve its data dir via the Tauri path resolver, not `dirs`"
    );
    assert!(
        lib_rs.contains("#[cfg(desktop)]"),
        "desktop-only startup workarounds (the single-instance lock) must be cfg-gated"
    );
}
