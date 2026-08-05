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
        lib_rs.contains("#[cfg(mobile)]") && lib_rs.contains("app_config_dir()"),
        "mobile must resolve its config.toml dir via the Tauri path resolver, not \
         `dirs` — otherwise preferences can never save on device (#170)"
    );
    assert!(
        lib_rs.contains("#[cfg(desktop)]"),
        "desktop-only startup workarounds (the single-instance lock) must be cfg-gated"
    );
}

/// Android discards process stdout, so the default `tracing` `fmt` writer makes
/// every log invisible on device — the first device bug would be undebuggable
/// (#157). Logcat wiring lives in the `#[cfg(target_os = "android")]` branch of
/// `init_tracing`, which is not compiled on this desktop host, so a source-string
/// check is the only guard that keeps it from silently regressing. Desktop
/// logging is exercised for real by the e2e smoke launch; here we only assert the
/// mobile branch and its target-gated dependency stay wired.
#[test]
fn android_logs_are_routed_to_logcat() {
    let root = app_root();

    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).expect("src/lib.rs readable");
    assert!(
        lib_rs.contains("#[cfg(target_os = \"android\")]")
            && lib_rs.contains("AndroidLogMakeWriter"),
        "the tracing subscriber must point at logcat via paranoid_android's \
         AndroidLogMakeWriter on Android, or on-device logs vanish (#157)"
    );

    let cargo_toml = fs::read_to_string(root.join("Cargo.toml")).expect("Cargo.toml readable");
    assert!(
        cargo_toml.contains("[target.'cfg(target_os = \"android\")'.dependencies]")
            && cargo_toml.contains("paranoid-android"),
        "the logcat writer must be an Android-only dependency so desktop builds \
         stay unchanged and free of the ndk-sys chain"
    );
}

/// `create_task` emits an `info`-level logcat marker on success. This is the
/// only on-device signal the emulator smoke gate (#161) can observe to prove a
/// quick-add round-tripped through the backend — the webview swallows its own
/// console output, so without this line `mobile-smoke.sh` would be asserting on
/// nothing. Keep it `info` so it survives the default `EnvFilter` on device.
#[test]
fn create_task_emits_a_logcat_marker() {
    let root = app_root();
    let commands = fs::read_to_string(root.join("src/commands.rs")).expect("commands.rs readable");
    assert!(
        commands.contains("create_task: created task"),
        "create_task must log an info marker so the emulator smoke gate can \
         observe a quick-add on device (#161)"
    );
}

/// Release signing (#162). Play/sideload release APKs must be signed with a
/// private upload key, but the keystore and its passwords are secrets that never
/// enter the repo — they live in a gitignored `keystore.properties` (and the
/// `.jks`/`.keystore` file it points at). The Gradle build must (a) load that
/// file when present and sign the `release` build type with it, and (b) fall
/// back cleanly to an unsigned release when it is absent, so debug builds and
/// this keystore-less gate host still configure without throwing. Gradle
/// configuration is not run on this desktop host, so a source-string check is
/// the only guard that keeps the wiring — and the secret-exclusion — from
/// silently regressing.
#[test]
fn android_release_signing_reads_gitignored_keystore_properties() {
    let root = app_root();

    let gradle = fs::read_to_string(root.join("gen/android/app/build.gradle.kts"))
        .expect("app/build.gradle.kts readable");

    // (a) Loads the gitignored secrets file and defines a release signing config
    // from it — store file, store password, key alias, and key password.
    assert!(
        gradle.contains("keystore.properties"),
        "release build must load signing secrets from a gitignored keystore.properties (#162)"
    );
    assert!(
        gradle.contains("signingConfigs") && gradle.contains("create(\"release\")"),
        "app/build.gradle.kts must declare a `release` signingConfig (#162)"
    );
    for key in ["storeFile", "storePassword", "keyAlias", "keyPassword"] {
        assert!(
            gradle.contains(key),
            "the release signingConfig must read `{key}` from keystore.properties (#162)"
        );
    }
    assert!(
        gradle.contains("signingConfig = signingConfigs.getByName(\"release\")"),
        "the release build type must actually apply the release signingConfig (#162)"
    );

    // (b) Falls back gracefully when keystore.properties is absent (the BLOCKED
    // state: no keystore has been generated yet). The signing config must be
    // guarded by an existence check so configuration never throws on a host
    // without the secrets — debug APKs must keep building.
    assert!(
        gradle.contains(".exists()"),
        "release signing must be guarded by a keystore.properties existence check \
         so keystore-less hosts still build (debug APKs suffice) (#162)"
    );

    // The secrets must never be committable: the Android project ignores the
    // properties file, and the repo root ignores the keystore binaries.
    let android_gitignore = fs::read_to_string(root.join("gen/android/.gitignore"))
        .expect("gen/android/.gitignore readable");
    assert!(
        android_gitignore.contains("keystore.properties"),
        "gen/android/.gitignore must exclude keystore.properties so signing secrets never land in the repo (#162)"
    );

    // A committed, secret-free template documents the required keys for the user
    // who will generate the keystore. It must not itself be the ignored name.
    let example = root.join("gen/android/keystore.properties.example");
    assert!(
        example.is_file(),
        "a keystore.properties.example template must be checked in to document the signing keys (#162)"
    );
    let example_body = fs::read_to_string(&example).expect("keystore.properties.example readable");
    for key in ["storeFile", "storePassword", "keyAlias", "keyPassword"] {
        assert!(
            example_body.contains(key),
            "keystore.properties.example must document the `{key}` field (#162)"
        );
    }
}

