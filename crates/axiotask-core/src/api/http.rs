//! Real [`GoogleTasksClient`] backed by `reqwest` against the Google Tasks v1 REST API.
//!
//! Authentication is delegated to [`crate::auth::AuthedClient`], which handles
//! `Authorization` headers and refresh-on-`401`. This module is responsible for:
//! - URL construction
//! - request/response (de)serialization
//! - mapping HTTP status to [`ApiError`]
//! - pagination
//! - exponential backoff on 5xx / 429

use std::time::Duration;

use async_trait::async_trait;
use reqwest::StatusCode;
use serde::Deserialize;

use super::{ApiError, GoogleTasksClient};
use crate::auth::AuthedClient;
use crate::model::{NewTask, Page, Task, TaskList, TaskPatch};

const BASE_URL: &str = "https://tasks.googleapis.com/tasks/v1";

/// HTTP-backed Google Tasks client.
pub struct HttpClient {
    auth: AuthedClient,
    base_url: String,
    max_retries: u32,
}

impl HttpClient {
    /// Construct against the real Google API endpoint.
    pub fn new(auth: AuthedClient) -> Self {
        Self {
            auth,
            base_url: BASE_URL.into(),
            max_retries: 4,
        }
    }

    /// Construct against an arbitrary base URL — used by `wiremock`-backed tests.
    pub fn with_base_url(auth: AuthedClient, base_url: impl Into<String>) -> Self {
        Self {
            auth,
            base_url: base_url.into(),
            max_retries: 4,
        }
    }

    /// Disable retries (useful in tests).
    pub fn with_max_retries(mut self, n: u32) -> Self {
        self.max_retries = n;
        self
    }

    /// Send with retry, and on 401 refresh the token and retry once.
    async fn send_authed<F, Fut>(&self, mut req: F) -> Result<reqwest::Response, ApiError>
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = Result<reqwest::Response, reqwest::Error>>,
    {
        match send_with_retry(self.max_retries, &mut req).await {
            Err(ApiError::Unauthorized) => {
                // Attempt token refresh, then retry once.
                self.auth
                    .refresh_now()
                    .await
                    .map_err(|e| ApiError::Other(format!("refresh failed: {e}")))?;
                send_with_retry(self.max_retries, &mut req).await
            }
            other => other,
        }
    }
}

#[derive(Debug, Deserialize)]
struct TaskListsResponse {
    items: Option<Vec<TaskListWire>>,
}

#[derive(Debug, Deserialize)]
struct TaskListWire {
    id: String,
    title: String,
    etag: Option<String>,
    updated: Option<String>,
}

