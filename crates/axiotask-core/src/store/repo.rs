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

/// A pending position/parent move to be pushed via the Tasks move API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingMove {
    /// Task being moved.
    pub task_id: String,
    /// List the task belongs to.
    pub list_id: String,
    /// Target parent (`None` = top-level).
    pub parent_id: Option<String>,
    /// Task it should follow (`None` = first position).
    pub previous_id: Option<String>,
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

    /// IDs of all dirty/deleted tasks (for skip-set computation).
    pub async fn dirty_ids(&self) -> Result<std::collections::HashSet<String>, StoreError> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT id FROM tasks WHERE sync_state = 'dirty' OR sync_state = 'deleted'",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    /// IDs of all clean tasks in a list (for ghost row detection).
    pub async fn clean_task_ids_for_list(
        &self,
        list_id: &str,
    ) -> Result<std::collections::HashSet<String>, StoreError> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT id FROM tasks WHERE list_id = ? AND sync_state = 'clean'",
        )
        .bind(list_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
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
                (parent_id IS NOT NULL),
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

    /// Record a pending position/parent move for a task (upsert).
    pub async fn record_move(
        &self,
        task_id: &str,
        list_id: &str,
        parent_id: Option<&str>,
        previous_id: Option<&str>,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO pending_moves (task_id, list_id, parent_id, previous_id)
             VALUES (?, ?, ?, ?)
             ON CONFLICT(task_id) DO UPDATE SET
               list_id = excluded.list_id,
               parent_id = excluded.parent_id,
               previous_id = excluded.previous_id",
        )
        .bind(task_id)
        .bind(list_id)
        .bind(parent_id)
        .bind(previous_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// All pending moves awaiting push.
    pub async fn pending_moves(&self) -> Result<Vec<PendingMove>, StoreError> {
        let rows = sqlx::query(
            "SELECT task_id, list_id, parent_id, previous_id FROM pending_moves",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            out.push(PendingMove {
                task_id: row.try_get("task_id")?,
                list_id: row.try_get("list_id")?,
                parent_id: row.try_get("parent_id")?,
                previous_id: row.try_get("previous_id")?,
            });
        }
        Ok(out)
    }

    /// Clear a pending move after it has been pushed (or remapped away).
    pub async fn clear_move(&self, task_id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM pending_moves WHERE task_id = ?")
            .bind(task_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Drop all local tasks and lists. Used for fresh sync.
    pub async fn clear_all(&self) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM tasks")
            .execute(&self.pool)
            .await?;
        sqlx::query("DELETE FROM task_lists")
            .execute(&self.pool)
            .await?;
        sqlx::query("DELETE FROM pending_moves")
            .execute(&self.pool)
            .await?;
        sqlx::query("DELETE FROM inflight_creates")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Record a sync run outcome.
    pub async fn write_sync_log(
        &self,
        pulled: u32,
        pushed: u32,
        conflicts: u32,
        duration_ms: u64,
        error: Option<String>,
    ) {
        let now = jiff::Zoned::now().strftime("%Y-%m-%dT%H:%M:%SZ").to_string();
        let _ = sqlx::query(
            "INSERT INTO sync_log (ran_at, duration_ms, pulled, pushed, conflicts, error) VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(&now)
        .bind(i64::try_from(duration_ms).unwrap_or(i64::MAX))
        .bind(i64::from(pulled))
        .bind(i64::from(pushed))
        .bind(i64::from(conflicts))
        .bind(&error)
        .execute(&self.pool)
        .await;

        // Bound growth: keep only the most recent 500 entries.
        let _ = sqlx::query(
            "DELETE FROM sync_log WHERE id NOT IN
                 (SELECT id FROM sync_log ORDER BY id DESC LIMIT 500)",
        )
        .execute(&self.pool)
        .await;
    }

    /// Atomically finalize a pushed create: rewrite the local id to the
    /// server id (incl. children + move intents) AND mark the row clean,
    /// in a single transaction. This removes the half-applied window where
    /// a crash between remap and mark-clean would leave a remapped row still
    /// flagged `pending_op='create'` (which would re-insert → duplicate).
    pub async fn finish_create(
        &self,
        local_id: &str,
        remote_id: &str,
        etag: Option<&str>,
        server_updated: &str,
    ) -> Result<(), StoreError> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("PRAGMA defer_foreign_keys = ON")
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
        sqlx::query("UPDATE pending_moves SET task_id = ? WHERE task_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE pending_moves SET parent_id = ? WHERE parent_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE pending_moves SET previous_id = ? WHERE previous_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "UPDATE tasks SET sync_state = 'clean', pending_op = NULL,
                 etag = COALESCE(?, etag), updated = ? WHERE id = ?",
        )
        .bind(etag)
        .bind(server_updated)
        .bind(remote_id)
        .execute(&mut *tx)
        .await?;
        // Clear the in-flight create marker in the same transaction.
        sqlx::query("DELETE FROM inflight_creates WHERE local_id = ?")
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(())
    }

    /// Durably mark a create as in-flight before calling the (non-idempotent)
    /// server insert. Cleared by [`finish_create`] on success.
    pub async fn record_inflight_create(
        &self,
        local_id: &str,
        list_id: &str,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT OR REPLACE INTO inflight_creates (local_id, list_id) VALUES (?, ?)",
        )
        .bind(local_id)
        .bind(list_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// All in-flight create markers (non-empty only after a crash mid-create).
    pub async fn inflight_creates(&self) -> Result<Vec<(String, String)>, StoreError> {
        let rows: Vec<(String, String)> =
            sqlx::query_as("SELECT local_id, list_id FROM inflight_creates")
                .fetch_all(&self.pool)
                .await?;
        Ok(rows)
    }

    /// Clear an in-flight marker without finalizing (e.g. the insert never
    /// reached the server, so the create will be retried normally).
    pub async fn clear_inflight_create(&self, local_id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM inflight_creates WHERE local_id = ?")
            .bind(local_id)
            .execute(&self.pool)
            .await?;
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
    async fn finish_create_rewrites_self_and_children_and_marks_clean() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut p = task("local-1", "L1", None, "1");
        p.sync_state = SyncState::Dirty;
        p.pending_op = Some("create".into());
        s.upsert_task(&p).await.unwrap();
        s.upsert_task(&task("local-2", "L1", Some("local-1"), "1"))
            .await
            .unwrap();
        s.finish_create("local-1", "remote-1", Some("e9"), "2026-02-01T00:00:00Z")
            .await
            .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        let parent = rows.iter().find(|r| r.task.id == "remote-1").unwrap();
        let child = rows.iter().find(|r| r.task.id == "local-2").unwrap();
        assert_eq!(child.task.parent.as_deref(), Some("remote-1"));
        assert!(parent.task.parent.is_none());
        // Marked clean atomically.
        assert_eq!(parent.sync_state, SyncState::Clean);
        assert!(parent.pending_op.is_none());
        assert_eq!(parent.task.etag.as_deref(), Some("e9"));
    }

    #[tokio::test]
    async fn delete_task_hard_removes_row() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        assert_eq!(s.list_tasks("L1").await.unwrap().len(), 1);
        s.delete_task_hard("T1").await.unwrap();
        assert!(s.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn delete_list_hard_removes_row() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        assert_eq!(s.all_lists().await.unwrap().len(), 1);
        s.delete_list_hard("L1").await.unwrap();
        assert!(s.all_lists().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_tasks_excludes_deleted() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Deleted;
        t.pending_op = Some("delete".into());
        s.upsert_task(&t).await.unwrap();
        assert!(s.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn all_lists_excludes_deleted() {
        let s = fresh().await;
        let mut l = list("L1");
        l.sync_state = SyncState::Deleted;
        s.upsert_list(&l).await.unwrap();
        assert!(s.all_lists().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn sync_state_round_trips() {
        assert_eq!(SyncState::parse(SyncState::Clean.as_str()), Some(SyncState::Clean));
        assert_eq!(SyncState::parse(SyncState::Dirty.as_str()), Some(SyncState::Dirty));
        assert_eq!(SyncState::parse(SyncState::Deleted.as_str()), Some(SyncState::Deleted));
        assert_eq!(SyncState::parse("unknown"), None);
    }

    #[tokio::test]
    async fn upsert_task_overwrites_existing() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        let mut updated = task("T1", "L1", None, "1");
        updated.task.title = "renamed".into();
        updated.sync_state = SyncState::Dirty;
        updated.pending_op = Some("update".into());
        s.upsert_task(&updated).await.unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].task.title, "renamed");
        assert_eq!(rows[0].sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn clear_all_removes_everything() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.upsert_task(&task("T2", "L1", None, "2")).await.unwrap();
        s.clear_all().await.unwrap();
        assert!(s.all_lists().await.unwrap().is_empty());
        assert!(s.list_tasks("L1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn record_and_read_pending_move() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.upsert_task(&task("P1", "L1", None, "2")).await.unwrap();
        s.upsert_task(&task("T0", "L1", None, "3")).await.unwrap();
        s.record_move("T1", "L1", Some("P1"), Some("T0")).await.unwrap();
        let moves = s.pending_moves().await.unwrap();
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0].task_id, "T1");
        assert_eq!(moves[0].parent_id.as_deref(), Some("P1"));
        assert_eq!(moves[0].previous_id.as_deref(), Some("T0"));
    }

    #[tokio::test]
    async fn record_move_upserts_same_task() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_move("T1", "L1", None, Some("A")).await.unwrap();
        s.record_move("T1", "L1", None, Some("B")).await.unwrap();
        let moves = s.pending_moves().await.unwrap();
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0].previous_id.as_deref(), Some("B"));
    }

    #[tokio::test]
    async fn clear_move_removes_it() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_move("T1", "L1", None, None).await.unwrap();
        s.clear_move("T1").await.unwrap();
        assert!(s.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn clear_all_removes_pending_moves() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_move("T1", "L1", None, None).await.unwrap();
        s.clear_all().await.unwrap();
        assert!(s.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn deleting_task_cascades_pending_move() {
        // FK integrity: a hard-deleted task must not leave an orphan move.
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_move("T1", "L1", None, None).await.unwrap();
        s.delete_task_hard("T1").await.unwrap();
        assert!(s.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn inflight_create_record_and_list() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_inflight_create("T1", "L1").await.unwrap();
        let inflight = s.inflight_creates().await.unwrap();
        assert_eq!(inflight, vec![("T1".into(), "L1".into())]);
    }

    #[tokio::test]
    async fn finish_create_clears_inflight_marker() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("local-1", "L1", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("create".into());
        s.upsert_task(&t).await.unwrap();
        s.record_inflight_create("local-1", "L1").await.unwrap();
        s.finish_create("local-1", "remote-1", Some("e1"), "2026-02-01T00:00:00Z").await.unwrap();
        assert!(s.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn deleting_task_cascades_inflight_marker() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.record_inflight_create("T1", "L1").await.unwrap();
        s.delete_task_hard("T1").await.unwrap();
        assert!(s.inflight_creates().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn finish_create_rewrites_pending_move_task_id() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("local-1", "L1", None, "1")).await.unwrap();
        s.record_move("local-1", "L1", None, Some("other")).await.unwrap();
        s.finish_create("local-1", "remote-1", None, "2026-02-01T00:00:00Z").await.unwrap();
        let moves = s.pending_moves().await.unwrap();
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0].task_id, "remote-1");
    }
}
