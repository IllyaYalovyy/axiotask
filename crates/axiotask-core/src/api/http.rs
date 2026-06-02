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
        let resp =
            send_with_retry(self.max_retries, || async { auth.get(&url).send().await }).await?;
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
            url.push_str(tok);
        }
        let auth = &self.auth;
        let resp =
            send_with_retry(self.max_retries, || async { auth.get(&url).send().await }).await?;
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
            url.push_str(&format!("?parent={p}"));
            if let Some(prev) = new.previous.as_deref() {
                url.push_str(&format!("&previous={prev}"));
            }
        } else if let Some(prev) = new.previous.as_deref() {
            url.push_str(&format!("?previous={prev}"));
        }
        let body = serde_json::json!({
            "title": new.title,
            "notes": new.notes,
            "due": new.due,
            "status": new.status.unwrap_or(crate::model::TaskStatus::NeedsAction).as_api_str(),
        });
        let auth = &self.auth;
        let resp = send_with_retry(self.max_retries, || async {
            auth.post(&url).json(&body).send().await
        })
        .await?;
        let wire: TaskWire = resp
            .json()
            .await
            .map_err(|e| ApiError::Other(format!("decode insert: {e}")))?;
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
        let resp = send_with_retry(self.max_retries, || async {
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
        let _ = send_with_retry(self.max_retries, || async {
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
            url.push_str(p);
            sep = '&';
        }
        if let Some(prev) = previous {
            url.push(sep);
            url.push_str("previous=");
            url.push_str(prev);
        }
        let auth = &self.auth;
        let resp =
            send_with_retry(self.max_retries, || async { auth.post(&url).send().await }).await?;
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
}
