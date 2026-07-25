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
//!
//! RFC-009 unknowns (issue #106) — the eight `probe` rows of the sync conflict
//! matrix, each answered here before being encoded anywhere:
//! 1. does a move bump the task's etag?
//! 2. move with a remotely-deleted `previous` sibling: 400 or 404?
//! 3. move creating a 3rd level: exact rejection status (if any).
//! 4. move an open task under a completed parent: allowed? resulting status?
//! 5. insert an open subtask under a completed parent: result?
//! 6. complete a parent while a child exists that we never pulled: does the
//!    server cascade take it, and does the child's insert stale the parent etag?
//! 7. does `DELETE /tasks/{id}` honor `If-Match`?
//! 8. does `PATCH /users/@me/lists/{id}` honor `If-Match` (do list etags 412)?
//!
//! Round 2 (#114) — pinning the soft-delete shape the fake now models:
//! - 2a. the EXACT PATCH-echo of a deleted task: the 200 body echoes the edit
//!   and carries `deleted:true`, while the stored row is left untouched.
//! - 2b. a STALE `If-Match` PATCH on a deleted row still 200s (no 412) — the
//!   P4 guard that a delete/edit race never forks a conflicted copy.
//! - 2c. the exact status of a `move` naming an unknown / soft-deleted
//!   `parent` (the one case `in_memory.rs` had not probed separately).

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

    /// Like [`Report::check`], but always prints the observed value. Used for
    /// the RFC-009 rows, where the raw evidence (status code, body, resulting
    /// field) is what the task report and `in_memory.rs` cite.
    fn observe(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        if ok {
            self.passed += 1;
            println!("  PASS  {name} — observed: {detail}");
        } else {
            self.failed += 1;
            println!("  FAIL  {name} — observed: {detail}");
        }
    }
}

const BASE_URL: &str = "https://tasks.googleapis.com/tasks/v1";

/// Raw, unretried request escape hatch. The typed [`HttpClient`] deliberately
/// does not send `If-Match` on `delete_task` / `patch_tasklist`, and maps
/// statuses into [`ApiError`] — both of which hide exactly what probes 2, 3, 7
/// and 8 need to see. This issues the request itself and reports the verbatim
/// status code and body.
struct Raw {
    auth: axiotask_core::auth::AuthedClient,
}

/// Verbatim HTTP outcome: status code plus (truncated) response body.
struct RawResp {
    status: u16,
    body: String,
}

impl RawResp {
    /// The Tasks API soft-deletes: a deleted task keeps returning 200 on a
    /// direct GET, flagged `deleted: true`, and simply stops appearing in
    /// `tasks.list` (which defaults to `showDeleted=false`). This reads that
    /// flag out of the body.
    fn deleted_flag(&self) -> Option<bool> {
        serde_json::from_str::<serde_json::Value>(&self.body)
            .ok()
            .and_then(|v| v["deleted"].as_bool())
    }

    /// A named string field out of a task/list body.
    fn field(&self, key: &str) -> Option<String> {
        serde_json::from_str::<serde_json::Value>(&self.body)
            .ok()
            .and_then(|v| v[key].as_str().map(String::from))
    }
}

impl std::fmt::Display for RawResp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let msg = serde_json::from_str::<serde_json::Value>(&self.body)
            .ok()
            .and_then(|v| v["error"]["message"].as_str().map(String::from))
            .unwrap_or_else(|| self.body.chars().take(160).collect());
        write!(f, "HTTP {} {}", self.status, msg)
    }
}

impl Raw {
    async fn send(&self, req: reqwest::RequestBuilder, if_match: Option<&str>) -> RawResp {
        let req = match if_match {
            Some(e) => req.header(reqwest::header::IF_MATCH, e),
            None => req,
        };
        let resp = req.send().await.expect("raw request failed to send");
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        RawResp { status, body }
    }

