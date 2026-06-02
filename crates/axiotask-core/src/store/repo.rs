//! High-level operations on the local SQLite cache.
//!
//! The store mirrors what's on Google plus per-row sync metadata. The sync
//! engine drains `dirty` rows; the UI reads `clean` + `dirty` rows together,
//! and skips `deleted` ones.

use sqlx::{Row, SqlitePool};

use super::StoreError;
use crate::model::{Task, TaskList, TaskStatus};

/// Sync state for a stored row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncState {
    /// In sync with the server.
    Clean,
    /// Locally modified; awaiting push.
    Dirty,
    /// Locally deleted; tombstone awaiting confirmation from the server.
    Deleted,
}

impl SyncState {
    /// Wire representation as stored in SQLite.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Clean => "clean",
            Self::Dirty => "dirty",
            Self::Deleted => "deleted",
        }
    }

    /// Parse from the SQLite representation.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "clean" => Some(Self::Clean),
            "dirty" => Some(Self::Dirty),
            "deleted" => Some(Self::Deleted),
            _ => None,
        }
    }
}

/// Stored task with sync metadata in addition to the domain fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTask {
    /// Domain task.
    pub task: Task,
    /// Which list this task belongs to.
    pub list_id: String,
    /// Local sync state.
    pub sync_state: SyncState,
    /// Local timestamp of the last edit (RFC 3339).
    pub local_updated: String,
    /// Pending operation when `sync_state` is `Dirty`. Stored as text:
    /// `"create" | "update" | "delete" | None`.
    pub pending_op: Option<String>,
}

/// Stored task list with sync metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredTaskList {
    /// Domain list.
    pub list: TaskList,
    /// Local sync state.
    pub sync_state: SyncState,
    /// Local timestamp of the last edit.
    pub local_updated: String,
}

/// Repository handle. Cheap to clone (wraps a pool).
#[derive(Clone)]
pub struct Store {
    pool: SqlitePool,
}