/// Mobile OAuth (#158). Android has no loopback server, so the PKCE
/// authorization code returns on a custom-scheme deep link
/// (`com.axiotask.app:/oauth2redirect`) instead. Three pieces must stay wired,
/// and none of them is compiled on this desktop host — the intent-filter lives
/// in the checked-in manifest, and the plugin registration + mobile login live
/// in `#[cfg(target_os = "android")]` branches — so source-string checks are the
/// only guard against a silent regression that would make sign-in impossible on
/// device. The redirect PARSING and code exchange are covered for real by unit
/// tests in `axiotask-core::auth::flow`; here we only assert the on-device wiring.
#[test]
fn android_oauth_deep_link_and_intent_filter_are_wired() {
    let root = app_root();

    // (1) The intent-filter routes the custom-scheme redirect back into the app.
    let manifest = fs::read_to_string(root.join("gen/android/app/src/main/AndroidManifest.xml"))
        .expect("AndroidManifest.xml readable");
    assert!(
        manifest.contains("android.intent.action.VIEW"),
        "the OAuth redirect intent-filter needs a VIEW action (#158)"
    );
    assert!(
        manifest.contains("android.intent.category.BROWSABLE"),
        "the OAuth redirect intent-filter must be BROWSABLE so the browser can hand off the redirect (#158)"
    );
    assert!(
        manifest.contains("android:scheme=\"com.axiotask.app\"")
            && manifest.contains("android:path=\"/oauth2redirect\""),
        "the intent-filter must match `com.axiotask.app:/oauth2redirect` exactly (#158)"
    );

    // (2) The deep-link and opener plugins are Android-only dependencies, so
    // desktop builds stay byte-identical and never pull them in.
    let cargo_toml = fs::read_to_string(root.join("Cargo.toml")).expect("Cargo.toml readable");
    assert!(
        cargo_toml.contains("[target.'cfg(target_os = \"android\")'.dependencies]")
            && cargo_toml.contains("tauri-plugin-deep-link")
            && cargo_toml.contains("tauri-plugin-opener"),
        "deep-link + opener must be Android-only deps so desktop is untouched (#158)"
    );

    // (3) Startup registers both plugins and forwards the redirect into the
    // in-flight mobile login via the deep-link bridge.
    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).expect("src/lib.rs readable");
    assert!(
        lib_rs.contains("tauri_plugin_deep_link::init()")
            && lib_rs.contains("tauri_plugin_opener::init()"),
        "both mobile OAuth plugins must be registered on the Android builder (#158)"
    );
    assert!(
        lib_rs.contains("on_open_url") && lib_rs.contains("MobileAuthBridge"),
        "the deep-link handler must deliver the redirect to the MobileAuthBridge (#158)"
    );

    // The mobile login flow and the build-time public client id live in state.rs.
    let state_rs = fs::read_to_string(root.join("src/state.rs")).expect("src/state.rs readable");
    assert!(
        state_rs.contains("start_login_mobile"),
        "the Android login entry point start_login_mobile must exist (#158)"
    );
    assert!(
        state_rs.contains("google_tasks_mobile")
            && state_rs.contains("AXIOTASK_ANDROID_CLIENT_ID")
            && state_rs.contains(
                "61486741888-a5alhtbcm86e3e0gd8s9a0j01gn6sum7.apps.googleusercontent.com"
            ),
        "Android must use the public build-time client id with no secret (#158)"
    );

    // A platform-scoped capability grants the plugins on Android without touching
    // the desktop ACL.
    let cap = read_json(&root.join("capabilities/mobile.json"));
    assert_eq!(
        cap["platforms"].as_array().map(Vec::as_slice),
        Some([Value::String("android".into())].as_slice()),
        "the mobile OAuth capability must be scoped to android only (#158)"
    );
    let perms: Vec<&str> = cap["permissions"]
        .as_array()
        .expect("permissions array")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(
        perms.contains(&"deep-link:default") && perms.contains(&"opener:default"),
        "the mobile capability must grant deep-link + opener (#158), got {perms:?}"
    );
}

