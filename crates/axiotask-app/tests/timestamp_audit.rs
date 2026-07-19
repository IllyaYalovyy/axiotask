//! Source audit for issue #47 timestamp regressions.
//!
//! The historical bug was formatting local wall-clock time with a literal
//! trailing `Z`, which labels it as UTC. Production mutation timestamps should
//! go through `axiotask_core::dates::now_utc_string()`; due dates are separate
//! Google Tasks date-only values and are intentionally not audited here.

use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("crate should live under crates/axiotask-app")
        .to_path_buf()
}

fn production_sources(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for rel in [
        "crates/axiotask-core/src",
        "crates/axiotask-app/src",
        "crates/axiotask-app/ui/src",
    ] {
        collect_sources(&root.join(rel), &mut files);
    }
    files.sort();
    files
}

fn collect_sources(dir: &Path, files: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).expect("source directory should be readable") {
        let path = entry.expect("source entry should be readable").path();
        if path.is_dir() {
            if path.file_name().is_some_and(|name| name == "__tests__") {
                continue;
            }
            collect_sources(&path, files);
            continue;
        }
        if matches!(
            path.extension().and_then(|ext| ext.to_str()),
            Some("rs" | "svelte" | "js" | "ts")
        ) {
            files.push(path);
        }
    }
}

#[test]
fn production_sources_do_not_label_local_time_as_utc() {
    let root = repo_root();
    let files = production_sources(&root);
    assert!(!files.is_empty(), "expected production source files");

    let forbidden = [
        "Zoned::now().strftime(\"%Y-%m-%dT",
        "Local::now",
        "chrono::Local",
        "DateTime<Local>",
        ".toISOString()",
    ];

    let mut failures = Vec::new();
    for path in files {
        let raw = fs::read_to_string(&path)
            .unwrap_or_else(|err| panic!("{} should be readable: {err}", path.display()));
        for pattern in forbidden {
            if raw.contains(pattern) {
                failures.push(format!(
                    "{} contains forbidden timestamp pattern `{pattern}`",
                    path.strip_prefix(&root).unwrap_or(&path).display()
                ));
            }
        }
    }

    assert!(
        failures.is_empty(),
        "local-time-labeled-Z audit failed:\n{}",
        failures.join("\n")
    );
}

#[test]
fn app_mutation_layers_use_shared_utc_timestamp_helper() {
    let root = repo_root();
    let mutation_files = [
        root.join("crates/axiotask-app/src/commands.rs"),
        root.join("crates/axiotask-app/src/state.rs"),
    ];

    for path in mutation_files {
        let raw = fs::read_to_string(&path)
            .unwrap_or_else(|err| panic!("{} should be readable: {err}", path.display()));
        assert!(
            raw.contains("now_utc_string"),
            "{} should use the shared UTC timestamp helper",
            path.strip_prefix(&root).unwrap_or(&path).display()
        );
        assert!(
            !raw.contains("Timestamp::now().strftime"),
            "{} should not format timestamps directly",
            path.strip_prefix(&root).unwrap_or(&path).display()
        );
    }
}
