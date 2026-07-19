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
