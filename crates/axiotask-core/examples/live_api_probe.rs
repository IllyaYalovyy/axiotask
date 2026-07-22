//! One-off contract probe against the REAL Google Tasks API (issue #94).
//!
//! This is NOT part of the automated test run — `cargo test` compiles it (so it
//! can't bit-rot) but never executes it, because it needs live credentials. Run
//! it by hand with the throwaway dev account whenever you need to re-verify that
//! `in_memory.rs` still mirrors reality (e.g. Google changed a behavior):
//!
//! ```text
//! cargo run -p axiotask-core --example live_api_probe
//! ```
//!
//! Credentials come from the dev instance (never the production account — see
//! the isolate-from-production-data rule):
//! - client id/secret: `~/.config/axiotask-dev/config.toml` (`[google]`)
//! - tokens:           `~/.local/share/axiotask-dev/tokens.json` (`StoredTokens`)
//!
//! Override either path with `AXIOTASK_DEV_CONFIG` / `AXIOTASK_DEV_TOKENS`.
//!
//! The probe creates ONE scratch task list, exercises every assumption the fake
//! encodes, prints PASS/FAIL per assertion, and deletes the scratch list on the
//! way out (even on panic-free early error). It exits non-zero if any assertion
//! failed, so it doubles as a manual regression gate.
//!
//! Assumptions probed (kept in lockstep with `in_memory.rs`):
//! - `due`: bare `YYYY-MM-DD` is a permanent 400; a full RFC-3339 timestamp is
//!   accepted and normalized to `...T00:00:00.000Z`; `""` clears it.
//! - stale `If-Match` → 412 PreconditionFailed.
//! - inserting under an unknown `parent` → permanent 400.
//! - deleting a parent deletes its descendants server-side.
//! - the API accepts nesting deeper than one level (our app self-limits to one).
//! - completing a parent auto-completes its subtree; re-opening a child of a
//!   still-completed parent is accepted (200) but silently ignored; re-opening
//!   the parent does NOT reopen children.
//! - moving an unknown task id → permanent 400 ("Invalid task ID"), not 404.

use std::path::PathBuf;
use std::sync::Arc;

use axiotask_core::api::{ApiError, GoogleTasksClient, HttpClient};
use axiotask_core::auth::{
    AuthedClient, OAuthConfig, RefreshError, RefreshFn, StoredTokens, TokenStore,
};
use axiotask_core::config::AppConfig;
use axiotask_core::model::{NewTask, TaskPatch, TaskStatus};

/// Minimal token store that persists refreshes back to the dev tokens file so a
/// rotated access token survives the run.
struct FileTokenStore {
    path: PathBuf,
}