impl From<TaskListWire> for TaskList {
    fn from(w: TaskListWire) -> Self {
        Self {
            id: w.id,
            title: w.title,
            etag: w.etag,
            updated: w.updated.unwrap_or_default(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct TasksResponse {
    items: Option<Vec<TaskWire>>,
    #[serde(rename = "nextPageToken")]
    next_page_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TaskWire {
    id: String,
    title: Option<String>,
    notes: Option<String>,
    status: Option<String>,
    due: Option<String>,
    completed: Option<String>,
    parent: Option<String>,
    position: Option<String>,
    etag: Option<String>,
    updated: Option<String>,
    #[serde(rename = "webViewLink")]
    web_view_link: Option<String>,
}

impl TryFrom<TaskWire> for Task {
    type Error = ApiError;
    fn try_from(w: TaskWire) -> Result<Self, ApiError> {
        let status = w
            .status
            .as_deref()
            .and_then(crate::model::TaskStatus::parse_api)
            .ok_or_else(|| ApiError::Other(format!("unknown status for task {}", w.id)))?;
        Ok(Self {
            id: w.id,
            parent: w.parent,
            position: w.position.unwrap_or_default(),
            title: w.title.unwrap_or_default(),
            notes: w.notes,
            status,
            due: w.due,
            completed: w.completed,
            etag: w.etag,
            updated: w.updated.unwrap_or_default(),
            web_view_link: w.web_view_link,
        })
    }
}

fn map_status(status: StatusCode, retry_after: Option<Duration>) -> ApiError {
    match status.as_u16() {
        401 => ApiError::Unauthorized,
        404 => ApiError::NotFound,
        409 | 412 => ApiError::PreconditionFailed,
        429 => ApiError::RateLimited { retry_after },
        500..=599 => ApiError::Server {
            status: status.as_u16(),
        },
        other => ApiError::Other(format!("unexpected status {other}")),
    }
}

fn retry_after_from(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    headers
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_secs)
}

async fn send_with_retry<F, Fut>(
    max_retries: u32,
    mut req: F,
) -> Result<reqwest::Response, ApiError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<reqwest::Response, reqwest::Error>>,
{
    let mut attempt: u32 = 0;
    loop {
        let result = req().await;
        let resp = match result {
            Ok(r) => r,
            Err(e) => {
                if attempt >= max_retries {
                    return Err(ApiError::Network(e.to_string()));
                }
                attempt += 1;
                tokio::time::sleep(backoff(attempt)).await;
                continue;
            }
        };
        let status = resp.status();
        if status.is_success() {
            return Ok(resp);
        }
        let retry_after = retry_after_from(resp.headers());
        let err = map_status(status, retry_after);
        if !err.is_transient() || attempt >= max_retries {
            return Err(err);
        }
        attempt += 1;
        let delay = retry_after.unwrap_or_else(|| backoff(attempt));
        tokio::time::sleep(delay).await;
    }
}

fn backoff(attempt: u32) -> Duration {
    // 100ms, 200ms, 400ms, 800ms, capped at 5s.
    let ms = 100u64.saturating_mul(1u64 << attempt.min(6));
    Duration::from_millis(ms.min(5_000))
}

#[async_trait]
impl GoogleTasksClient for HttpClient {
    async fn list_tasklists(&self) -> Result<Vec<TaskList>, ApiError> {
        let url = format!("{}/users/@me/lists", self.base_url);
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.get(&url).send().await }).await?;
        let body: TaskListsResponse = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode lists: {e}")))?;
        Ok(body
            .items
            .unwrap_or_default()
            .into_iter()
            .map(TaskList::from)
            .collect())
    }

    async fn insert_tasklist(&self, title: &str) -> Result<TaskList, ApiError> {
        let url = format!("{}/users/@me/lists", self.base_url);
        let body = serde_json::json!({ "title": title });
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.post(&url).json(&body).send().await }).await?;
        let wire: TaskListWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode list insert: {e}")))?;
        Ok(TaskList::from(wire))
    }

