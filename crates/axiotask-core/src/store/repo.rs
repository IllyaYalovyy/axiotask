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
    /// Pending push operation: `"create" | "update" | "delete"` or `None`.
    pub pending_op: Option<String>,
    /// Local-only list: never pushed to, pulled from, or reconciled against
    /// Google. Excluded from ghost detection and from all push paths.
    pub local_only: bool,
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
            r"INSERT INTO task_lists (id, title, etag, updated, local_updated, sync_state, pending_op, local_only)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                etag = excluded.etag,
                updated = excluded.updated,
                local_updated = excluded.local_updated,
                sync_state = excluded.sync_state,
                pending_op = excluded.pending_op,
                local_only = excluded.local_only",
        )
        .bind(&list.list.id)
        .bind(&list.list.title)
        .bind(&list.list.etag)
        .bind(&list.list.updated)
        .bind(&list.local_updated)
        .bind(list.sync_state.as_str())
        .bind(&list.pending_op)
        .bind(list.local_only)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Upsert a list pulled from the server without clobbering a locally
    /// dirty/deleted one (race-safe, mirrors `upsert_remote_task`).
    pub async fn upsert_remote_list(&self, list: &StoredTaskList) -> Result<(), StoreError> {
        sqlx::query(
            r"INSERT INTO task_lists (id, title, etag, updated, local_updated, sync_state, pending_op, local_only)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                etag = excluded.etag,
                updated = excluded.updated,
                local_updated = excluded.local_updated,
                sync_state = excluded.sync_state,
                pending_op = excluded.pending_op
              WHERE task_lists.sync_state = 'clean'",
        )
        .bind(&list.list.id)
        .bind(&list.list.title)
        .bind(&list.list.etag)
        .bind(&list.list.updated)
        .bind(&list.local_updated)
        .bind(list.sync_state.as_str())
        .bind(&list.pending_op)
        .bind(list.local_only)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Hard-delete a list only if still clean (ghost detection must not remove
    /// a list a live rename/delete just dirtied).
    pub async fn delete_list_hard_if_clean(&self, id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM task_lists WHERE id = ? AND sync_state = 'clean'")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// All known lists, in arbitrary order.
    pub async fn all_lists(&self) -> Result<Vec<StoredTaskList>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, title, etag, updated, local_updated, sync_state, pending_op, local_only
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
                pending_op: row.try_get("pending_op").map_err(StoreError::from)?,
                local_only: row.try_get("local_only").map_err(StoreError::from)?,
            });
        }
        Ok(out)
    }

    /// Insert or replace a task row.
    pub async fn upsert_task(&self, t: &StoredTask) -> Result<(), StoreError> {
        sqlx::query(
            r"INSERT INTO tasks
              (id, list_id, parent_id, position, title, notes, status, due,
               completed_at, etag, updated, local_updated, sync_state, pending_op, web_view_link)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                pending_op = excluded.pending_op,
                web_view_link = excluded.web_view_link",
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
        .bind(&t.task.web_view_link)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Upsert a row pulled from the server, but NEVER clobber a row that is
    /// locally dirty/deleted. Closes the read-then-write race where a live UI
    /// edit marks a task dirty after pull's skip-set snapshot but before this
    /// write — the `WHERE sync_state = 'clean'` makes skip-if-dirty atomic with
    /// the update, so the local edit (and its dirty flag) survive.
    pub async fn upsert_remote_task(&self, t: &StoredTask) -> Result<(), StoreError> {
        sqlx::query(
            r"INSERT INTO tasks
              (id, list_id, parent_id, position, title, notes, status, due,
               completed_at, etag, updated, local_updated, sync_state, pending_op, web_view_link)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                pending_op = excluded.pending_op,
                web_view_link = excluded.web_view_link
              WHERE tasks.sync_state = 'clean'",
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
        .bind(&t.task.web_view_link)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Remove a row the server no longer has (ghost detection), only if it is
    /// still clean — a live edit that re-dirtied it cancels the removal.
    ///
    /// The rows in its subtree the server has never seen are promoted to
    /// top-level first, in the same transaction: `ON DELETE CASCADE` would
    /// otherwise take an unpushed subtask down with a parent another device
    /// deleted (RFC-009 D3, P2). Returns whether the row was removed.
    pub async fn remove_ghost_task(&self, id: &str) -> Result<bool, StoreError> {
        let mut tx = self.pool.begin().await?;
        let still_clean: Option<(i64,)> =
            sqlx::query_as("SELECT 1 FROM tasks WHERE id = ? AND sync_state = 'clean'")
                .bind(id)
                .fetch_optional(&mut *tx)
                .await?;
        if still_clean.is_none() {
            tx.rollback().await?;
            return Ok(false);
        }
        sqlx::query(
            "UPDATE tasks SET parent_id = NULL
             WHERE parent_id = ? AND etag IS NULL AND sync_state != 'deleted'",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
        let res = sqlx::query("DELETE FROM tasks WHERE id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(res.rows_affected() > 0)
    }

    /// Detach the rows the server has never seen from a parent that a REMOTE
    /// event is about to remove (RFC-009 §G / D3, P2).
    ///
    /// `parent_id REFERENCES tasks(id) ON DELETE CASCADE` would otherwise take
    /// an unpushed subtask down with a parent that was deleted on another
    /// device — destroying work the server never saw, and the row's insert
    /// would 400 forever on the dead parent id anyway. Promoting it to
    /// top-level keeps it, still queued, in the same list.
    ///
    /// Deliberately NOT used for the user's own delete: that cascade is the
    /// point (invariant #3, P4), so tombstoned rows are left alone here and
    /// only remote-driven removals call this.
    ///
    /// Returns the number of rows promoted.
    pub async fn promote_unpushed_children(&self, parent_id: &str) -> Result<u64, StoreError> {
        let res = sqlx::query(
            "UPDATE tasks SET parent_id = NULL
             WHERE parent_id = ? AND etag IS NULL AND sync_state != 'deleted'",
        )
        .bind(parent_id)
        .execute(&self.pool)
        .await?;
        Ok(res.rows_affected())
    }

    /// Move the rows the server has never seen out of a list that a REMOTE
    /// delete is about to remove, into `to_list` (RFC-009 §G3 / D2, P2).
    ///
    /// Rows *with* an etag stay behind and die with the list (P1/P4). A row
    /// whose parent stays behind is promoted to top-level, so an unpushed
    /// subtree re-homes intact while an unpushed subtask of a synced parent
    /// survives as a top-level task rather than being cascaded away.
    /// Tombstones are left behind too — the user already deleted them.
    ///
    /// Returns the number of rows re-homed.
    pub async fn rehome_unpushed_tasks(
        &self,
        from_list: &str,
        to_list: &str,
    ) -> Result<u64, StoreError> {
        let mut tx = self.pool.begin().await?;
        // Detach first: "parent is re-homing too" must be evaluated while the
        // rows are all still in the dying list.
        sqlx::query(
            "UPDATE tasks SET parent_id = NULL
             WHERE list_id = ?1 AND etag IS NULL AND sync_state != 'deleted'
               AND parent_id IS NOT NULL
               AND parent_id NOT IN (
                   SELECT id FROM tasks
                   WHERE list_id = ?1 AND etag IS NULL AND sync_state != 'deleted')",
        )
        .bind(from_list)
        .execute(&mut *tx)
        .await?;
        let res = sqlx::query(
            "UPDATE tasks SET list_id = ?2
             WHERE list_id = ?1 AND etag IS NULL AND sync_state != 'deleted'",
        )
        .bind(from_list)
        .bind(to_list)
        .execute(&mut *tx)
        .await?;
        // An in-flight marker is scoped to a list: follow the row, or the
        // list's FK cascade would drop it and a committed-but-unacked insert
        // could be re-inserted as a duplicate (P8).
        sqlx::query("UPDATE inflight_creates SET list_id = ?2 WHERE list_id = ?1 AND local_id IN (SELECT id FROM tasks WHERE list_id = ?2)")
            .bind(from_list)
            .bind(to_list)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(res.rows_affected())
    }

    /// Whether a list still holds rows the server has never seen (D2: such a
    /// list may not be dropped until they have somewhere to go).
    pub async fn has_unpushed_tasks(&self, list_id: &str) -> Result<bool, StoreError> {
        let row: Option<(i64,)> = sqlx::query_as(
            "SELECT 1 FROM tasks
             WHERE list_id = ? AND etag IS NULL AND sync_state != 'deleted' LIMIT 1",
        )
        .bind(list_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// All tasks in `list_id`, ordered by `(parent_id NULLS FIRST, position)`.
    /// Caller folds into a tree if needed.
    pub async fn list_tasks(&self, list_id: &str) -> Result<Vec<StoredTask>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, list_id, parent_id, position, title, notes, status, due,
                     completed_at, etag, updated, local_updated, sync_state, pending_op, web_view_link
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
    /// Fetch a single task by id regardless of sync_state (incl. tombstones).
    pub async fn find_task_any(&self, id: &str) -> Result<Option<StoredTask>, StoreError> {
        let row = sqlx::query(
            r"SELECT id, list_id, parent_id, position, title, notes, status, due,
                     completed_at, etag, updated, local_updated, sync_state, pending_op, web_view_link
              FROM tasks WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        row.map(|r| stored_task_from_row(&r)).transpose()
    }

    /// Ids of all locally dirty or deleted tasks (the pull skip-set).
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
        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM tasks WHERE list_id = ? AND sync_state = 'clean'")
                .bind(list_id)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    /// All locally-dirty tasks awaiting push, ordered by pending_op priority
    /// (creates → updates → deletes). Tasks in local-only lists are excluded:
    /// their list does not exist on the server, so they are never pushed.
    pub async fn drain_dirty(&self) -> Result<Vec<StoredTask>, StoreError> {
        let rows = sqlx::query(
            r"SELECT t.id, t.list_id, t.parent_id, t.position, t.title, t.notes, t.status, t.due,
                     t.completed_at, t.etag, t.updated, t.local_updated, t.sync_state, t.pending_op, t.web_view_link
              FROM tasks t
              JOIN task_lists l ON l.id = t.list_id
              WHERE (t.sync_state = 'dirty' OR t.sync_state = 'deleted') AND l.local_only = 0
              ORDER BY CASE t.pending_op
                WHEN 'create' THEN 0
                WHEN 'update' THEN 1
                WHEN 'delete' THEN 2
                ELSE 3 END,
                (t.parent_id IS NOT NULL),
                t.local_updated ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            out.push(stored_task_from_row(&row)?);
        }
        Ok(out)
    }

    /// Mark a task as in-sync after a successful push — but only if the row's
    /// `local_updated` still equals the snapshot taken when the push drained it.
    ///
    /// Without the guard, an edit made while the push's HTTP request is in
    /// flight would have its dirty flag wiped by the push completing, and that
    /// newer edit would silently never sync (a lost update). When the guard
    /// misses, the row stays dirty — but the fresh etag is adopted either way,
    /// so the re-push of the newer content succeeds instead of 412ing.
    pub async fn mark_task_clean(
        &self,
        id: &str,
        new_etag: Option<&str>,
        server_updated: &str,
        expected_local_updated: &str,
    ) -> Result<(), StoreError> {
        sqlx::query(
            r"UPDATE tasks
              SET etag = COALESCE(?, etag),
                  updated = ?,
                  sync_state = CASE WHEN local_updated = ? THEN 'clean' ELSE sync_state END,
                  pending_op = CASE WHEN local_updated = ? THEN NULL ELSE pending_op END
              WHERE id = ?",
        )
        .bind(new_etag)
        .bind(server_updated)
        .bind(expected_local_updated)
        .bind(expected_local_updated)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Adopt the full task the server returned from a successful push.
    ///
    /// The response is what the server ACTUALLY stored, and it can differ from
    /// what we sent: it assigns `position` on insert (locally we'd otherwise
    /// keep the placeholder zeros forever, since the matching etag makes pull
    /// skip the row), sets the `completed` timestamp, normalizes `due`, and can
    /// silently coerce fields (re-opening a subtask of a completed parent is
    /// accepted with 200 but ignored — verified live). Discarding the body
    /// creates permanent drift that no later pull corrects.
    ///
    /// Same race guard as [`mark_task_clean`]: content + clean only when
    /// `local_updated` still equals the drained snapshot; a mid-flight re-edit
    /// keeps its content and dirty flag, adopting just the fresh etag.
    pub async fn apply_pushed_task(
        &self,
        remote: &Task,
        expected_local_updated: &str,
    ) -> Result<(), StoreError> {
        sqlx::query(
            r"UPDATE tasks
              SET etag = COALESCE(?1, etag),
                  updated = ?2,
                  parent_id    = CASE WHEN local_updated = ?3 AND NOT EXISTS
                                   (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id)
                                 THEN ?4 ELSE parent_id END,
                  position     = CASE WHEN local_updated = ?3 AND NOT EXISTS
                                   (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id)
                                 THEN ?5 ELSE position END,
                  title        = CASE WHEN local_updated = ?3 THEN ?6  ELSE title        END,
                  notes        = CASE WHEN local_updated = ?3 THEN ?7  ELSE notes        END,
                  status       = CASE WHEN local_updated = ?3 THEN ?8  ELSE status       END,
                  due          = CASE WHEN local_updated = ?3 THEN ?9  ELSE due          END,
                  completed_at = CASE WHEN local_updated = ?3 THEN ?10 ELSE completed_at END,
                  web_view_link = COALESCE(?11, web_view_link),
                  sync_state = CASE WHEN local_updated = ?3 THEN 'clean' ELSE sync_state END,
                  pending_op = CASE WHEN local_updated = ?3 THEN NULL ELSE pending_op END
              WHERE id = ?12",
        )
        .bind(remote.etag.as_deref()) // ?1
        .bind(&remote.updated) // ?2
        .bind(expected_local_updated) // ?3
        .bind(&remote.parent) // ?4
        .bind(&remote.position) // ?5
        .bind(&remote.title) // ?6
        .bind(&remote.notes) // ?7
        .bind(remote.status.as_api_str()) // ?8
        .bind(&remote.due) // ?9
        .bind(&remote.completed) // ?10
        .bind(&remote.web_view_link) // ?11
        .bind(&remote.id) // ?12
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Adopt a fresh etag/updated from the server WITHOUT touching sync_state
    /// or pending_op. Used after a move push: the move endpoint returns a new
    /// etag, but the row may carry an unrelated pending content edit whose
    /// dirty flag must survive.
    pub async fn refresh_task_meta(
        &self,
        id: &str,
        new_etag: Option<&str>,
        server_updated: &str,
    ) -> Result<(), StoreError> {
        sqlx::query("UPDATE tasks SET etag = COALESCE(?, etag), updated = ? WHERE id = ?")
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

    /// All locally-dirty/deleted lists awaiting push, creates before
    /// updates before deletes. Local-only lists are excluded: they are never
    /// pushed to the server.
    pub async fn drain_dirty_lists(&self) -> Result<Vec<StoredTaskList>, StoreError> {
        let rows = sqlx::query(
            r"SELECT id, title, etag, updated, local_updated, sync_state, pending_op, local_only
              FROM task_lists
              WHERE (sync_state = 'dirty' OR sync_state = 'deleted') AND local_only = 0
              ORDER BY CASE pending_op
                WHEN 'create' THEN 0 WHEN 'update' THEN 1 WHEN 'delete' THEN 2 ELSE 3 END,
                local_updated ASC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let s: String = row.try_get("sync_state")?;
            out.push(StoredTaskList {
                list: TaskList {
                    id: row.try_get("id")?,
                    title: row.try_get("title")?,
                    etag: row.try_get("etag")?,
                    updated: row.try_get("updated")?,
                },
                sync_state: SyncState::parse(&s)
                    .ok_or_else(|| StoreError::Decode(format!("bad sync_state {s}")))?,
                local_updated: row.try_get("local_updated")?,
                pending_op: row.try_get("pending_op")?,
                local_only: row.try_get("local_only")?,
            });
        }
        Ok(out)
    }

    /// Mark a list in-sync after a successful push.
    pub async fn mark_list_clean(
        &self,
        id: &str,
        new_etag: Option<&str>,
        server_updated: &str,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "UPDATE task_lists SET sync_state = 'clean', pending_op = NULL,
                 etag = COALESCE(?, etag), updated = ? WHERE id = ?",
        )
        .bind(new_etag)
        .bind(server_updated)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Ids of all clean lists eligible for ghost detection. Local-only lists
    /// are excluded: they are absent from the server by design, so they must
    /// never be treated as remotely-deleted ghosts.
    pub async fn clean_list_ids(&self) -> Result<std::collections::HashSet<String>, StoreError> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT id FROM task_lists WHERE sync_state = 'clean' AND local_only = 0",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    /// Remap a local list UUID to its server id, rewriting the list row and
    /// every task's `list_id` (and pending_moves) in one transaction.
    pub async fn remap_list_id(
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
        sqlx::query("UPDATE task_lists SET id = ? WHERE id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE tasks SET list_id = ? WHERE list_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE pending_moves SET list_id = ? WHERE list_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE inflight_creates SET list_id = ? WHERE list_id = ?")
            .bind(remote_id)
            .bind(local_id)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "UPDATE task_lists SET sync_state = 'clean', pending_op = NULL,
                 etag = COALESCE(?, etag), updated = ? WHERE id = ?",
        )
        .bind(etag)
        .bind(server_updated)
        .bind(remote_id)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
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
        let rows =
            sqlx::query("SELECT task_id, list_id, parent_id, previous_id FROM pending_moves")
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

    /// Number of local changes awaiting push: dirty/deleted tasks and lists
    /// plus recorded position moves, excluding local-only lists (which never
    /// sync). Read-only — unlike `drain_*`, it does not consume the queue, so
    /// the UI can display "N changes pending" without disturbing sync state.
    pub async fn pending_push_count(&self) -> Result<u32, StoreError> {
        let tasks: (i64,) = sqlx::query_as(
            r"SELECT COUNT(*) FROM tasks t
              JOIN task_lists l ON l.id = t.list_id
              WHERE (t.sync_state = 'dirty' OR t.sync_state = 'deleted') AND l.local_only = 0",
        )
        .fetch_one(&self.pool)
        .await?;
        let lists: (i64,) = sqlx::query_as(
            r"SELECT COUNT(*) FROM task_lists
              WHERE (sync_state = 'dirty' OR sync_state = 'deleted') AND local_only = 0",
        )
        .fetch_one(&self.pool)
        .await?;
        let moves: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM pending_moves")
            .fetch_one(&self.pool)
            .await?;
        Ok((tasks.0 + lists.0 + moves.0) as u32)
    }

    /// Drop all local tasks and lists. Used for fresh sync.
    pub async fn clear_all(&self) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM tasks").execute(&self.pool).await?;
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

    /// Drop all *synced* lists and their tasks, preserving local-only lists.
    ///
    /// Fresh sync rebuilds the cache from Google, which is the source of truth
    /// for synced data. Local-only lists exist nowhere but this device, so they
    /// must survive. Relies on `ON DELETE CASCADE` to clear each removed list's
    /// tasks, pending moves, and in-flight create markers.
    pub async fn clear_synced(&self) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM task_lists WHERE local_only = 0")
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
        let now = crate::dates::now_utc_string();
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
        expected_local_updated: &str,
        server_position: Option<&str>,
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
        // Mark clean only if the row wasn't re-edited while the insert was in
        // flight. A re-edited row keeps its dirty flag but its pending op is
        // rewritten create→update: the task now exists remotely under the new
        // id, so re-running it as a create would insert a duplicate.
        //
        // Also adopt the server-assigned position (guarded like the rest, and
        // skipped when a pending move exists — the move will supersede it).
        // Without this the row keeps its local placeholder position forever:
        // the adopted etag makes every future pull skip the row.
        sqlx::query(
            "UPDATE tasks SET
                 etag = COALESCE(?1, etag),
                 updated = ?2,
                 position = CASE WHEN local_updated = ?3 AND ?4 IS NOT NULL AND NOT EXISTS
                              (SELECT 1 FROM pending_moves pm WHERE pm.task_id = tasks.id)
                            THEN ?4 ELSE position END,
                 sync_state = CASE WHEN local_updated = ?3 THEN 'clean' ELSE sync_state END,
                 pending_op = CASE WHEN local_updated = ?3 THEN NULL ELSE 'update' END
             WHERE id = ?5",
        )
        .bind(etag)
        .bind(server_updated)
        .bind(expected_local_updated)
        .bind(server_position)
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
        sqlx::query("INSERT OR REPLACE INTO inflight_creates (local_id, list_id) VALUES (?, ?)")
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
            web_view_link: row.try_get("web_view_link").map_err(StoreError::from)?,
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
            pending_op: None,
            local_only: false,
        }
    }

    fn local_list(id: &str) -> StoredTaskList {
        StoredTaskList {
            list: TaskList {
                id: id.into(),
                title: "Scratch".into(),
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
            local_only: true,
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
                web_view_link: None,
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
    async fn local_only_flag_round_trips() {
        let s = fresh().await;
        s.upsert_list(&local_list("L1")).await.unwrap();
        s.upsert_list(&list("L2")).await.unwrap();
        let all = s.all_lists().await.unwrap();
        let l1 = all.iter().find(|l| l.list.id == "L1").unwrap();
        let l2 = all.iter().find(|l| l.list.id == "L2").unwrap();
        assert!(l1.local_only, "local-only flag persisted");
        assert!(!l2.local_only, "synced list is not local-only");
    }

    #[tokio::test]
    async fn clean_list_ids_excludes_local_only() {
        let s = fresh().await;
        s.upsert_list(&local_list("LOCAL")).await.unwrap();
        s.upsert_list(&list("SYNCED")).await.unwrap();
        let ids = s.clean_list_ids().await.unwrap();
        // Ghost detection must never see a local-only list, or it would delete
        // it the moment it's absent from the server (which is always).
        assert!(
            !ids.contains("LOCAL"),
            "local-only list excluded from ghost set"
        );
        assert!(ids.contains("SYNCED"));
    }

    #[tokio::test]
    async fn drain_dirty_lists_excludes_local_only() {
        let s = fresh().await;
        // A local-only list can never be in a push-pending state, but even if
        // marked dirty it must never be drained for push.
        let mut l = local_list("LOCAL");
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("create".into());
        s.upsert_list(&l).await.unwrap();
        let drained = s.drain_dirty_lists().await.unwrap();
        assert!(drained.is_empty(), "local-only list never pushed");
    }

    #[tokio::test]
    async fn drain_dirty_excludes_tasks_in_local_only_lists() {
        let s = fresh().await;
        s.upsert_list(&local_list("LOCAL")).await.unwrap();
        s.upsert_list(&list("SYNCED")).await.unwrap();
        let mut local_task = task("LT", "LOCAL", None, "1");
        local_task.sync_state = SyncState::Dirty;
        local_task.pending_op = Some("create".into());
        let mut synced_task = task("ST", "SYNCED", None, "1");
        synced_task.sync_state = SyncState::Dirty;
        synced_task.pending_op = Some("create".into());
        s.upsert_task(&local_task).await.unwrap();
        s.upsert_task(&synced_task).await.unwrap();
        let drained = s.drain_dirty().await.unwrap();
        let ids: Vec<_> = drained.iter().map(|t| t.task.id.clone()).collect();
        assert_eq!(ids, vec!["ST"], "only the synced list's task is pushed");
    }

    #[tokio::test]
    async fn pending_push_count_sums_tasks_lists_moves_excluding_local_only() {
        let s = fresh().await;
        s.upsert_list(&local_list("LOCAL")).await.unwrap();
        s.upsert_list(&list("SYNCED")).await.unwrap();
        assert_eq!(
            s.pending_push_count().await.unwrap(),
            0,
            "all clean to start"
        );

        // Dirty task in synced list → counts.
        let mut t = task("T1", "SYNCED", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        s.upsert_task(&t).await.unwrap();
        // Dirty task in local-only list → must NOT count.
        let mut lt = task("LT", "LOCAL", None, "1");
        lt.sync_state = SyncState::Dirty;
        lt.pending_op = Some("create".into());
        s.upsert_task(&lt).await.unwrap();
        // A dirty list and a recorded move → each counts.
        let mut dl = list("SYNCED");
        dl.list.title = "renamed".into();
        dl.sync_state = SyncState::Dirty;
        dl.pending_op = Some("update".into());
        s.upsert_list(&dl).await.unwrap();
        s.record_move("T1", "SYNCED", None, None).await.unwrap();

        // 1 task + 1 list + 1 move = 3; the local-only task is excluded.
        assert_eq!(s.pending_push_count().await.unwrap(), 3);
    }

    #[tokio::test]
    async fn upsert_remote_list_does_not_clobber_dirty() {
        let s = fresh().await;
        let mut local = list("L1");
        local.list.title = "My Rename".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        s.upsert_list(&local).await.unwrap();

        let mut remote = list("L1");
        remote.list.title = "Server Name".into();
        remote.sync_state = SyncState::Clean;
        remote.pending_op = None;
        s.upsert_remote_list(&remote).await.unwrap();

        let l = s
            .all_lists()
            .await
            .unwrap()
            .into_iter()
            .find(|l| l.list.id == "L1")
            .unwrap();
        assert_eq!(l.list.title, "My Rename", "local rename preserved");
        assert_eq!(l.sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn delete_list_hard_if_clean_spares_dirty() {
        let s = fresh().await;
        let mut l = list("L1");
        l.sync_state = SyncState::Dirty;
        l.pending_op = Some("update".into());
        s.upsert_list(&l).await.unwrap();
        s.delete_list_hard_if_clean("L1").await.unwrap();
        assert_eq!(s.all_lists().await.unwrap().len(), 1, "dirty list spared");
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
        s.mark_task_clean(
            "T1",
            Some("e-new"),
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
        )
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
    async fn mark_task_clean_stale_snapshot_keeps_dirty_but_adopts_etag() {
        // The lost-update race: the row was re-edited while its push was in
        // flight, so the drained local_updated no longer matches. The dirty
        // flag must survive (the newer edit still needs to push), but the
        // fresh etag is adopted so that re-push won't 412.
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        t.local_updated = "2026-01-01T00:00:05Z".into(); // re-edited: newer than drain
        s.upsert_task(&t).await.unwrap();
        s.mark_task_clean(
            "T1",
            Some("e-new"),
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
        )
        .await
        .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(
            rows[0].sync_state,
            SyncState::Dirty,
            "newer edit must stay queued"
        );
        assert_eq!(rows[0].pending_op.as_deref(), Some("update"));
        assert_eq!(
            rows[0].task.etag.as_deref(),
            Some("e-new"),
            "fresh etag adopted"
        );
    }

    #[tokio::test]
    async fn refresh_task_meta_never_touches_sync_state() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        s.upsert_task(&t).await.unwrap();
        s.refresh_task_meta("T1", Some("e-move"), "2026-02-01T00:00:00Z")
            .await
            .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(rows[0].sync_state, SyncState::Dirty);
        assert_eq!(rows[0].pending_op.as_deref(), Some("update"));
        assert_eq!(rows[0].task.etag.as_deref(), Some("e-move"));
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
        s.finish_create(
            "local-1",
            "remote-1",
            Some("e9"),
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
            None,
        )
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
    async fn finish_create_reedited_row_stays_dirty_as_update() {
        // Re-edited while the insert was in flight: the remap must still land
        // (the task exists remotely now) but the row keeps its dirty flag and
        // flips create→update, so the newer content pushes against the remote
        // id instead of inserting a duplicate.
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut p = task("local-1", "L1", None, "1");
        p.task.etag = None;
        p.task.title = "typed more while pushing".into();
        p.sync_state = SyncState::Dirty;
        p.pending_op = Some("create".into());
        p.local_updated = "2026-01-01T00:00:07Z".into(); // newer than the drain snapshot
        s.upsert_task(&p).await.unwrap();
        s.finish_create(
            "local-1",
            "remote-1",
            Some("e9"),
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
            None,
        )
        .await
        .unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        let row = rows
            .iter()
            .find(|r| r.task.id == "remote-1")
            .expect("remapped");
        assert_eq!(
            row.sync_state,
            SyncState::Dirty,
            "mid-flight edit must stay queued"
        );
        assert_eq!(
            row.pending_op.as_deref(),
            Some("update"),
            "create would duplicate"
        );
        assert_eq!(row.task.etag.as_deref(), Some("e9"));
        assert_eq!(row.task.title, "typed more while pushing");
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
    async fn find_task_any_sees_tombstones() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Deleted;
        t.pending_op = Some("delete".into());
        s.upsert_task(&t).await.unwrap();
        // Excluded from list_tasks, but find_task_any sees it.
        assert!(s.list_tasks("L1").await.unwrap().is_empty());
        let found = s.find_task_any("T1").await.unwrap().unwrap();
        assert_eq!(found.sync_state, SyncState::Deleted);
        assert!(s.find_task_any("nope").await.unwrap().is_none());
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
        assert_eq!(
            SyncState::parse(SyncState::Clean.as_str()),
            Some(SyncState::Clean)
        );
        assert_eq!(
            SyncState::parse(SyncState::Dirty.as_str()),
            Some(SyncState::Dirty)
        );
        assert_eq!(
            SyncState::parse(SyncState::Deleted.as_str()),
            Some(SyncState::Deleted)
        );
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
    async fn web_view_link_round_trips() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.task.web_view_link = Some("https://tasks.google.com/task/abc123".into());
        s.upsert_task(&t).await.unwrap();
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(
            rows[0].task.web_view_link.as_deref(),
            Some("https://tasks.google.com/task/abc123")
        );
        // find_task_any sees it too.
        let found = s.find_task_any("T1").await.unwrap().unwrap();
        assert_eq!(
            found.task.web_view_link.as_deref(),
            Some("https://tasks.google.com/task/abc123")
        );
    }

    #[tokio::test]
    async fn upsert_remote_task_does_not_clobber_dirty() {
        // Models the pull-vs-edit race: a row dirtied by a live edit must
        // survive a concurrent remote upsert.
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut local = task("T1", "L1", None, "1");
        local.task.title = "my edit".into();
        local.sync_state = SyncState::Dirty;
        local.pending_op = Some("update".into());
        s.upsert_task(&local).await.unwrap();

        // Remote pull tries to overwrite with server content.
        let mut remote = task("T1", "L1", None, "1");
        remote.task.title = "server version".into();
        remote.sync_state = SyncState::Clean;
        remote.pending_op = None;
        s.upsert_remote_task(&remote).await.unwrap();

        // Local dirty edit preserved.
        let rows = s.list_tasks("L1").await.unwrap();
        assert_eq!(rows[0].task.title, "my edit");
        assert_eq!(rows[0].sync_state, SyncState::Dirty);
    }

    #[tokio::test]
    async fn upsert_remote_task_updates_clean_and_inserts_new() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        // Insert brand-new (no local row).
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Clean;
        s.upsert_remote_task(&t).await.unwrap();
        assert_eq!(s.list_tasks("L1").await.unwrap().len(), 1);
        // Update existing clean row.
        let mut t2 = task("T1", "L1", None, "1");
        t2.task.title = "updated".into();
        t2.sync_state = SyncState::Clean;
        s.upsert_remote_task(&t2).await.unwrap();
        assert_eq!(s.list_tasks("L1").await.unwrap()[0].task.title, "updated");
    }

    #[tokio::test]
    async fn remove_ghost_task_spares_dirty() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut t = task("T1", "L1", None, "1");
        t.sync_state = SyncState::Dirty;
        t.pending_op = Some("update".into());
        s.upsert_task(&t).await.unwrap();
        assert!(!s.remove_ghost_task("T1").await.unwrap());
        assert_eq!(
            s.list_tasks("L1").await.unwrap().len(),
            1,
            "dirty row spared"
        );

        // Clean row is removed.
        let mut c = task("T2", "L1", None, "2");
        c.sync_state = SyncState::Clean;
        s.upsert_task(&c).await.unwrap();
        assert!(s.remove_ghost_task("T2").await.unwrap());
        assert!(
            s.list_tasks("L1")
                .await
                .unwrap()
                .iter()
                .all(|r| r.task.id != "T2")
        );
    }

    #[tokio::test]
    async fn remove_ghost_task_promotes_unpushed_children_only() {
        // A remotely-deleted parent takes its SYNCED subtree with it, but the
        // subtask the server has never seen is promoted, not cascaded (P2).
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        let mut parent = task("P", "L1", None, "1");
        parent.sync_state = SyncState::Clean;
        s.upsert_task(&parent).await.unwrap();

        let mut synced_child = task("C-synced", "L1", Some("P"), "2");
        synced_child.sync_state = SyncState::Clean;
        synced_child.task.etag = Some("e-child".into());
        s.upsert_task(&synced_child).await.unwrap();

        let mut unpushed = task("C-new", "L1", Some("P"), "3");
        unpushed.sync_state = SyncState::Dirty;
        unpushed.pending_op = Some("create".into());
        unpushed.task.etag = None;
        s.upsert_task(&unpushed).await.unwrap();

        // A tombstoned unpushed child: the user deleted it, so it dies with
        // the parent rather than being resurrected as a top-level task.
        let mut doomed = task("C-doomed", "L1", Some("P"), "4");
        doomed.sync_state = SyncState::Deleted;
        doomed.pending_op = Some("delete".into());
        doomed.task.etag = None;
        s.upsert_task(&doomed).await.unwrap();

        assert!(s.remove_ghost_task("P").await.unwrap());

        assert!(s.find_task_any("C-synced").await.unwrap().is_none());
        assert!(s.find_task_any("C-doomed").await.unwrap().is_none());
        let kept = s.find_task_any("C-new").await.unwrap().expect("survives");
        assert_eq!(kept.task.parent, None, "promoted to top-level");
        assert_eq!(kept.pending_op.as_deref(), Some("create"));
    }

    #[tokio::test]
    async fn rehome_unpushed_tasks_moves_only_rows_the_server_never_saw() {
        // D2 at the store layer: etag-less rows follow to the target list,
        // keeping an unpushed subtree together; a subtask of a row that stays
        // behind is promoted; synced rows and tombstones do not move.
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_list(&list("L2")).await.unwrap();

        let mut synced = task("SYNCED", "L1", None, "1");
        synced.sync_state = SyncState::Clean;
        synced.task.etag = Some("e1".into());
        s.upsert_task(&synced).await.unwrap();

        for (id, parent) in [
            ("new-parent", None),
            ("new-child", Some("new-parent")),
            ("new-orphan", Some("SYNCED")),
        ] {
            let mut t = task(id, "L1", parent, "2");
            t.sync_state = SyncState::Dirty;
            t.pending_op = Some("create".into());
            t.task.etag = None;
            s.upsert_task(&t).await.unwrap();
        }
        let mut tombstone = task("gone", "L1", None, "5");
        tombstone.sync_state = SyncState::Deleted;
        tombstone.pending_op = Some("delete".into());
        tombstone.task.etag = None;
        s.upsert_task(&tombstone).await.unwrap();

        assert_eq!(s.rehome_unpushed_tasks("L1", "L2").await.unwrap(), 3);

        let moved = s.list_tasks("L2").await.unwrap();
        assert_eq!(moved.len(), 3);
        let by_id = |id: &str| moved.iter().find(|r| r.task.id == id).cloned().unwrap();
        assert_eq!(by_id("new-parent").task.parent, None);
        assert_eq!(
            by_id("new-child").task.parent.as_deref(),
            Some("new-parent"),
            "the unpushed subtree stays together"
        );
        assert_eq!(
            by_id("new-orphan").task.parent,
            None,
            "its synced parent stays behind, so it is promoted"
        );
        assert_eq!(
            s.find_task_any("SYNCED").await.unwrap().unwrap().list_id,
            "L1",
            "a row the server knows does not move"
        );
        assert_eq!(
            s.find_task_any("gone").await.unwrap().unwrap().list_id,
            "L1",
            "a tombstone does not move"
        );
        assert!(!s.has_unpushed_tasks("L1").await.unwrap());
        assert!(s.has_unpushed_tasks("L2").await.unwrap());
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
    async fn clear_synced_preserves_local_only_lists_and_tasks() {
        // Fresh sync drops synced data (the server is the source of truth) but
        // local-only lists exist nowhere else, so they must survive.
        let s = fresh().await;
        s.upsert_list(&local_list("LOCAL")).await.unwrap();
        s.upsert_list(&list("SYNCED")).await.unwrap();
        s.upsert_task(&task("LT", "LOCAL", None, "1"))
            .await
            .unwrap();
        s.upsert_task(&task("ST", "SYNCED", None, "1"))
            .await
            .unwrap();

        s.clear_synced().await.unwrap();

        let lists = s.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1, "only the local-only list survives");
        assert_eq!(lists[0].list.id, "LOCAL");
        assert!(lists[0].local_only);
        assert_eq!(
            s.list_tasks("LOCAL").await.unwrap().len(),
            1,
            "local-only list's tasks survive"
        );
        assert!(
            s.list_tasks("SYNCED").await.unwrap().is_empty(),
            "synced list's tasks are cleared"
        );
    }

    #[tokio::test]
    async fn clear_synced_cascades_moves_of_synced_tasks() {
        // Deleting synced lists must not leave orphan pending moves.
        let s = fresh().await;
        s.upsert_list(&list("SYNCED")).await.unwrap();
        s.upsert_task(&task("ST", "SYNCED", None, "1"))
            .await
            .unwrap();
        s.record_move("ST", "SYNCED", None, None).await.unwrap();
        s.clear_synced().await.unwrap();
        assert!(s.pending_moves().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn record_and_read_pending_move() {
        let s = fresh().await;
        s.upsert_list(&list("L1")).await.unwrap();
        s.upsert_task(&task("T1", "L1", None, "1")).await.unwrap();
        s.upsert_task(&task("P1", "L1", None, "2")).await.unwrap();
        s.upsert_task(&task("T0", "L1", None, "3")).await.unwrap();
        s.record_move("T1", "L1", Some("P1"), Some("T0"))
            .await
            .unwrap();
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
        s.finish_create(
            "local-1",
            "remote-1",
            Some("e1"),
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
            None,
        )
        .await
        .unwrap();
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
        s.upsert_task(&task("local-1", "L1", None, "1"))
            .await
            .unwrap();
        s.record_move("local-1", "L1", None, Some("other"))
            .await
            .unwrap();
        s.finish_create(
            "local-1",
            "remote-1",
            None,
            "2026-02-01T00:00:00Z",
            "2026-01-01T00:00:00Z",
            None,
        )
        .await
        .unwrap();
        let moves = s.pending_moves().await.unwrap();
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0].task_id, "remote-1");
    }
}
