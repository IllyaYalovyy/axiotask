//! Domain types shared between API, store, and sync.
//!
//! Both API-shape and store-shape rows are represented here; conversions are
//! straightforward field maps. Keeping them in one module makes the domain
//! easy to reason about.

use serde::{Deserialize, Serialize};

/// A Google Tasks task list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskList {
    /// Google's identifier (or a local UUID before first push).
    pub id: String,
    /// Display title.
    pub title: String,
    /// Opaque etag returned by Google. `None` for local-only rows.
    pub etag: Option<String>,
    /// Server-side `updated` timestamp (RFC 3339).
    pub updated: String,
}

/// A Google Tasks task (a leaf or an interior node of the tree).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Task {
    /// Google's identifier (or a local UUID before first push).
    pub id: String,
    /// Parent task id; `None` means the task is a top-level item of its list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// Google's lex-sortable position string. Opaque to us.
    pub position: String,
    /// Display title.
    pub title: String,
    /// Free-form notes. Empty string is treated as `None` on the wire.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Completion status.
    pub status: TaskStatus,
    /// Due date (RFC 3339; date-only effectively, time component ignored by Google).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    /// Completion timestamp (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed: Option<String>,
    /// Opaque etag returned by Google.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub etag: Option<String>,
    /// Server-side `updated` timestamp.
    pub updated: String,
}

/// Completion status for a task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskStatus {
    /// Task is open.
    NeedsAction,
    /// Task has been completed.
    Completed,
}

impl TaskStatus {
    /// String form used by Google's API.
    pub fn as_api_str(self) -> &'static str {
        match self {
            Self::NeedsAction => "needsAction",
            Self::Completed => "completed",
        }
    }

    /// Parse from Google's API string form. Returns `None` for unknown values.
    pub fn parse_api(s: &str) -> Option<Self> {
        match s {
            "needsAction" => Some(Self::NeedsAction),
            "completed" => Some(Self::Completed),
            _ => None,
        }
    }
}

/// Payload accepted by `insert_task`. Server fills in the missing fields.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewTask {
    /// Display title.
    pub title: String,
    /// Optional notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Optional due date.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    /// Optional initial status (defaults to `NeedsAction`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskStatus>,
    /// Optional parent task id; `None` makes it a top-level task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// Optional preceding-sibling id for placement.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous: Option<String>,
}

/// Sparse update for `patch_task` — only `Some` fields are sent.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskPatch {
    /// New title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// New notes (`Some("")` clears).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// New due date (`Some("")` clears).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    /// New status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskStatus>,
}

impl TaskPatch {
    /// Returns true if no fields are set.
    pub fn is_empty(&self) -> bool {
        self.title.is_none() && self.notes.is_none() && self.due.is_none() && self.status.is_none()
    }
}

/// One page of a paginated list response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page<T> {
    /// The items in this page.
    pub items: Vec<T>,
    /// Continuation token, if more pages exist.
    pub next_page_token: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_status_round_trips_through_api_strings() {
        assert_eq!(
            TaskStatus::parse_api(TaskStatus::NeedsAction.as_api_str()),
            Some(TaskStatus::NeedsAction)
        );
        assert_eq!(
            TaskStatus::parse_api(TaskStatus::Completed.as_api_str()),
            Some(TaskStatus::Completed)
        );
        assert_eq!(TaskStatus::parse_api("nonsense"), None);
    }

    #[test]
    fn empty_patch_is_detected_as_empty() {
        assert!(TaskPatch::default().is_empty());
        assert!(
            !TaskPatch {
                title: Some("x".into()),
                ..Default::default()
            }
            .is_empty()
        );
    }

    #[test]
    fn task_serializes_with_camel_case_status() {
        let t = Task {
            id: "1".into(),
            parent: None,
            position: "00000000000001".into(),
            title: "Buy milk".into(),
            notes: None,
            status: TaskStatus::NeedsAction,
            due: None,
            completed: None,
            etag: None,
            updated: "2026-05-23T00:00:00Z".into(),
        };
        let json = serde_json::to_string(&t).unwrap();
        assert!(json.contains("\"status\":\"needsAction\""), "got: {json}");
        assert!(
            !json.contains("\"parent\""),
            "parent should be skipped when None"
        );
    }
}