impl TokenStore for FileTokenStore {
    fn load(&self) -> Result<Option<StoredTokens>, axiotask_core::auth::AuthError> {
        match std::fs::read_to_string(&self.path) {
            Ok(s) => Ok(Some(serde_json::from_str(&s).map_err(|e| {
                axiotask_core::auth::AuthError::Format(e.to_string())
            })?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(axiotask_core::auth::AuthError::Keyring(e.to_string())),
        }
    }

    fn save(&self, tokens: &StoredTokens) -> Result<(), axiotask_core::auth::AuthError> {
        let json = serde_json::to_string_pretty(tokens)
            .map_err(|e| axiotask_core::auth::AuthError::Format(e.to_string()))?;
        std::fs::write(&self.path, json)
            .map_err(|e| axiotask_core::auth::AuthError::Keyring(e.to_string()))
    }

    fn clear(&self) -> Result<(), axiotask_core::auth::AuthError> {
        Ok(())
    }
}

/// Tallies assertions so the run can report a summary and exit code.
#[derive(Default)]
struct Report {
    passed: u32,
    failed: u32,
}

impl Report {
    fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        if ok {
            self.passed += 1;
            println!("  PASS  {name}");
        } else {
            self.failed += 1;
            println!("  FAIL  {name} — {detail}");
        }
    }
}

fn dev_path(env_var: &str, rel: &str) -> PathBuf {
    if let Ok(p) = std::env::var(env_var) {
        return PathBuf::from(p);
    }
    let home = dirs::home_dir().expect("no home directory");
    home.join(rel)
}

fn build_client() -> HttpClient {
    let config_path = dev_path("AXIOTASK_DEV_CONFIG", ".config/axiotask-dev/config.toml");
    let tokens_path = dev_path(
        "AXIOTASK_DEV_TOKENS",
        ".local/share/axiotask-dev/tokens.json",
    );

    let cfg = AppConfig::load_from(&config_path).unwrap_or_else(|| {
        panic!(
            "could not read dev config at {} — set AXIOTASK_DEV_CONFIG",
            config_path.display()
        )
    });
    assert!(
        !cfg.google.client_id.is_empty() && !cfg.google.client_secret.is_empty(),
        "dev config is missing google.client_id/client_secret"
    );

    let store: Arc<dyn TokenStore> = Arc::new(FileTokenStore {
        path: tokens_path.clone(),
    });
    let tokens = store
        .load()
        .expect("failed to read tokens")
        .unwrap_or_else(|| {
            panic!(
                "no tokens at {} — sign the dev account in first",
                tokens_path.display()
            )
        });

    let oauth = OAuthConfig::google_tasks(&cfg.google.client_id, &cfg.google.client_secret);
    let token_url = oauth.token_url.clone();
    let client_id = oauth.client_id.clone();
    let client_secret = oauth.client_secret.clone();
    let refresh: RefreshFn = Arc::new(move |refresh_token: String| {
        let token_url = token_url.clone();
        let client_id = client_id.clone();
        let client_secret = client_secret.clone();
        Box::pin(async move {
            let client = reqwest::Client::new();
            let resp = client
                .post(&token_url)
                .form(&[
                    ("client_id", client_id.as_str()),
                    ("client_secret", client_secret.as_str()),
                    ("refresh_token", refresh_token.as_str()),
                    ("grant_type", "refresh_token"),
                ])
                .send()
                .await
                .map_err(|e| RefreshError::Transient(e.to_string()))?;
            let status = resp.status().as_u16();
            let body = resp
                .text()
                .await
                .map_err(|e| RefreshError::Transient(e.to_string()))?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            axiotask_core::auth::parse_refresh_response(
                status,
                &body,
                refresh_token,
                "https://www.googleapis.com/auth/tasks",
                now,
            )
        })
    });

    let authed = AuthedClient::new(reqwest::Client::new(), tokens, store, refresh);
    HttpClient::new(authed)
}

/// A permanent (non-transient) 400 from the API.
fn is_bad_request(err: &ApiError) -> bool {
    !err.is_transient() && !matches!(err, ApiError::PreconditionFailed | ApiError::NotFound)
}

#[tokio::main]
async fn main() {
    let client = build_client();
    let list = client
        .insert_tasklist(&format!(
            "axiotask-probe-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        ))
        .await
        .expect("failed to create scratch list");
    let lid = list.id.clone();
    println!("scratch list: {lid}");

    let mut r = Report::default();
    // Each probe records pass/fail rather than panicking on an unexpected API
    // outcome, so cleanup below always runs.
    run_probes(&client, &lid, &mut r).await;

    // Cleanup: delete the scratch list (cascades its tasks server-side).
    match client.delete_tasklist(&lid).await {
        Ok(()) => println!("deleted scratch list {lid}"),
        Err(e) => println!("WARNING: failed to delete scratch list {lid}: {e:?}"),
    }

    println!("\n{} passed, {} failed", r.passed, r.failed);
    if r.failed > 0 {
        std::process::exit(1);
    }
}

async fn run_probes(client: &HttpClient, lid: &str, r: &mut Report) {
    probe_dates_and_conflict(client, lid, r).await;
    probe_hierarchy_and_completion(client, lid, r).await;
}

async fn probe_dates_and_conflict(client: &HttpClient, lid: &str, r: &mut Report) {
    // --- date format ------------------------------------------------------
    let bare = client
        .insert_task(
            lid,
            NewTask {
                title: "bare-date".into(),
                due: Some("2026-08-01".into()),
                ..Default::default()
            },
        )
        .await;
    r.check(
        "bare YYYY-MM-DD due is a permanent 400",
        matches!(&bare, Err(e) if is_bad_request(e)),
        format!("{bare:?}"),
    );

    let rfc = client
        .insert_task(
            lid,
            NewTask {
                title: "rfc-date".into(),
                due: Some("2026-08-01T00:00:00.000Z".into()),
                ..Default::default()
            },
        )
        .await
        .expect("RFC-3339 due should be accepted");
    r.check(
        "RFC-3339 due normalized to T00:00:00.000Z",
        rfc.due.as_deref() == Some("2026-08-01T00:00:00.000Z"),
        format!("due = {:?}", rfc.due),
    );

    let cleared = client
        .patch_task(
            lid,
            &rfc.id,
            TaskPatch {
                due: Some(String::new()),
                ..Default::default()
            },
            None,
        )
        .await
        .expect("clearing due should succeed");
    r.check(
        "empty-string due clears the date",
        cleared.due.is_none(),
        format!("due = {:?}", cleared.due),
    );

    // --- stale If-Match / 412 --------------------------------------------
    let conflict = client
        .patch_task(
            lid,
            &rfc.id,
            TaskPatch {
                title: Some("nope".into()),
                ..Default::default()
            },
            Some("definitely-stale-etag"),
        )
        .await;
    r.check(
        "stale If-Match returns 412 PreconditionFailed",
        matches!(conflict, Err(ApiError::PreconditionFailed)),
        format!("{conflict:?}"),
    );

    // --- unknown parent ---------------------------------------------------
    let orphan = client
        .insert_task(
            lid,
            NewTask {
                title: "orphan".into(),
                parent: Some("no-such-parent-id".into()),
                ..Default::default()
            },
        )
        .await;
    r.check(
        "insert under unknown parent is a permanent 400",
        matches!(&orphan, Err(e) if is_bad_request(e)),
        format!("{orphan:?}"),
    );
}

async fn probe_hierarchy_and_completion(client: &HttpClient, lid: &str, r: &mut Report) {
    // --- nesting depth: the API accepts >1 level -------------------------
    let p = new_task(client, lid, "parent", None).await;
    let c = new_task(client, lid, "child", Some(&p.id)).await;
    let gc = client
        .insert_task(
            lid,
            NewTask {
                title: "grandchild".into(),
                parent: Some(c.id.clone()),
                ..Default::default()
            },
        )
        .await;
    r.check(
        "API accepts a 2-levels-deep sub-subtask",
        gc.is_ok(),
        format!("{gc:?}"),
    );

    // --- completion cascade ----------------------------------------------
    let refreshed_p = client.get_task(lid, &p.id).await.expect("get parent");
    client
        .patch_task(
            lid,
            &p.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            refreshed_p.etag.as_deref(),
        )
        .await
        .expect("completing parent");
    let child_after = client.get_task(lid, &c.id).await.expect("get child");
    r.check(
        "completing a parent auto-completes its subtree",
        child_after.status == TaskStatus::Completed,
        format!("child status = {:?}", child_after.status),
    );

    // reopen child while parent stays completed → silently ignored
    let reopened = client
        .patch_task(
            lid,
            &c.id,
            TaskPatch {
                status: Some(TaskStatus::NeedsAction),
                ..Default::default()
            },
            child_after.etag.as_deref(),
        )
        .await;
    let child_now = client.get_task(lid, &c.id).await.expect("get child");
    r.check(
        "reopening a completed parent's child is silently ignored (200, no-op)",
        reopened.is_ok() && child_now.status == TaskStatus::Completed,
        format!("resp={reopened:?}, child status={:?}", child_now.status),
    );

    // reopen parent → children stay completed
    let parent_now = client.get_task(lid, &p.id).await.expect("get parent");
    client
        .patch_task(
            lid,
            &p.id,
            TaskPatch {
                status: Some(TaskStatus::NeedsAction),
                ..Default::default()
            },
            parent_now.etag.as_deref(),
        )
        .await
        .expect("reopening parent");
    let child_final = client.get_task(lid, &c.id).await.expect("get child");
    r.check(
        "reopening a parent does NOT reopen its children",
        child_final.status == TaskStatus::Completed,
        format!("child status = {:?}", child_final.status),
    );

    // --- delete cascade ---------------------------------------------------
    client
        .delete_task(lid, &p.id)
        .await
        .expect("deleting parent");
    let gone = client.get_task(lid, &c.id).await;
    r.check(
        "deleting a parent deletes its descendants server-side",
        matches!(gone, Err(ApiError::NotFound)),
        format!("{gone:?}"),
    );

    // --- move of unknown id ----------------------------------------------
    let bad_move = client.move_task(lid, "no-such-task-id", None, None).await;
    r.check(
        "moving an unknown id is a permanent 400, not a 404",
        matches!(&bad_move, Err(e) if is_bad_request(e)),
        format!("{bad_move:?}"),
    );
}

async fn new_task(
    client: &HttpClient,
    lid: &str,
    title: &str,
    parent: Option<&str>,
) -> axiotask_core::model::Task {
    client
        .insert_task(
            lid,
            NewTask {
                title: title.into(),
                parent: parent.map(String::from),
                ..Default::default()
            },
        )
        .await
        .unwrap_or_else(|e| panic!("insert {title} failed: {e:?}"))
}