/// The opt-in Android emulator smoke gate (#161). It can only run against a live
/// emulator/device with the Android SDK present, so it never runs on this
/// desktop host or in the automatic quality gate. Like the logcat wiring above,
/// a source-string check is the only thing that keeps its essential steps from
/// silently regressing: it must install the DEBUG apk for the real package,
/// launch the real activity, drive a quick-add, and assert BOTH the startup log
/// and the quick-add `create_task` log in `adb logcat`.
#[test]
fn mobile_smoke_gate_is_wired_and_opt_in() {
    let root = app_root();
    let script = root.join("e2e/mobile-smoke.sh");
    assert!(
        script.is_file(),
        "the emulator smoke gate `e2e/mobile-smoke.sh` must be checked in (#161)"
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(&script)
            .expect("mobile-smoke.sh metadata")
            .permissions()
            .mode();
        assert!(
            mode & 0o111 != 0,
            "mobile-smoke.sh must be executable so `./mobile-smoke.sh` runs"
        );
    }

    let sh = fs::read_to_string(&script).expect("mobile-smoke.sh readable");
    for needle in [
        // installs the DEBUG apk for the real package/activity
        "adb",
        "install",
        "com.axiotask.app",
        ".MainActivity",
        "am start",
        "logcat",
        // launch assertion (startup line from init) + quick-add assertion
        "starting default instance",
        "create_task: created task",
    ] {
        assert!(
            sh.contains(needle),
            "mobile-smoke.sh must contain `{needle}` — a missing step means the \
             gate no longer proves launch+quick-add on device (#161)"
        );
    }

    // Opt-in: the desktop e2e runner must never chain into the emulator gate, so
    // the always-on quality gate (which invokes run-smoke.sh) can't drag in a
    // step that needs an emulator.
    let run_smoke = fs::read_to_string(root.join("e2e/run-smoke.sh")).expect("run-smoke.sh");
    assert!(
        !run_smoke.contains("mobile-smoke"),
        "the desktop e2e runner must not invoke the emulator gate — it is opt-in"
    );

    // Discoverable through the same entry-point convention as the other Android
    // developer commands, but distinct from the automatic `test:e2e` gate.
    let package = read_json(&root.join("ui/package.json"));
    let scripts = package["scripts"]
        .as_object()
        .expect("ui/package.json scripts should be an object");
    assert_eq!(
        scripts.get("mobile:smoke").and_then(Value::as_str),
        Some("bash ../e2e/mobile-smoke.sh"),
        "ui/package.json should expose the opt-in emulator gate as `mobile:smoke`"
    );
    assert_eq!(
        scripts.get("test:e2e").and_then(Value::as_str),
        Some("bash ../e2e/run-smoke.sh"),
        "the automatic e2e gate must stay the desktop smoke, not the emulator gate"
    );
}