    async fn delete_task(&self, lid: &str, id: &str, if_match: Option<&str>) -> RawResp {
        let url = format!("{BASE_URL}/lists/{lid}/tasks/{id}");
        self.send(self.auth.delete(&url), if_match).await
    }

    async fn patch_tasklist(&self, id: &str, title: &str, if_match: Option<&str>) -> RawResp {
        let url = format!("{BASE_URL}/users/@me/lists/{}", urlencoding::encode(id));
        let body = serde_json::json!({ "title": title });
        self.send(self.auth.patch(&url).json(&body), if_match).await
    }

    /// Raw `PATCH .../tasks/{id}` with an arbitrary JSON body and optional
    /// `If-Match`. The typed client drops the `deleted` flag and normalizes the
    /// body into a `Task`; probe round 2 needs the verbatim status + body to
    /// pin the exact PATCH-echo of a soft-deleted row.
    async fn patch_task(
        &self,
        lid: &str,
        id: &str,
        body: &serde_json::Value,
        if_match: Option<&str>,
    ) -> RawResp {
        let url = format!("{BASE_URL}/lists/{lid}/tasks/{id}");
        self.send(self.auth.patch(&url).json(body), if_match).await
    }

    fn move_url(lid: &str, id: &str, parent: Option<&str>, previous: Option<&str>) -> String {
        let mut url = format!("{BASE_URL}/lists/{lid}/tasks/{id}/move");
        let mut sep = '?';
        if let Some(p) = parent {
            url.push(sep);
            url.push_str(&format!("parent={}", urlencoding::encode(p)));
            sep = '&';
        }
        if let Some(prev) = previous {
            url.push(sep);
            url.push_str(&format!("previous={}", urlencoding::encode(prev)));
        }
        url
    }

    /// `POST .../move` with an explicit zero-length body (`Content-Length: 0`).
    async fn move_task(
        &self,
        lid: &str,
        id: &str,
        parent: Option<&str>,
        previous: Option<&str>,
    ) -> RawResp {
        let url = Self::move_url(lid, id, parent, previous);
        self.send(
            self.auth
                .post(&url)
                .header(reqwest::header::CONTENT_LENGTH, "0"),
            None,
        )
        .await
    }

    /// `POST .../move` with NO body at all — reqwest then omits `Content-Length`
    /// entirely. Probes whether the endpoint requires the header.
    async fn move_task_bodyless(
        &self,
        lid: &str,
        id: &str,
        parent: Option<&str>,
        previous: Option<&str>,
    ) -> RawResp {
        let url = Self::move_url(lid, id, parent, previous);
        self.send(self.auth.post(&url), None).await
    }

    async fn get_task(&self, lid: &str, id: &str) -> RawResp {
        let url = format!("{BASE_URL}/lists/{lid}/tasks/{id}");
        self.send(self.auth.get(&url), None).await
    }
}

fn dev_path(env_var: &str, rel: &str) -> PathBuf {
    if let Ok(p) = std::env::var(env_var) {
        return PathBuf::from(p);
    }
    let home = dirs::home_dir().expect("no home directory");
    home.join(rel)
}

fn build_authed() -> axiotask_core::auth::AuthedClient {
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

    AuthedClient::new(reqwest::Client::new(), tokens, store, refresh)
}

/// A permanent (non-transient) 400 from the API.
fn is_bad_request(err: &ApiError) -> bool {
    !err.is_transient() && !matches!(err, ApiError::PreconditionFailed | ApiError::NotFound)
}