    // NOTE: no If-Match — the tasklists endpoint IGNORES it (a stale etag still
    // returns 200; verified live), so list renames are last-writer-wins by
    // server design. Conflict detection for lists is not possible.
    async fn patch_tasklist(&self, id: &str, title: &str) -> Result<TaskList, ApiError> {
        let url = format!("{}/users/@me/lists/{}", self.base_url, urlencoding::encode(id));
        let body = serde_json::json!({ "title": title });
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.patch(&url).json(&body).send().await }).await?;
        let wire: TaskListWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode list patch: {e}")))?;
        Ok(TaskList::from(wire))
    }

    async fn delete_tasklist(&self, id: &str) -> Result<(), ApiError> {
        let url = format!("{}/users/@me/lists/{}", self.base_url, urlencoding::encode(id));
        let auth = &self.auth;
        let _ = self.send_authed(|| async { auth.delete(&url).send().await }).await?;
        Ok(())
    }

    async fn list_tasks(
        &self,
        list_id: &str,
        page_token: Option<&str>,
    ) -> Result<Page<Task>, ApiError> {
        let mut url = format!(
            "{}/lists/{}/tasks?showCompleted=true&showHidden=true",
            self.base_url, list_id
        );
        if let Some(tok) = page_token {
            url.push_str("&pageToken=");
            url.push_str(&urlencoding::encode(tok));
        }
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.get(&url).send().await }).await?;
        let body: TasksResponse = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode tasks: {e}")))?;
        let items = body
            .items
            .unwrap_or_default()
            .into_iter()
            .map(Task::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Page {
            items,
            next_page_token: body.next_page_token,
        })
    }

    async fn insert_task(&self, list_id: &str, new: NewTask) -> Result<Task, ApiError> {
        let mut url = format!("{}/lists/{}/tasks", self.base_url, list_id);
        if let Some(p) = new.parent.as_deref() {
            url.push_str(&format!("?parent={}", urlencoding::encode(p)));
            if let Some(prev) = new.previous.as_deref() {
                url.push_str(&format!("&previous={}", urlencoding::encode(prev)));
            }
        } else if let Some(prev) = new.previous.as_deref() {
            url.push_str(&format!("?previous={}", urlencoding::encode(prev)));
        }
        let body = serde_json::json!({
            "title": new.title,
            "notes": new.notes,
            "due": new.due,
            "status": new.status.unwrap_or(crate::model::TaskStatus::NeedsAction).as_api_str(),
        });
        let auth = &self.auth;
        let resp = self.send_authed(|| async {
            auth.post(&url).json(&body).send().await
        })
        .await?;
        let wire: TaskWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode insert: {e}")))?;
        Task::try_from(wire)
    }

    async fn get_task(&self, list_id: &str, id: &str) -> Result<Task, ApiError> {
        let url = format!(
            "{}/lists/{}/tasks/{}",
            self.base_url,
            urlencoding::encode(list_id),
            urlencoding::encode(id)
        );
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.get(&url).send().await }).await?;
        let wire: TaskWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode get: {e}")))?;
        Task::try_from(wire)
    }

    async fn patch_task(
        &self,
        list_id: &str,
        id: &str,
        patch: TaskPatch,
        etag: Option<&str>,
    ) -> Result<Task, ApiError> {
        let url = format!("{}/lists/{}/tasks/{}", self.base_url, list_id, id);
        let mut body = serde_json::Map::new();
        if let Some(t) = patch.title {
            body.insert("title".into(), serde_json::Value::String(t));
        }
        if let Some(n) = patch.notes {
            body.insert("notes".into(), serde_json::Value::String(n));
        }
        if let Some(d) = patch.due {
            body.insert("due".into(), serde_json::Value::String(d));
        }
        if let Some(s) = patch.status {
            body.insert(
                "status".into(),
                serde_json::Value::String(s.as_api_str().into()),
            );
        }
        let auth = &self.auth;
        let resp = self.send_authed(|| async {
            let mut req = auth.patch(&url);
            if let Some(e) = etag {
                req = req.header(reqwest::header::IF_MATCH, e);
            }
            req.json(&body).send().await
        })
        .await?;
        let wire: TaskWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode patch: {e}")))?;
        Task::try_from(wire)
    }

    async fn delete_task(&self, list_id: &str, id: &str) -> Result<(), ApiError> {
        let url = format!("{}/lists/{}/tasks/{}", self.base_url, list_id, id);
        let auth = &self.auth;
        let _ = self.send_authed(|| async {
            auth.delete(&url).send().await
        })
        .await?;
        Ok(())
    }

    async fn move_task(
        &self,
        list_id: &str,
        id: &str,
        parent: Option<&str>,
        previous: Option<&str>,
    ) -> Result<Task, ApiError> {
        let mut url = format!("{}/lists/{}/tasks/{}/move", self.base_url, list_id, id);
        let mut sep = '?';
        if let Some(p) = parent {
            url.push(sep);
            url.push_str("parent=");
            url.push_str(&urlencoding::encode(p));
            sep = '&';
        }
        if let Some(prev) = previous {
            url.push(sep);
            url.push_str("previous=");
            url.push_str(&urlencoding::encode(prev));
        }
        let auth = &self.auth;
        let resp = self.send_authed(|| async { auth.post(&url).send().await }).await?;
        let wire: TaskWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode move: {e}")))?;
        Task::try_from(wire)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use crate::auth::{AuthedClient, InMemoryTokenStore, RefreshFn, StoredTokens};

    #[test]
    fn backoff_grows_then_caps() {
        assert!(backoff(1) >= Duration::from_millis(100));
        assert!(backoff(10) <= Duration::from_secs(5));
    }

    #[test]
    fn map_status_categorizes_correctly() {
        assert!(matches!(
            map_status(StatusCode::UNAUTHORIZED, None),
            ApiError::Unauthorized
        ));
        assert!(matches!(
            map_status(StatusCode::PRECONDITION_FAILED, None),
            ApiError::PreconditionFailed
        ));
        assert!(matches!(
            map_status(StatusCode::TOO_MANY_REQUESTS, None),
            ApiError::RateLimited { .. }
        ));
        assert!(matches!(
            map_status(StatusCode::SERVICE_UNAVAILABLE, None),
            ApiError::Server { status: 503 }
        ));
    }

    fn make_tokens(access: &str) -> StoredTokens {
        StoredTokens {
            access_token: access.into(),
            refresh_token: "rt".into(),
            access_expires_at: Some(i64::MAX),
            scope: "tasks".into(),
        }
    }

    fn counting_refresh(counter: Arc<AtomicU32>) -> RefreshFn {
        Arc::new(move |_rt: String| {
            let counter = counter.clone();
            Box::pin(async move {
                counter.fetch_add(1, Ordering::SeqCst);
                Ok(make_tokens("refreshed-token"))
            })
        })
    }

    fn build_test_client(base_url: &str, tokens: StoredTokens, refresh: RefreshFn) -> HttpClient {
        let store: Arc<dyn crate::auth::TokenStore> = Arc::new(InMemoryTokenStore::new());
        store.save(&tokens).unwrap();
        let authed = AuthedClient::new(reqwest::Client::new(), tokens, store, refresh);
        HttpClient::with_base_url(authed, base_url).with_max_retries(0)
    }

    #[tokio::test]
    async fn refresh_on_401_then_retry_succeeds() {
        let server = MockServer::start().await;
        let refresh_count = Arc::new(AtomicU32::new(0));

        // First call returns 401, second (after refresh) returns 200.
        Mock::given(method("GET"))
            .and(path("/users/@me/lists"))
            .respond_with(ResponseTemplate::new(401))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/users/@me/lists"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                serde_json::json!({"items": [{"id": "L1", "title": "Inbox", "updated": "2026-01-01T00:00:00Z"}]}),
            ))
            .mount(&server)
            .await;

        let client = build_test_client(
            &server.uri(),
            make_tokens("expired-token"),
            counting_refresh(refresh_count.clone()),
        );

        let lists = client.list_tasklists().await.unwrap();
        assert_eq!(lists.len(), 1);
        assert_eq!(lists[0].title, "Inbox");
        assert_eq!(refresh_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn refresh_on_401_still_fails_returns_unauthorized() {
        let server = MockServer::start().await;
        let refresh_count = Arc::new(AtomicU32::new(0));

        // Both calls return 401 — refresh doesn't help.
        Mock::given(method("GET"))
            .and(path("/users/@me/lists"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;

        let client = build_test_client(
            &server.uri(),
            make_tokens("bad-token"),
            counting_refresh(refresh_count.clone()),
        );

        let err = client.list_tasklists().await.unwrap_err();
        assert!(matches!(err, ApiError::Unauthorized));
        assert_eq!(refresh_count.load(Ordering::SeqCst), 1);
    }

    // ─── Task method tests (request construction + response parsing) ──────────

    fn plain_client(base_url: &str) -> HttpClient {
        let refresh = Arc::new(AtomicU32::new(0));
        build_test_client(base_url, make_tokens("token"), counting_refresh(refresh))
    }

    #[tokio::test]
    async fn list_tasks_parses_response_and_pagination() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/lists/L1/tasks"))
            .and(query_param("showCompleted", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "items": [
                    {"id": "T1", "title": "first", "status": "needsAction", "position": "00001", "updated": "2026-01-01T00:00:00Z"},
                    {"id": "T2", "title": "done", "status": "completed", "position": "00002", "updated": "2026-01-01T00:00:00Z"}
                ],
                "nextPageToken": "page2"
            })))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let page = client.list_tasks("L1", None).await.unwrap();
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "first");
        assert_eq!(page.items[1].status, crate::model::TaskStatus::Completed);
        assert_eq!(page.next_page_token.as_deref(), Some("page2"));
    }

    #[tokio::test]
    async fn list_tasks_passes_page_token() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;

        Mock::given(method("GET"))
            .and(path("/lists/L1/tasks"))
            .and(query_param("pageToken", "tok-abc"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"items": []})))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let page = client.list_tasks("L1", Some("tok-abc")).await.unwrap();
        assert!(page.items.is_empty());
    }

    #[tokio::test]
    async fn list_tasks_encodes_special_page_token() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;

        // Google page tokens can contain characters needing URL encoding.
        // wiremock decodes query params, so query_param matcher sees the
        // decoded value — this verifies we encoded it correctly on the wire.
        Mock::given(method("GET"))
            .and(path("/lists/L1/tasks"))
            .and(query_param("pageToken", "a b+c/d=e"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"items": []})))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let result = client.list_tasks("L1", Some("a b+c/d=e")).await;
        assert!(result.is_ok(), "special page token must be URL-encoded");
    }

    #[tokio::test]
    async fn insert_task_sends_body_and_parses_response() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/lists/L1/tasks"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "remote-1", "title": "new task", "status": "needsAction",
                "position": "00001", "etag": "etag-1", "updated": "2026-01-01T00:00:00Z"
            })))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let task = client.insert_task("L1", NewTask { title: "new task".into(), ..Default::default() }).await.unwrap();
        assert_eq!(task.id, "remote-1");
        assert_eq!(task.etag.as_deref(), Some("etag-1"));
    }

    #[tokio::test]
    async fn patch_task_sends_if_match_etag() {
        use wiremock::matchers::header;
        let server = MockServer::start().await;

        Mock::given(method("PATCH"))
            .and(path("/lists/L1/tasks/T1"))
            .and(header("if-match", "etag-xyz"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "T1", "title": "updated", "status": "needsAction",
                "position": "1", "etag": "etag-new", "updated": "2026-01-02T00:00:00Z"
            })))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let patch = TaskPatch { title: Some("updated".into()), ..Default::default() };
        let task = client.patch_task("L1", "T1", patch, Some("etag-xyz")).await.unwrap();
        assert_eq!(task.title, "updated");
        assert_eq!(task.etag.as_deref(), Some("etag-new"));
    }

    #[tokio::test]
    async fn patch_task_412_maps_to_precondition_failed() {
        let server = MockServer::start().await;

        Mock::given(method("PATCH"))
            .and(path("/lists/L1/tasks/T1"))
            .respond_with(ResponseTemplate::new(412))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let patch = TaskPatch { title: Some("x".into()), ..Default::default() };
        let err = client.patch_task("L1", "T1", patch, Some("stale")).await.unwrap_err();
        assert!(matches!(err, ApiError::PreconditionFailed));
    }

    #[tokio::test]
    async fn delete_task_succeeds() {
        let server = MockServer::start().await;

        Mock::given(method("DELETE"))
            .and(path("/lists/L1/tasks/T1"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        assert!(client.delete_task("L1", "T1").await.is_ok());
    }

    #[tokio::test]
    async fn delete_task_404_maps_to_not_found() {
        let server = MockServer::start().await;

        Mock::given(method("DELETE"))
            .and(path("/lists/L1/tasks/gone"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let err = client.delete_task("L1", "gone").await.unwrap_err();
        assert!(matches!(err, ApiError::NotFound));
    }

    #[tokio::test]
    async fn move_task_sends_parent_and_previous() {
        use wiremock::matchers::query_param;
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/lists/L1/tasks/T1/move"))
            .and(query_param("parent", "P1"))
            .and(query_param("previous", "T0"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "T1", "title": "moved", "status": "needsAction",
                "parent": "P1", "position": "1", "updated": "2026-01-01T00:00:00Z"
            })))
            .mount(&server)
            .await;

        let client = plain_client(&server.uri());
        let task = client.move_task("L1", "T1", Some("P1"), Some("T0")).await.unwrap();
        assert_eq!(task.parent.as_deref(), Some("P1"));
    }

    #[tokio::test]
    async fn insert_tasklist_sends_title_and_parses() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/users/@me/lists"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "L-new", "title": "Work", "etag": "e1", "updated": "2026-01-01T00:00:00Z"
            })))
            .mount(&server)
            .await;
        let client = plain_client(&server.uri());
        let list = client.insert_tasklist("Work").await.unwrap();
        assert_eq!(list.id, "L-new");
        assert_eq!(list.title, "Work");
        assert_eq!(list.etag.as_deref(), Some("e1"));
    }

    #[tokio::test]
    async fn patch_tasklist_renames() {
        let server = MockServer::start().await;
        Mock::given(method("PATCH"))
            .and(path("/users/@me/lists/L1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "L1", "title": "Renamed", "etag": "e2", "updated": "2026-01-02T00:00:00Z"
            })))
            .mount(&server)
            .await;
        let client = plain_client(&server.uri());
        let list = client.patch_tasklist("L1", "Renamed").await.unwrap();
        assert_eq!(list.title, "Renamed");
        assert_eq!(list.etag.as_deref(), Some("e2"));
    }

    #[tokio::test]
    async fn delete_tasklist_succeeds() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .and(path("/users/@me/lists/L1"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        let client = plain_client(&server.uri());
        assert!(client.delete_tasklist("L1").await.is_ok());
    }

    #[tokio::test]
    async fn delete_tasklist_404_maps_not_found() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .and(path("/users/@me/lists/gone"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&server)
            .await;
        let client = plain_client(&server.uri());
        assert!(matches!(client.delete_tasklist("gone").await.unwrap_err(), ApiError::NotFound));
    }
}
