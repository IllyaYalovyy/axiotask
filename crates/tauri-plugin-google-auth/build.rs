//! Tauri plugin build script: generates the ACL permission files for the
//! plugin's commands and wires the Android library project.

const COMMANDS: &[&str] = &["authorize", "sign_out"];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .build();
}