impl Store {
    /// Wrap an already-open pool.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    /// Underlying pool, exposed for advanced callers.
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Replace (or insert) a task-list row.
    pub async fn upsert_list(&self, list: &StoredTaskList) -> Result<(), StoreError> {
        sqlx::query(
            r"INSERT INTO task_lists (id, title, etag, updated, local_updated, sync_state)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                etag = excluded.etag,
                updated = excluded.updated,
                local_updated = excluded.local_updated,
                sync_state = excluded.sync_state",
        )
        .bind(&list.list.id)
        .bind(&list.list.title)
        .bind(&list.list.etag)
        .bind(&list.list.updated)
        .bind(&list.local_updated)
        .bind(list.sync_state.as_str())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// All known lists, in arbitrary order.
    pub async fn all_lists(&self) -> Result<Vec<StoredTaskList>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, title, etag, updated, local_updated, sync_state
              FROM task_lists
              WHERE sync_state != 'deleted'",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let sync_state_str: String = row.try_get("sync_state").map_err(StoreError::from)?;
            out.push(StoredTaskList {
                list: TaskList {
                    id: row.try_get("id").map_err(StoreError::from)?,
                    title: row.try_get("title").map_err(StoreError::from)?,
                    etag: row.try_get("etag").map_err(StoreError::from)?,
                    updated: row.try_get("updated").map_err(StoreError::from)?,
                },
                sync_state: SyncState::parse(&sync_state_str).ok_or_else(|| {
                    StoreError::Decode(format!("bad sync_state {sync_state_str}"))
                })?,
                local_updated: row.try_get("local_updated").map_err(StoreError::from)?,
            });
        }
        Ok(out)
    }

    /// Insert or replace a task row.
    pub async fn upsert_task(&self, t: &StoredTask) -> Result<(), StoreError> {
        sqlx::query(
            r"INSERT INTO tasks
              (id, list_id, parent_id, position, title, notes, status, due,
               completed_at, etag, updated, local_updated, sync_state, pending_op)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                list_id = excluded.list_id,
                parent_id = excluded.parent_id,
                position = excluded.position,
                title = excluded.title,
                notes = excluded.notes,
                status = excluded.status,
                due = excluded.due,
                completed_at = excluded.completed_at,
                etag = excluded.etag,
                updated = excluded.updated,
                local_updated = excluded.local_updated,
                sync_state = excluded.sync_state,
                pending_op = excluded.pending_op",
        )
        .bind(&t.task.id)
        .bind(&t.list_id)
        .bind(&t.task.parent)
        .bind(&t.task.position)
        .bind(&t.task.title)
        .bind(&t.task.notes)
        .bind(t.task.status.as_api_str())
        .bind(&t.task.due)
        .bind(&t.task.completed)
        .bind(&t.task.etag)
        .bind(&t.task.updated)
        .bind(&t.local_updated)
        .bind(t.sync_state.as_str())
        .bind(&t.pending_op)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// All tasks in `list_id`, ordered by `(parent_id NULLS FIRST, position)`.
    /// Caller folds into a tree if needed.
    pub async fn list_tasks(&self, list_id: &str) -> Result<Vec<StoredTask>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, list_id, parent_id, position, title, notes, status, due,
                     completed_at, etag, updated, local_updated, sync_state, pending_op
              FROM tasks
              WHERE list_id = ? AND sync_state != 'deleted'
              ORDER BY (parent_id IS NOT NULL), parent_id, position",
        )
        .bind(list_id)
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            out.push(stored_task_from_row(&row)?);
        }
        Ok(out)
    }

    /// All locally-dirty tasks awaiting push, ordered by pending_op priority
    /// (creates → updates → deletes).
    pub async fn drain_dirty(&self) -> Result<Vec<StoredTask>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, list_id, parent_id, position, title, notes, status, due,
                     completed_at, etag, updated, local_updated, sync_state, pending_op
              FROM tasks
              WHERE sync_state = 'dirty' OR sync_state = 'deleted'
              ORDER BY CASE pending_op
                WHEN 'create' THEN 0
                WHEN 'update' THEN 1
                WHEN 'delete' THEN 2
                ELSE 3 END,
                local_updated ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            out.push(stored_task_from_row(&row)?);
        }
        Ok(out)
    }

    /// Mark a task as in-sync (used after a successful push).
    pub async fn mark_task_clean(
        &self,
        id: &str,
        new_etag: Option<&str>,
        server_updated: &str,
    ) -> Result<(), StoreError> {
        sqlx::query(
            r"UPDATE tasks
              SET sync_state = 'clean', pending_op = NULL,
                  etag = COALESCE(?, etag),
                  updated = ?
              WHERE id = ?",
        )
        .bind(new_etag)
        .bind(server_updated)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Hard-delete a task row after the server has confirmed.
    pub async fn delete_task_hard(&self, id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM tasks WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Hard-delete a list row.
    pub async fn delete_list_hard(&self, id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM task_lists WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Record a local UUID → remote id remap and rewrite child references.
    /// Uses `PRAGMA defer_foreign_keys` so FK checks are evaluated only at commit.
    pub async fn remap_id(&self, local_id: &str, remote_id: &str) -> Result<(), StoreError> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("PRAGMA defer_foreign_keys = ON")
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT OR REPLACE INTO id_remap (local_id, remote_id) VALUES (?, ?)")
            .bind(local_id)
            .bind(remote_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE tasks SET id = ? WHERE id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE tasks SET parent_id = ? WHERE parent_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }
}

fn stored_task_from_row(row: &sqlx::sqlite::SqliteRow) -> Result<StoredTask, StoreError> {
    let status_str: String = row.try_get("status").map_err(StoreError::from)?;
    let status = TaskStatus::parse_api(&status_str)
        .ok_or_else(|| StoreError::Decode(format!("bad status {status_str}")))?;
    let sync_state_str: String = row.try_get("sync_state").map_err(StoreError::from)?;
    let sync_state = SyncState::parse(&sync_state_str)
        .ok_or_else(|| StoreError::Decode(format!("bad sync_state {sync_state_str}")))?;
    Ok(StoredTask {
        task: Task {
            id: row.try_get("id").map_err(StoreError::from)?,
            parent: row.try_get("parent_id").map_err(StoreError::from)?,
            position: row.try_get("position").map_err(StoreError::from)?,
            title: row.try_get("title").map_err(StoreError::from)?,
            notes: row.try_get("notes").map_err(StoreError::from)?,
            status,
            due: row.try_get("due").map_err(StoreError::from)?,
            completed: row.try_get("completed_at").map_err(StoreError::from)?,
            etag: row.try_get("etag").map_err(StoreError::from)?,
            updated: row.try_get("updated").map_err(StoreError::from)?,
        },
        list_id: row.try_get("list_id").map_err(StoreError::from)?,
        sync_state,
        local_updated: row.try_get("local_updated").map_err(StoreError::from)?,
        pending_op: row.try_get("pending_op").map_err(StoreError::from)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TaskStatus;
    use crate::store::open_memory;

    async fn fresh() -> Store {
        let pool = open_memory().await.unwrap();
        Store::new(pool)
    }

    fn list(id: &str) -> StoredTaskList {
        StoredTaskList {
            list: TaskList {
                id: id.into(),
                title: "Inbox".into(),
                etag: Some("e1".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
        }
    }

    fn task(id: &str, list_id: &str, parent: Option<&str>, position: &str) -> StoredTask {
        StoredTask {
            task: Task {
                id: id.into(),
                parent: parent.map(String::from),
                position: position.into(),
                title: format!("task {id}"),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: Some("e1".into()),
                updated: "2026-01-01T00:00:00Z".into(),
            },
            list_id: list_id.into(),
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
        }
    }

    #[tokio::test]
    async fn upsert_and_read_lists() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let all = s.all_lists().await.unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].list.id, "L1");
    }

    #[tokio::test]
    async fn upsert_task_and_list_in_order() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "00000000000001"))
            .await
            .unwrap();
        s.upsert_task(&task("T2", "L1", None, "00000000000002"))
            .await
            .unwrap();
        s.upsert_task(&task("T1a", "L1", Some("T1"), "00000000000001"))
            .await
            .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(rows.len(), 3);
        // Top-level first (parent IS NULL = 0), then subtask.
        assert_eq!(rows[0].task.id, "T1");
        assert_eq!(rows[1].task.id, "T2");
        assert_eq!(rows[2].task.id, "T1a");
        assert_eq!(rows[2].task.parent.as_deref(), Some("T1"));
    }

    #[tokio::test]
    async fn drain_dirty_orders_create_before_update_before_delete() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut a = task("a", "L1", None, "1");
        a.sync_state = SyncState::Dirty;
        a.pending_op = Some("update".into());
        let mut b = task("b", "L1", None, "2");
        b.sync_state = SyncState::Dirty;
        b.pending_op = Some("create".into());
        let mut c = task("c", "L1", None, "3");
        c.sync_state = SyncState::Deleted;
        c.pending_op = Some("delete".into());
        s.upsert_task(&a).await.unwrap();
        s.upsert_task(&b).await.unwrap();
        s.upsert_task(&c).await.unwrap();
        let drained = s.drain_dirty().await.unwrap();
        let ops: Vec<_> = drained
            .iter()
            .map(|t| t.pending_op.clone().unwrap())
            .collect();
        assert_eq!(ops, vec!["create", "update", "delete"]);
    }

    #[tokio::test]
    async fn mark_task_clean_updates_etag_and_clears_flags() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        s.upsert_task(&t).await.unwrap();
        s.mark_task_clean("T1", Some("e-new"), "2026-02-01T00:00:00Z")
            .await
            .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].sync_state, SyncState::Clean);
        assert_eq!(rows[0].task.etag.as_deref(), Some("e-new"));
        assert_eq!(rows[0].task.updated, "2026-02-01T00:00:00Z");
        assert!(rows[0].pending_op.is_none());
    }

    #[tokio::test]
    async fn remap_id_rewrites_self_and_children() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("local-1", "L1", None, "1"))
            .await
            .unwrap();
        s.upsert_task(&task("local-2", "L1", Some("local-1"), "1"))
            .await
            .unwrap();
        s.remap_id("local-1", "remote-1").await.unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        let parent = rows.iter().find(|r| r.task.id == "remote-1").unwrap();
        let child = rows.iter().find(|r| r.task.id == "local-2").unwrap();
        assert_eq!(child.task.parent.as_deref(), Some("remote-1"));
        assert!(parent.task.parent.is_none());
    }
}
