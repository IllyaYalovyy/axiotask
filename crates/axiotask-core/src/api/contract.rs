//! Shared contract tests that exercise any [`GoogleTasksClient`]
//! implementation through the same scenarios. Both [`InMemoryClient`] and
//! [`HttpClient`] (driven by `wiremock` in integration tests) are expected to
//! satisfy these assertions.

#![allow(dead_code)]

use super::{ApiError, GoogleTasksClient};
use crate::model::{NewTask, TaskPatch, TaskStatus};

/// Insert → list-tasks round-trip: a created task shows up in the listing.
pub async fn insert_then_list_returns_new_row<C: GoogleTasksClient>(c: &C, list_id: &str) {
    let inserted = c
        .insert_task(
            list_id,
            NewTask {
                title: "from contract".into(),
                ..Default::default()
            },
        )
        .await
        .expect("insert");
    let page = c.list_tasks(list_id, None).await.expect("list");
    assert!(
        page.items.iter().any(|t| t.id == inserted.id),
        "newly inserted task must appear in list"
    );
}

/// Patch with a stale etag returns [`ApiError::PreconditionFailed`].
pub async fn stale_etag_is_rejected<C: GoogleTasksClient>(c: &C, list_id: &str) {
    let t = c
        .insert_task(
            list_id,
            NewTask {
                title: "x".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let err = c
        .patch_task(
            list_id,
            &t.id,
            TaskPatch {
                title: Some("y".into()),
                ..Default::default()
            },
            Some("definitely-not-the-etag"),
        )
        .await
        .unwrap_err();
    assert!(matches!(err, ApiError::PreconditionFailed));
}

/// Completion via patch flips status and back.
pub async fn patch_status_round_trip<C: GoogleTasksClient>(c: &C, list_id: &str) {
    let t = c
        .insert_task(
            list_id,
            NewTask {
                title: "to-complete".into(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    let done = c
        .patch_task(
            list_id,
            &t.id,
            TaskPatch {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            t.etag.as_deref(),
        )
        .await
        .unwrap();
    assert_eq!(done.status, TaskStatus::Completed);
    let undone = c
        .patch_task(
            list_id,
            &t.id,
            TaskPatch {
                status: Some(TaskStatus::NeedsAction),
                ..Default::default()
            },
            done.etag.as_deref(),
        )
        .await
        .unwrap();
    assert_eq!(undone.status, TaskStatus::NeedsAction);
}

#[cfg(test)]
mod against_in_memory {
    use super::*;
    use crate::api::InMemoryClient;

    #[tokio::test]
    async fn insert_then_list() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        insert_then_list_returns_new_row(&c, "L1").await;
    }

    #[tokio::test]
    async fn stale_etag() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        stale_etag_is_rejected(&c, "L1").await;
    }

    #[tokio::test]
    async fn status_round_trip() {
        let c = InMemoryClient::new();
        c.seed_list("L1", "Inbox");
        patch_status_round_trip(&c, "L1").await;
    }
}
