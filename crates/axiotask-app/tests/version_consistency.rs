//! Version consistency checks.
//!
//! axiotask declares its version in three places that MUST stay in sync:
//!   - the workspace `Cargo.toml` (inherited by this crate, surfaced here as
//!     `CARGO_PKG_VERSION`)
//!   - `tauri.conf.json` (the desktop bundle version)
//!   - `ui/package.json` (the version shown in the About dialog)
//!
//! These tests fail if the versions drift apart, keeping the app version a
//! single, meaningful source of truth. Bump all three together — see the
//! "Versioning" section of `CONTRIBUTING.md`.

use std::fs;

use serde_json::Value;

/// The crate version, inherited from `workspace.package.version` in the root
/// `Cargo.toml`. This is the source of truth the other files must match.
const CRATE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Read the `version` field from a JSON file relative to this crate's root.
fn read_json_version(rel_path: &str) -> String {
    let path = format!("{}/{rel_path}", env!("CARGO_MANIFEST_DIR"));
    let raw = fs::read_to_string(&path).expect("version file should be readable");
    let json: Value = serde_json::from_str(&raw).expect("version file should be valid JSON");
    json["version"]
        .as_str()
        .expect("`version` field should be a string")
        .to_string()
}

#[test]
fn version_starts_at_0_1() {
    assert!(
        CRATE_VERSION == "0.1" || CRATE_VERSION.starts_with("0.1."),
        "app version must start at 0.1, got {CRATE_VERSION}"
    );
}

#[test]
fn tauri_conf_version_matches_crate() {
    assert_eq!(
        read_json_version("tauri.conf.json"),
        CRATE_VERSION,
        "tauri.conf.json version must match the workspace Cargo.toml version"
    );
}

#[test]
fn ui_package_version_matches_crate() {
    assert_eq!(
        read_json_version("ui/package.json"),
        CRATE_VERSION,
        "ui/package.json version must match the workspace Cargo.toml version"
    );
}
