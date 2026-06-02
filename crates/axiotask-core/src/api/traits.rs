//! The sole abstraction layer between the app and Google's Tasks API.

use async_trait::async_trait;

use super::ApiError;
use crate::model::{NewTask, Page, Task, TaskList, TaskPatch};

/// Operations against Google Tasks v1. The MVP needs exactly these — adding
/// methods here is the canonical extension point.
#[async_trait]
pub trait GoogleTasksClient: Send + Sync {
    /// List all task lists the authenticated user can see.
    async fn list_tasklists(&self) -> Result<Vec<TaskList>, ApiError>;

    /// List tasks in `list_id`. Pass the previous page's `next_page_token`
    /// to continue; pass `None` to start.
    async fn list_tasks(
        &self,
        list_id: &str,
        page_token: Option<&str>,
    ) -> Result<Page<Task>, ApiError>;

    /// Insert a task. Returns the server's view of the new task (etag,
    /// position, etc. filled in).
    async fn insert_task(&self, list_id: &str, new: NewTask) -> Result<Task, ApiError>;

    /// Sparse update by id. If `etag` is `Some`, the request is sent with
    /// `If-Match` and will return [`ApiError::PreconditionFailed`] on conflict.
    async fn patch_task(
        &self,
        list_id: &str,
        id: &str,
        patch: TaskPatch,
        etag: Option<&str>,
    ) -> Result<Task, ApiError>;

    /// Delete a task by id.
    async fn delete_task(&self, list_id: &str, id: &str) -> Result<(), ApiError>;

    /// Reparent / reorder a task. Either `parent` or `previous` may be `None`.
    /// Returns the server's view after the move.
    async fn move_task(
        &self,
        list_id: &str,
        id: &str,
        parent: Option<&str>,
        previous: Option<&str>,
    ) -> Result<Task, ApiError>;
}