#[tokio::main]
async fn main() {
    let client = HttpClient::new(build_authed());
    let raw = Raw {
        auth: build_authed(),
    };
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
    run_probes(&client, &raw, &lid, &mut r).await;

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

async fn run_probes(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    probe_dates_and_conflict(client, lid, r).await;
    probe_hierarchy_and_completion(client, lid, r).await;
    // RFC-009 (#106) rows.
    probe_delete_visibility(client, raw, lid, r).await;
    probe_move_semantics(client, raw, lid, r).await;
    probe_writes_under_completed_parent(client, raw, lid, r).await;
    probe_if_match_support(client, raw, lid, r).await;
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
    // Stated in terms of what a pull can observe: the API SOFT-deletes, so a
    // direct GET by id still returns the row with `deleted: true` (see
    // `probe_delete_visibility`). "Deleted" as the sync engine means it is
    // "gone from list_tasks", which is what ghost detection reads.
    client
        .delete_task(lid, &p.id)
        .await
        .expect("deleting parent");
    let listed = list_all(client, lid).await;
    r.check(
        "deleting a parent removes its descendants from list_tasks",
        !listed.iter().any(|t| t.id == c.id) && !listed.iter().any(|t| t.id == p.id),
        format!(
            "still listed: parent={}, child={}",
            listed.iter().any(|t| t.id == p.id),
            listed.iter().any(|t| t.id == c.id)
        ),
    );

    // --- move of unknown id ----------------------------------------------
    let bad_move = client.move_task(lid, "no-such-task-id", None, None).await;
    r.check(
        "moving an unknown id is a permanent 400, not a 404",
        matches!(&bad_move, Err(e) if is_bad_request(e)),
        format!("{bad_move:?}"),
    );
}

/// What "deleted" actually means server-side, for a task deleted directly and
/// for one taken by a parent's cascade. The engine's §B/§D rows are all written
/// in terms of "PATCH 404" and "the row disappears from the pull", so both must
/// be pinned to what the API really does.
async fn probe_delete_visibility(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    // --- a task deleted directly -----------------------------------------
    let direct = new_task(client, lid, "del-direct", None).await;
    client
        .delete_task(lid, &direct.id)
        .await
        .expect("direct delete");
    let got = raw.get_task(lid, &direct.id).await;
    r.observe(
        "GET on a deleted task returns 200 with deleted:true (soft delete)",
        got.status == 200 && got.deleted_flag() == Some(true),
        format!("{got} | deleted flag = {:?}", got.deleted_flag()),
    );
    let listed = list_all(client, lid).await;
    r.observe(
        "…and a deleted task is absent from list_tasks (showDeleted defaults off)",
        !listed.iter().any(|t| t.id == direct.id),
        format!(
            "present in list_tasks: {}",
            listed.iter().any(|t| t.id == direct.id)
        ),
    );
    // RFC-009 §B×deleted assumed a PATCH to a deleted row 404s. It does NOT:
    // the API answers 200 with a body echoing the edit, but the row stays
    // deleted and never returns to `list_tasks` — the same "accepted then
    // silently ignored" shape as reopening a completed parent's child. So the
    // engine's "PATCH 404 → hard-delete local" branch never fires here; what
    // actually converges the row is ghost detection on the next pull.
    let patched = client
        .patch_task(
            lid,
            &direct.id,
            TaskPatch {
                title: Some("edit-after-delete".into()),
                ..Default::default()
            },
            None,
        )
        .await;
    let back = list_all(client, lid)
        .await
        .iter()
        .any(|t| t.id == direct.id);
    let after = raw.get_task(lid, &direct.id).await;
    r.observe(
        "PATCH of a deleted task returns 200 but is silently ignored (row stays deleted)",
        patched.is_ok() && !back && after.deleted_flag() == Some(true),
        format!(
            "patch ok={}; back in list_tasks={back}; deleted flag still={:?}",
            patched.is_ok(),
            after.deleted_flag()
        ),
    );

    probe_deleted_patch_echo(client, raw, lid, r).await;

    // --- a child taken by its parent's cascade ---------------------------
    let p = new_task(client, lid, "del-casc-parent", None).await;
    let c = new_task(client, lid, "del-casc-child", Some(&p.id)).await;
    client.delete_task(lid, &p.id).await.expect("parent delete");
    let got = raw.get_task(lid, &c.id).await;
    r.observe(
        "a cascaded child is also soft-deleted (200, deleted:true)",
        got.status == 200 && got.deleted_flag() == Some(true),
        format!(
            "{got} | deleted={:?} parent={:?}",
            got.deleted_flag(),
            got.field("parent")
        ),
    );
    let listed = list_all(client, lid).await;
    r.observe(
        "…and the cascaded child is absent from list_tasks",
        !listed.iter().any(|t| t.id == c.id),
        format!(
            "present in list_tasks: {}",
            listed.iter().any(|t| t.id == c.id)
        ),
    );
    // A cascade-deleted child behaves identically: 200, silently ignored.
    let patched = client
        .patch_task(
            lid,
            &c.id,
            TaskPatch {
                title: Some("edit-after-cascade".into()),
                ..Default::default()
            },
            None,
        )
        .await;
    let back = list_all(client, lid).await.iter().any(|t| t.id == c.id);
    let after = raw.get_task(lid, &c.id).await;
    r.observe(
        "PATCH of a cascade-deleted child is likewise 200-but-ignored",
        patched.is_ok() && !back && after.deleted_flag() == Some(true),
        format!(
            "patch ok={}; back in list_tasks={back}; deleted flag still={:?}",
            patched.is_ok(),
            after.deleted_flag()
        ),
    );
}

/// Round 2 (#114): the EXACT shape of a soft-deleted row's PATCH, now that the
/// fake models it. 2a pins the echo body (edited fields returned, `deleted:true`,
/// stored row untouched); 2b pins the P4 guard that a stale `If-Match` still
/// 200s rather than 412ing into a spurious conflicted copy.
async fn probe_deleted_patch_echo(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    // --- round 2a: the EXACT PATCH-echo body -----------------------------
    // The fake returns a 200 whose body echoes the requested edit but carries
    // `deleted:true`, and leaves the stored row untouched (get still shows the
    // ORIGINAL title). Confirm that is what the live service actually returns,
    // to the field: does the 200 body echo `title`, and is it flagged deleted?
    let echoed = new_task(client, lid, "del-echo", None).await;
    let orig_etag = echoed.etag.clone();
    client
        .delete_task(lid, &echoed.id)
        .await
        .expect("delete for echo probe");
    let raw_patch = raw
        .patch_task(
            lid,
            &echoed.id,
            &serde_json::json!({ "title": "echoed-edit" }),
            None,
        )
        .await;
    let get_after = raw.get_task(lid, &echoed.id).await;
    r.observe(
        "round2a: PATCH-echo of a deleted task is 200, body carries the edited title AND deleted:true",
        raw_patch.status == 200
            && raw_patch.field("title").as_deref() == Some("echoed-edit")
            && raw_patch.deleted_flag() == Some(true),
        format!(
            "{raw_patch} | echoed title={:?} deleted={:?} etag before={:?} echo etag={:?}",
            raw_patch.field("title"),
            raw_patch.deleted_flag(),
            orig_etag,
            raw_patch.field("etag"),
        ),
    );
    r.observe(
        "round2a: …and the STORED row is untouched (get still shows the original title)",
        get_after.field("title").as_deref() == Some("del-echo")
            && get_after.deleted_flag() == Some(true),
        format!(
            "stored title={:?}, deleted={:?}",
            get_after.field("title"),
            get_after.deleted_flag()
        ),
    );

    // --- round 2b: a STALE If-Match PATCH on a deleted row ---------------
    // P4-critical: the engine cannot see `deleted` through the typed client, so
    // a 412 here would send it down the conflict-refetch path and fork a
    // conflicted copy of a row that is actually gone. Verify the deleted row
    // ignores the precondition too (200, not 412), so delete/edit never forks.
    let stale = new_task(client, lid, "del-stale", None).await;
    client
        .delete_task(lid, &stale.id)
        .await
        .expect("delete for stale-etag probe");
    let stale_patch = raw
        .patch_task(
            lid,
            &stale.id,
            &serde_json::json!({ "title": "stale-edit" }),
            Some("\"definitely-stale-etag\""),
        )
        .await;
    r.observe(
        "round2b: a stale If-Match PATCH on a deleted row still 200s (no 412 → no fork, P4)",
        stale_patch.status == 200,
        format!("{stale_patch}"),
    );
}

/// RFC-009 probes 1–4: what the `move` endpoint does with etags, dead sibling
/// anchors, a 3rd nesting level, and a completed destination parent.
async fn probe_move_semantics(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    // --- 0. transport: the move endpoint REQUIRES Content-Length ---------
    // reqwest omits Content-Length for a POST with no body, and Google answers
    // 411 — i.e. a bodyless `move` never lands. This row exists so nobody
    // "simplifies" the explicit empty body out of `http.rs::move_task` again.
    let t0 = new_task(client, lid, "mv-transport-a", None).await;
    let t1 = new_task(client, lid, "mv-transport-b", None).await;
    let bodyless = raw
        .move_task_bodyless(lid, &t1.id, None, Some(&t0.id))
        .await;
    r.observe(
        "POST /move with NO body is rejected 411 Length Required",
        bodyless.status == 411,
        format!("{bodyless}"),
    );
    let with_body = raw.move_task(lid, &t1.id, None, Some(&t0.id)).await;
    r.observe(
        "POST /move with an explicit empty body (Content-Length: 0) succeeds",
        with_body.status == 200,
        format!("{with_body}"),
    );

    // --- 1. does a move bump the task's etag? ----------------------------
    // Matters for §B×moved: if a move bumps the etag, an unrelated local
    // content edit 412s and must NOT produce a false conflicted copy.
    let anchor = new_task(client, lid, "mv-anchor", None).await;
    let subject = new_task(client, lid, "mv-subject", None).await;
    let before = subject.etag.clone();
    let moved = client
        .move_task(lid, &subject.id, None, Some(&anchor.id))
        .await
        .expect("reorder should succeed");
    r.observe(
        "a move bumps the task's etag",
        moved.etag.is_some() && moved.etag != before,
        format!("etag {:?} -> {:?}", before, moved.etag),
    );

    // --- 2. move with a remotely-deleted `previous` sibling --------------
    let dead_anchor = new_task(client, lid, "mv-dead-anchor", None).await;
    let orphan_mover = new_task(client, lid, "mv-after-dead", None).await;
    client
        .delete_task(lid, &dead_anchor.id)
        .await
        .expect("deleting the anchor");
    let resp = raw
        .move_task(lid, &orphan_mover.id, None, Some(&dead_anchor.id))
        .await;
    r.observe(
        "move with a deleted `previous` sibling is 404 'Previous task id not found'",
        resp.status == 404,
        format!("{resp}"),
    );
    // Note the asymmetry with an unknown SUBJECT id (400, checked above): the
    // engine must not read a move 404 as "the task I am moving is gone".
    let typed = client
        .move_task(lid, &orphan_mover.id, None, Some(&dead_anchor.id))
        .await;
    r.observe(
        "…and the typed client maps it to NotFound (non-transient)",
        matches!(&typed, Err(e) if !e.is_transient()) && matches!(typed, Err(ApiError::NotFound)),
        format!("{typed:?}"),
    );

    probe_move_unknown_parent(client, raw, lid, r).await;

    // --- 3. move creating a 3rd level ------------------------------------
    let l1 = new_task(client, lid, "depth-l1", None).await;
    let l2 = new_task(client, lid, "depth-l2", Some(&l1.id)).await;
    let l3 = new_task(client, lid, "depth-l3", None).await;
    let resp = raw.move_task(lid, &l3.id, Some(&l2.id), None).await;
    r.observe(
        "move creating a 3rd level is accepted (the API does not cap depth)",
        resp.status == 200,
        format!("{resp}"),
    );

    // --- 4. move an open task under a COMPLETED parent -------------------
    let done_parent = new_task(client, lid, "mv-done-parent", None).await;
    complete(client, lid, &done_parent.id).await;
    let open_child = new_task(client, lid, "mv-open-child", None).await;
    let resp = raw
        .move_task(lid, &open_child.id, Some(&done_parent.id), None)
        .await;
    r.observe(
        "moving an open task under a completed parent is accepted",
        resp.status == 200,
        format!("{resp}"),
    );
    if resp.status == 200 {
        let after = client
            .get_task(lid, &open_child.id)
            .await
            .expect("get moved child");
        r.observe(
            "…and the moved-in child is COMPLETED by the parent's cascade",
            after.status == TaskStatus::Completed,
            format!("status={:?}, parent={:?}", after.status, after.parent),
        );
    }
}

/// Round 2c (#114): the exact status of a `move` naming a `parent` that does not
/// exist — the one `move` field `in_memory.rs` had not probed separately. Two
/// variants: a parent id that never existed, and one soft-deleted mid-flight
/// (the only way a live parent actually vanishes). Either way it must be a
/// permanent rejection; the engine treats every permanent status the same.
async fn probe_move_unknown_parent(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    let mover_a = new_task(client, lid, "mv-bad-parent-a", None).await;
    let unknown_parent = raw
        .move_task(lid, &mover_a.id, Some("no-such-parent-id"), None)
        .await;
    r.observe(
        "round2c: move under an UNKNOWN parent — exact status (fake models 400)",
        unknown_parent.status == 400 || unknown_parent.status == 404,
        format!("{unknown_parent}"),
    );
    let doomed_parent = new_task(client, lid, "mv-doomed-parent", None).await;
    let mover_b = new_task(client, lid, "mv-bad-parent-b", None).await;
    client
        .delete_task(lid, &doomed_parent.id)
        .await
        .expect("deleting the doomed parent");
    let deleted_parent = raw
        .move_task(lid, &mover_b.id, Some(&doomed_parent.id), None)
        .await;
    r.observe(
        "round2c: move under a soft-DELETED parent — exact status (fake models 400)",
        deleted_parent.status == 400 || deleted_parent.status == 404,
        format!("{deleted_parent}"),
    );
}

/// RFC-009 probes 5–6: writes that race a completed parent.
async fn probe_writes_under_completed_parent(
    client: &HttpClient,
    _raw: &Raw,
    lid: &str,
    r: &mut Report,
) {
    // --- 5. insert an OPEN subtask under a completed parent --------------
    // §G: a subtask create whose parent completed remotely mid-flight.
    let done_parent = new_task(client, lid, "ins-done-parent", None).await;
    complete(client, lid, &done_parent.id).await;
    let inserted = client
        .insert_task(
            lid,
            NewTask {
                title: "ins-open-child".into(),
                parent: Some(done_parent.id.clone()),
                ..Default::default()
            },
        )
        .await;
    r.observe(
        "inserting an open subtask under a completed parent is accepted",
        inserted.is_ok(),
        format!("{inserted:?}"),
    );
    if let Ok(child) = &inserted {
        let refetched = client
            .get_task(lid, &child.id)
            .await
            .expect("get new child");
        r.observe(
            "…and the new subtask comes back COMPLETED, already in the insert response",
            child.status == TaskStatus::Completed && refetched.status == TaskStatus::Completed,
            format!(
                "insert response status={:?}, refetched status={:?}",
                child.status, refetched.status
            ),
        );
    }

    // --- 6. complete a parent while a child we never pulled exists -------
    // §C: our local cascade only knows the children we have pulled. Does the
    // server's cascade take the ones we have not?
    let parent = new_task(client, lid, "cascade-parent", None).await;
    let snapshot_etag = parent.etag.clone();
    let unseen = new_task(client, lid, "cascade-unseen-child", Some(&parent.id)).await;
    // Does another client's child-insert stale the parent's etag? If it does,
    // our complete would 412 on an edit we never made.
    let refetched_parent = client.get_task(lid, &parent.id).await.expect("get parent");
    r.observe(
        "inserting a child does NOT change the parent's etag",
        refetched_parent.etag == snapshot_etag,
        format!("{:?} -> {:?}", snapshot_etag, refetched_parent.etag),
    );
    let completed = client
        .patch_task(
            lid,
            &parent.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            snapshot_etag.as_deref(),
        )
        .await;
    r.observe(
        "completing a parent with a pre-child etag lands (no 412)",
        completed.is_ok(),
        format!("{completed:?}"),
    );
    let child_after = client.get_task(lid, &unseen.id).await.expect("get child");
    r.observe(
        "the server cascade completes a child we never pulled",
        child_after.status == TaskStatus::Completed,
        format!("unseen child status={:?}", child_after.status),
    );
}

/// RFC-009 probes 7–8: which endpoints actually honor `If-Match`.
async fn probe_if_match_support(client: &HttpClient, raw: &Raw, lid: &str, r: &mut Report) {
    // --- 7. does DELETE honor If-Match? ----------------------------------
    // It DOES: a stale etag 412s and the task survives. So P4's "delete is
    // unconditional" is our own choice (http.rs sends no If-Match), not a
    // physical constraint — D4 has a real alternative available.
    let victim = new_task(client, lid, "del-ifmatch", None).await;
    let stale = raw
        .delete_task(lid, &victim.id, Some("\"definitely-stale-etag\""))
        .await;
    let survived = list_all(client, lid)
        .await
        .iter()
        .any(|t| t.id == victim.id);
    r.observe(
        "DELETE HONORS If-Match: a stale etag 412s and the task survives",
        stale.status == 412 && survived,
        format!("{stale}; task still listed afterwards: {survived}"),
    );
    // …and the current etag deletes, proving the 412 was the precondition and
    // not a blanket rejection of the header.
    let current = client
        .get_task(lid, &victim.id)
        .await
        .expect("get before conditional delete");
    let fresh = raw
        .delete_task(lid, &victim.id, current.etag.as_deref())
        .await;
    let gone = !list_all(client, lid)
        .await
        .iter()
        .any(|t| t.id == victim.id);
    r.observe(
        "…and DELETE with the CURRENT etag succeeds",
        (fresh.status == 200 || fresh.status == 204) && gone,
        format!("{fresh}; removed from list_tasks: {gone}"),
    );

    // --- 8. does patch_tasklist honor If-Match? --------------------------
    // Renaming the scratch list itself; it is deleted at the end of the run.
    let lists = client.list_tasklists().await.expect("list tasklists");
    let etag_before = lists
        .iter()
        .find(|l| l.id == lid)
        .and_then(|l| l.etag.clone());
    let resp = raw
        .patch_tasklist(
            lid,
            "axiotask-probe-renamed",
            Some("\"definitely-stale-etag\""),
        )
        .await;
    let renamed = client
        .list_tasklists()
        .await
        .expect("list tasklists")
        .into_iter()
        .find(|l| l.id == lid)
        .map(|l| l.title);
    r.observe(
        "PATCH tasklist ignores If-Match (list renames are last-writer-wins)",
        resp.status == 200 && renamed.as_deref() == Some("axiotask-probe-renamed"),
        format!("{resp}; etag before={etag_before:?}; title now={renamed:?}"),
    );
}

/// Every task in a list, following pagination.
async fn list_all(client: &HttpClient, lid: &str) -> Vec<axiotask_core::model::Task> {
    let mut out = Vec::new();
    let mut token: Option<String> = None;
    loop {
        let page = client
            .list_tasks(lid, token.as_deref())
            .await
            .expect("list tasks");
        out.extend(page.items);
        match page.next_page_token {
            Some(t) => token = Some(t),
            None => return out,
        }
    }
}

/// Mark a task completed using its current server etag.
async fn complete(client: &HttpClient, lid: &str, id: &str) {
    let current = client.get_task(lid, id).await.expect("get before complete");
    client
        .patch_task(
            lid,
            id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            current.etag.as_deref(),
        )
        .await
        .expect("completing task");
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
