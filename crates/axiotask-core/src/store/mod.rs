//! Local SQLite cache.
//!
//! Uses `sqlx` runtime queries (not the compile-time-checked macros) so the
//! crate builds without a live `DATABASE_URL`. Trade-off: query strings are
//! validated only at test time. Acceptable for MVP; revisit if churn grows.

mod error;
mod repo;

pub use error::StoreError;
pub use repo::{PendingMove, Store, StoredTask, StoredTaskList, SyncState};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Column, Row, SqlitePool, TypeInfo, ValueRef};
use std::path::{Path, PathBuf};
use std::str::FromStr;

/// The whole local-store schema, in one file. Pre-1.0 there are NO migrations:
/// a schema change wipes and recreates the cache (see [`prepare_schema`] and
/// designs/RFC-003-local-sqlite-store.md). To change the schema, edit that file.
const SCHEMA: &str = include_str!("../../schema.sql");

/// Open a pool against the given file path; creates the file if missing and
/// makes the schema current — wiping-and-recreating (after a JSON export) any
/// database whose fingerprint no longer matches [`SCHEMA`].
pub async fn open(path: &Path) -> Result<SqlitePool, StoreError> {
    let url = format!("sqlite://{}", path.display());
    let opts = SqliteConnectOptions::from_str(&url)
        .map_err(|e| StoreError::Open(e.to_string()))?
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(4)
        .connect_with(opts)
        .await
        .map_err(|e| StoreError::Open(e.to_string()))?;
    prepare_schema(&pool, Some(path)).await?;
    Ok(pool)
}

/// Open an in-memory pool; useful for tests.
pub async fn open_memory() -> Result<SqlitePool, StoreError> {
    let opts = SqliteConnectOptions::from_str("sqlite::memory:")
        .map_err(|e| StoreError::Open(e.to_string()))?
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(opts)
        .await
        .map_err(|e| StoreError::Open(e.to_string()))?;
    prepare_schema(&pool, None).await?;
    Ok(pool)
}

/// Stable 32-bit fingerprint of the current [`SCHEMA`], stored in the database
/// header's `user_version` slot. A database stamped with a different value is
/// from an incompatible schema. Never zero — 0 is the default of an unstamped
/// (fresh, or pre-fingerprint) database, which must be told apart from a match.
fn schema_fingerprint() -> i64 {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(SCHEMA.as_bytes());
    let bytes = [digest[0], digest[1], digest[2], digest[3]];
    let fp = i64::from(i32::from_be_bytes(bytes));
    if fp == 0 { 1 } else { fp }
}

/// Make the schema current. Fast path: a database already stamped with the
/// current fingerprint is left untouched. Otherwise the database is either
/// fresh (create the schema and stamp it) or from an incompatible schema — in
/// which case its contents are exported to JSON and it is wiped and recreated.
///
/// Pre-1.0 there are no migrations (RFC-003 G4): the local store is a cache of
/// Google's data, so a schema change starts the cache over rather than
/// evolving it in place. `path` (the database file) is where the pre-wipe JSON
/// backup is written; `None` for an in-memory database, which has nothing to
/// preserve.
async fn prepare_schema(pool: &SqlitePool, path: Option<&Path>) -> Result<(), StoreError> {
    let stamped: i64 = sqlx::query_scalar("PRAGMA user_version")
        .fetch_one(pool)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    let expected = schema_fingerprint();
    if stamped == expected {
        return Ok(());
    }

    // Incompatible or fresh. If it already holds tables it is an old schema
    // (or a pre-fingerprint database): back it up, then wipe it clean. The wipe
    // is destructive, so it must not run unless the pre-wipe backup is durably
    // on disk — UNLESS the cache holds nothing Google lacks, in which case the
    // wipe-and-recreate is safe even without a backup (#129).
    if has_user_tables(pool).await? {
        if let BackupOutcome::Failed(reason) = export_before_wipe(pool, path).await {
            if has_unsynced_local_data(pool).await {
                return Err(StoreError::WipeAborted(format!(
                    "Refusing to reset the local store after a schema change: it holds \
                     local-only or unsynced changes that are not yet saved to Google, and \
                     the pre-wipe backup could not be written to disk ({reason}). Your data \
                     has been left untouched. Free up disk space or fix file permissions for \
                     the data directory and restart."
                )));
            }
            tracing::warn!(
                "pre-wipe backup failed ({reason}), but the local store is fully synced with \
                 Google; wiping-and-recreating best-effort from the current schema"
            );
        }
        wipe(pool).await?;
    }

    sqlx::query(SCHEMA)
        .execute(pool)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    // PRAGMA can't be parameterized; the fingerprint is a trusted integer.
    sqlx::query(&format!("PRAGMA user_version = {expected}"))
        .execute(pool)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    Ok(())
}

/// Whether the database holds any user (non-`sqlite_*`) tables.
async fn has_user_tables(pool: &SqlitePool) -> Result<bool, StoreError> {
    let n: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    )
    .fetch_one(pool)
    .await
    .map_err(|e| StoreError::Migrate(e.to_string()))?;
    Ok(n > 0)
}

/// Whether the (soon-to-be-wiped) database holds local state that is NOT
/// recoverable from Google: local-only lists, unpushed dirty/deleted rows, or
/// queued moves / in-flight creates. Used only when the pre-wipe backup could
/// not be written — a fully-synced cache is safe to wipe without a backup
/// (Google is the source of truth), but local-only/dirty data would be lost.
///
/// Schema-agnostic and conservative: the database being inspected is from an
/// OLDER schema, so a probe against a table that exists but errors (e.g. an
/// unexpected column) is treated as "at risk" rather than assumed safe.
async fn has_unsynced_local_data(pool: &SqlitePool) -> bool {
    for (table, predicate) in [
        ("task_lists", "local_only = 1"),
        ("task_lists", "sync_state <> 'clean'"),
        ("tasks", "sync_state <> 'clean'"),
        ("tasks", "pending_op IS NOT NULL"),
        ("pending_moves", "1 = 1"),
        ("inflight_creates", "1 = 1"),
    ] {
        if any_row_matches(pool, table, predicate).await {
            return true;
        }
    }
    false
}

/// True if `table` exists and holds at least one row matching `predicate`. A
/// missing table ⇒ false (nothing there to lose). A query error against an
/// existing table (e.g. a column the old schema lacks) ⇒ true (conservative:
/// never destroy data we could not inspect). `table` and `predicate` are
/// compile-time constants from [`has_unsynced_local_data`], never user input.
async fn any_row_matches(pool: &SqlitePool, table: &str, predicate: &str) -> bool {
    let exists: Result<i64, _> =
        sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?")
            .bind(table)
            .fetch_one(pool)
            .await;
    match exists {
        Ok(0) => return false, // table absent from this (old) schema
        Ok(_) => {}
        Err(_) => return true, // cannot even inspect: conservative
    }
    let matched: Result<i64, _> = sqlx::query_scalar(&format!(
        "SELECT EXISTS(SELECT 1 FROM \"{table}\" WHERE {predicate})"
    ))
    .fetch_one(pool)
    .await;
    matched.map_or(true, |n| n != 0)
}

/// Drop every user object — tables, views, AND triggers — so the schema can be
/// recreated from scratch. Dropping only tables is not enough: a standalone
/// view (and any INSTEAD OF trigger on it) is not attached to a table, so it
/// would survive a table-only wipe and linger as a stale object in the
/// recreated database (#133). Triggers are dropped first, then views, then
/// tables; `IF EXISTS` makes the order safe even when dropping a table or view
/// has already cascaded away a dependent trigger. Foreign keys are disabled for
/// the drop (and restored after) so tables can go in any order without tripping
/// a reference constraint.
async fn wipe(pool: &SqlitePool) -> Result<(), StoreError> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&mut *conn)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    // (object_type, kind-keyword) pairs, dropped in dependency-safe order.
    for (kind, keyword) in [("trigger", "TRIGGER"), ("view", "VIEW"), ("table", "TABLE")] {
        let objects: Vec<(String,)> = sqlx::query_as(
            "SELECT name FROM sqlite_master WHERE type = ?1 AND name NOT LIKE 'sqlite_%'",
        )
        .bind(kind)
        .fetch_all(&mut *conn)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
        for (name,) in objects {
            // `name` comes from sqlite_master, not user input; quote it defensively.
            sqlx::query(&format!("DROP {keyword} IF EXISTS \"{name}\""))
                .execute(&mut *conn)
                .await
                .map_err(|e| StoreError::Migrate(e.to_string()))?;
        }
    }
    sqlx::query("PRAGMA foreign_keys = ON")
        .execute(&mut *conn)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
    Ok(())
}

/// Outcome of the pre-wipe backup attempt, so the caller can decide whether the
/// destructive wipe is safe to proceed with (#129).
enum BackupOutcome {
    /// The backup is durably on disk, or there is nothing to preserve (an
    /// in-memory database). Either way the wipe may proceed unconditionally.
    Durable,
    /// The backup could not be written durably; the string is a human reason.
    /// The wipe may only proceed if no local-only/unsynced data is at risk.
    Failed(String),
}

/// JSON export of a soon-to-be-wiped database, written (and fsync'd) beside the
/// database file. The export is logged loudly so a lost local-only list or
/// unpushed edit is recoverable. Google remains the source of truth, but a
/// wipe must not run unless this backup is durably on disk when local data is
/// at risk (#129) — hence the outcome is returned rather than swallowed. An
/// in-memory database (`path == None`) has no file and nothing a user would
/// miss, so it reports [`BackupOutcome::Durable`].
async fn export_before_wipe(pool: &SqlitePool, path: Option<&Path>) -> BackupOutcome {
    let Some(path) = path else {
        return BackupOutcome::Durable;
    };
    let json = match raw_dump_json(pool).await {
        Ok(json) => json,
        Err(e) => {
            tracing::error!("schema changed but pre-wipe backup dump failed: {e}");
            return BackupOutcome::Failed(format!("dump: {e}"));
        }
    };
    let out = pre_wipe_backup_path(path);
    match write_durably(&out, json.as_bytes()) {
        Ok(()) => {
            tracing::warn!(
                "schema changed; local database wiped-and-recreated. \
                 Pre-wipe backup written to {}",
                out.display()
            );
            BackupOutcome::Durable
        }
        Err(e) => {
            tracing::error!(
                "schema changed but pre-wipe backup write to {} failed: {e}",
                out.display()
            );
            BackupOutcome::Failed(format!("write {}: {e}", out.display()))
        }
    }
}

/// Write `bytes` to `path` and force them to durable storage before returning:
/// `sync_all` flushes the file's data and metadata, then the parent directory
/// is fsync'd (best-effort) so the new file's directory entry itself survives a
/// crash. Without this, `std::fs::write` alone can report success while the
/// bytes still sit in OS buffers — a crash would then lose the "backup" that a
/// wipe was told had been taken (#129).
fn write_durably(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = std::fs::File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    if let Some(dir) = path.parent() {
        // Directory fsync is best-effort: not all platforms permit opening a
        // directory as a file, but the file's own sync_all is the guarantee.
        if let Ok(dir) = std::fs::File::open(dir) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Path for the pre-wipe backup: a timestamped JSON file beside the database.
/// Timestamped so successive wipes never clobber an earlier backup.
fn pre_wipe_backup_path(db_path: &Path) -> PathBuf {
    let stamp = jiff::Zoned::now().strftime("%Y%m%d-%H%M%S").to_string();
    let dir = db_path.parent().unwrap_or_else(|| Path::new("."));
    dir.join(format!("axiotask-prewipe-{stamp}.json"))
}

/// Schema-agnostic dump of every user table to a single JSON document. Reads
/// whatever columns exist (it cannot assume the current schema — that is the
/// point), decoding each cell by its stored value type.
async fn raw_dump_json(pool: &SqlitePool) -> Result<String, StoreError> {
    let tables: Vec<(String,)> = sqlx::query_as(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' \
         ORDER BY name",
    )
    .fetch_all(pool)
    .await
    .map_err(|e| StoreError::Sql(e.to_string()))?;

    let mut tables_json = serde_json::Map::new();
    for (table,) in tables {
        // `table` comes from sqlite_master, not user input; quote it defensively.
        let rows = sqlx::query(&format!("SELECT * FROM \"{table}\""))
            .fetch_all(pool)
            .await
            .map_err(|e| StoreError::Sql(e.to_string()))?;
        let mut out_rows = Vec::with_capacity(rows.len());
        for row in &rows {
            let mut obj = serde_json::Map::new();
            for col in row.columns() {
                obj.insert(col.name().to_string(), cell_to_json(row, col.ordinal()));
            }
            out_rows.push(serde_json::Value::Object(obj));
        }
        tables_json.insert(table, serde_json::Value::Array(out_rows));
    }

    let doc = serde_json::json!({
        "app": "axiotask",
        "kind": "pre-wipe-raw-dump",
        "exported_at": crate::dates::now_utc_string(),
        "tables": serde_json::Value::Object(tables_json),
    });
    serde_json::to_string_pretty(&doc).map_err(|e| StoreError::Sql(e.to_string()))
}

/// Decode one SQLite cell into a JSON value by its stored type class, so an
/// unknown old column of any type round-trips into the backup.
fn cell_to_json(row: &sqlx::sqlite::SqliteRow, idx: usize) -> serde_json::Value {
    let Ok(raw) = row.try_get_raw(idx) else {
        return serde_json::Value::Null;
    };
    if raw.is_null() {
        return serde_json::Value::Null;
    }
    match raw.type_info().name() {
        "INTEGER" | "BIGINT" | "INT" | "BOOLEAN" => row
            .try_get::<i64, _>(idx)
            .map(serde_json::Value::from)
            .unwrap_or(serde_json::Value::Null),
        "REAL" | "FLOAT" | "DOUBLE" => row
            .try_get::<f64, _>(idx)
            .map(serde_json::Value::from)
            .unwrap_or(serde_json::Value::Null),
        "BLOB" => {
            use base64::Engine;
            row.try_get::<Vec<u8>, _>(idx)
                .map(|b| {
                    serde_json::Value::from(base64::engine::general_purpose::STANDARD.encode(b))
                })
                .unwrap_or(serde_json::Value::Null)
        }
        _ => row
            .try_get::<String, _>(idx)
            .map(serde_json::Value::from)
            .unwrap_or(serde_json::Value::Null),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn open_memory_succeeds_and_schema_exists() {
        let pool = open_memory().await.expect("open");
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='tasks'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(row.0, 1);
    }

    #[tokio::test]
    async fn open_stamps_the_schema_fingerprint() {
        // A fresh database is stamped with the current schema fingerprint (a
        // non-zero value), not left at the default 0.
        let pool = open_memory().await.expect("open");
        let stamped: i64 = sqlx::query_scalar("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_ne!(stamped, 0, "fresh DB must be stamped");
        assert_eq!(stamped, schema_fingerprint());
    }

    #[tokio::test]
    async fn reopen_of_current_db_preserves_data() {
        // Fingerprint match ⇒ no wipe. Data written to a current-schema DB must
        // survive a reopen; the store must not wipe-and-recreate on every launch.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");

        let store = Store::new(open(&db).await.expect("first open"));
        store
            .upsert_list(&sample_list("L1", "Inbox"))
            .await
            .unwrap();
        drop(store);

        let store = Store::new(open(&db).await.expect("reopen"));
        let lists = store.all_lists().await.unwrap();
        assert_eq!(lists.len(), 1, "data must survive a reopen");
        assert_eq!(lists[0].list.id, "L1");
        // No spurious pre-wipe backup for an unchanged schema.
        assert!(
            prewipe_backups_in(dir.path()).is_empty(),
            "an unchanged schema must not trigger a backup/wipe"
        );
    }

    #[tokio::test]
    async fn fresh_db_is_not_backed_up() {
        // Creating a brand-new database has nothing to export: no pre-wipe file.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        let _pool = open(&db).await.expect("open fresh");
        assert!(
            prewipe_backups_in(dir.path()).is_empty(),
            "a fresh DB must not produce a pre-wipe backup"
        );
    }

    #[tokio::test]
    async fn incompatible_schema_is_exported_then_wiped_and_recreated() {
        // The bug (#126): a schema change silently bricks an existing DB. Model
        // a DB that a prior build created and stamped, but whose `tasks` table
        // predates the current columns (no web_view_link). Non-happy path: the
        // fixture holds a parent task AND a child subtask.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");

        {
            let url = format!("sqlite://{}", db.display());
            let opts = SqliteConnectOptions::from_str(&url)
                .unwrap()
                .create_if_missing(true)
                .foreign_keys(true);
            let pool = SqlitePoolOptions::new()
                .max_connections(1)
                .connect_with(opts)
                .await
                .unwrap();
            // Old schema: tasks WITHOUT web_view_link / base_* columns.
            sqlx::query(
                "CREATE TABLE task_lists (id TEXT PRIMARY KEY, title TEXT NOT NULL,
                     etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL,
                     sync_state TEXT NOT NULL, pending_op TEXT,
                     local_only INTEGER NOT NULL DEFAULT 0);
                 CREATE TABLE tasks (id TEXT PRIMARY KEY, list_id TEXT NOT NULL,
                     parent_id TEXT, position TEXT NOT NULL, title TEXT NOT NULL,
                     notes TEXT, status TEXT NOT NULL, due TEXT, completed_at TEXT,
                     etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL,
                     sync_state TEXT NOT NULL, pending_op TEXT);",
            )
            .execute(&pool)
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO task_lists (id,title,updated,local_updated,sync_state)
                     VALUES ('L1','Old Inbox','u','lu','clean');
                 INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state)
                     VALUES ('P1','L1','1','Parent survives','needsAction','u','lu','clean');
                 INSERT INTO tasks (id,list_id,parent_id,position,title,status,updated,local_updated,sync_state)
                     VALUES ('C1','L1','P1','1','Child subtask','needsAction','u','lu','clean');",
            )
            .execute(&pool)
            .await
            .unwrap();
            // Stamp it as a previously-migrated DB (old counter value) so the
            // fingerprint comparison — not an accidental 0 — triggers the wipe.
            sqlx::query("PRAGMA user_version = 3")
                .execute(&pool)
                .await
                .unwrap();
            pool.close().await;
        }

        // Reopen through the real entry point.
        let store = Store::new(open(&db).await.expect("open incompatible DB"));

        // 1. Recreated with the CURRENT schema (new column present).
        let has_col: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='web_view_link'",
        )
        .fetch_one(store.pool())
        .await
        .unwrap();
        assert_eq!(has_col, 1, "recreated tasks table must have the new column");
        let stamped: i64 = sqlx::query_scalar("PRAGMA user_version")
            .fetch_one(store.pool())
            .await
            .unwrap();
        assert_eq!(stamped, schema_fingerprint(), "must be re-stamped");

        // 2. The stale cache is gone (Google is the source of truth).
        assert!(
            store.all_lists().await.unwrap().is_empty(),
            "incompatible DB must be wiped clean"
        );

        // 3. The old data was exported to JSON before the wipe — both the parent
        //    and the child subtask, so nothing local is lost silently.
        let backups = prewipe_backups_in(dir.path());
        assert_eq!(backups.len(), 1, "exactly one pre-wipe backup expected");
        let json = std::fs::read_to_string(&backups[0]).unwrap();
        assert!(json.contains("Old Inbox"), "list must be in the backup");
        assert!(
            json.contains("Parent survives"),
            "parent must be in the backup"
        );
        assert!(
            json.contains("Child subtask"),
            "child subtask must be in the backup"
        );
    }

    #[tokio::test]
    async fn wipe_and_recreate_drops_stale_views_and_triggers() {
        // #133: a schema change wipes-and-recreates, but `wipe()` historically
        // dropped only TABLES. A standalone VIEW — and any INSTEAD OF trigger
        // defined on it — is not attached to any table, so a table-only wipe
        // leaves both behind. They then linger in the recreated database as
        // stale objects that can shadow or collide with a future schema. The
        // wipe must drop views and triggers too. Non-happy path: the old DB
        // carries schema objects the current schema does not define at all.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        let pool = old_schema_db(&db).await;
        sqlx::query(
            "CREATE VIEW v_legacy AS SELECT id, title FROM tasks;
             CREATE TRIGGER trg_legacy INSTEAD OF INSERT ON v_legacy
                 BEGIN SELECT 1; END;",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool.close().await;

        // Reopen through the real entry point: fingerprint mismatch ⇒ the
        // stale DB is backed up, wiped, and recreated from the current schema.
        let store = Store::new(open(&db).await.expect("wipe-and-recreate"));

        let views: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='view'")
            .fetch_one(store.pool())
            .await
            .unwrap();
        assert_eq!(views, 0, "a schema wipe must drop stale views");

        let triggers: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'")
                .fetch_one(store.pool())
                .await
                .unwrap();
        assert_eq!(triggers, 0, "a schema wipe must drop stale triggers");
    }

    #[tokio::test]
    async fn cascade_delete_still_works_after_a_wipe() {
        // Invariant #3: deletes cascade. `wipe()` toggles PRAGMA foreign_keys
        // OFF/ON on a pooled connection — this proves the connection is not
        // left FK-disabled, which would silently orphan subtasks on delete.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        {
            let url = format!("sqlite://{}", db.display());
            let opts = SqliteConnectOptions::from_str(&url)
                .unwrap()
                .create_if_missing(true)
                .foreign_keys(true);
            let pool = SqlitePoolOptions::new()
                .max_connections(1)
                .connect_with(opts)
                .await
                .unwrap();
            sqlx::query("CREATE TABLE legacy (x TEXT); PRAGMA user_version = 3;")
                .execute(&pool)
                .await
                .unwrap();
            pool.close().await;
        }

        let store = Store::new(open(&db).await.expect("wipe-and-recreate"));
        store
            .upsert_list(&sample_list("L1", "Inbox"))
            .await
            .unwrap();
        store
            .upsert_task(&sample_task("P1", "L1", None))
            .await
            .unwrap();
        store
            .upsert_task(&sample_task("C1", "L1", Some("P1")))
            .await
            .unwrap();

        // Delete the parent; the child must cascade away via the parent_id FK.
        store.delete_task_hard("P1").await.unwrap();
        assert!(
            store.find_task_any("C1").await.unwrap().is_none(),
            "child subtask must cascade-delete after a wipe (FK left ON)"
        );
    }

    #[tokio::test]
    async fn wipe_aborts_when_backup_fails_and_local_only_data_at_risk() {
        // #129: a schema change must NOT wipe local data that Google does not
        // have (a local-only list) unless the pre-wipe backup is durably on
        // disk. Here the backup write is forced to fail (its target directory
        // does not exist), so the open must FAIL OPEN — abort the wipe and
        // leave the at-risk data untouched — rather than silently destroy it.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        let pool = old_schema_db(&db).await;
        // A local-only list: lives only on this device, absent from Google.
        sqlx::query(
            "INSERT INTO task_lists (id,title,updated,local_updated,sync_state,local_only)
                 VALUES ('L1','My private list','u','lu','clean',1);
             INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state)
                 VALUES ('T1','L1','1','Only here','needsAction','u','lu','clean');",
        )
        .execute(&pool)
        .await
        .unwrap();

        // Backup target dir does not exist ⇒ the durable write cannot succeed.
        let unwritable = dir.path().join("no-such-dir").join("axiotask.sqlite");
        let err = prepare_schema(&pool, Some(&unwritable))
            .await
            .expect_err("open must fail open when at-risk data cannot be backed up");
        assert!(
            matches!(err, StoreError::WipeAborted(_)),
            "expected WipeAborted, got {err:?}"
        );

        // The at-risk data must still be there — nothing was dropped.
        let lists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM task_lists WHERE local_only = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(
            lists, 1,
            "the local-only list must survive the aborted wipe"
        );
        let tasks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tasks")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(
            tasks, 1,
            "the local-only task must survive the aborted wipe"
        );
        // And no partial backup was left anywhere in the real directory.
        assert!(
            prewipe_backups_in(dir.path()).is_empty(),
            "a failed backup must not leave a file behind"
        );
    }

    #[tokio::test]
    async fn wipe_aborts_when_backup_fails_and_dirty_edits_at_risk() {
        // #129: unpushed edits (sync_state != 'clean') are also not yet on
        // Google, so they are at risk and must block a backup-less wipe.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        let pool = old_schema_db(&db).await;
        sqlx::query(
            "INSERT INTO task_lists (id,title,updated,local_updated,sync_state)
                 VALUES ('L1','Inbox','u','lu','clean');
             INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state,pending_op)
                 VALUES ('T1','L1','1','Edited offline','needsAction','u','lu','dirty','update');",
        )
        .execute(&pool)
        .await
        .unwrap();

        let unwritable = dir.path().join("no-such-dir").join("axiotask.sqlite");
        let err = prepare_schema(&pool, Some(&unwritable))
            .await
            .expect_err("dirty edits with no durable backup must abort the wipe");
        assert!(matches!(err, StoreError::WipeAborted(_)), "got {err:?}");
        let dirty: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM tasks WHERE sync_state <> 'clean'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(dirty, 1, "the dirty edit must survive the aborted wipe");
    }

    #[tokio::test]
    async fn clean_cache_wipes_best_effort_even_when_backup_fails() {
        // #129: a fully-synced cache holds nothing Google does not already
        // have, so it may still be wiped-and-recreated even when the pre-wipe
        // backup cannot be written. This keeps a schema change from bricking
        // startup for the common case where no local-only/dirty data exists.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("axiotask.sqlite");
        let pool = old_schema_db(&db).await;
        sqlx::query(
            "INSERT INTO task_lists (id,title,updated,local_updated,sync_state)
                 VALUES ('L1','Inbox','u','lu','clean');
             INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state)
                 VALUES ('T1','L1','1','Synced task','needsAction','u','lu','clean');",
        )
        .execute(&pool)
        .await
        .unwrap();

        // Backup target dir does not exist ⇒ the write fails, but the cache is
        // clean, so the wipe proceeds best-effort.
        let unwritable = dir.path().join("no-such-dir").join("axiotask.sqlite");
        prepare_schema(&pool, Some(&unwritable))
            .await
            .expect("a clean cache must wipe-and-recreate even without a backup");

        // Recreated with the CURRENT schema and emptied.
        let has_col: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='web_view_link'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(
            has_col, 1,
            "clean cache must be recreated on the new schema"
        );
        let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tasks")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(remaining, 0, "clean cache must be wiped clean");
    }

    #[tokio::test]
    async fn has_unsynced_local_data_distinguishes_clean_from_at_risk() {
        // Directly exercise the at-risk detector across its branches.
        let dir = tempfile::tempdir().unwrap();

        // Clean, fully-synced cache ⇒ nothing at risk.
        let clean = old_schema_db(&dir.path().join("clean.sqlite")).await;
        sqlx::query(
            "INSERT INTO task_lists (id,title,updated,local_updated,sync_state)
                 VALUES ('L1','Inbox','u','lu','clean');
             INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state)
                 VALUES ('T1','L1','1','Synced','needsAction','u','lu','clean');",
        )
        .execute(&clean)
        .await
        .unwrap();
        assert!(
            !has_unsynced_local_data(&clean).await,
            "a fully-synced cache is not at risk"
        );

        // A local-only list ⇒ at risk.
        let local = old_schema_db(&dir.path().join("local.sqlite")).await;
        sqlx::query(
            "INSERT INTO task_lists (id,title,updated,local_updated,sync_state,local_only)
                 VALUES ('L1','Private','u','lu','clean',1);",
        )
        .execute(&local)
        .await
        .unwrap();
        assert!(
            has_unsynced_local_data(&local).await,
            "a local-only list is at risk"
        );
    }

    /// Open a real on-disk pool holding the OLD (pre-current) schema, stamped
    /// with a stale fingerprint so `prepare_schema` treats it as incompatible.
    /// The pool is returned live so a test can insert fixture rows and then
    /// drive `prepare_schema` directly.
    async fn old_schema_db(db: &Path) -> SqlitePool {
        let url = format!("sqlite://{}", db.display());
        let opts = SqliteConnectOptions::from_str(&url)
            .unwrap()
            .create_if_missing(true)
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .unwrap();
        // Old schema: tasks WITHOUT web_view_link / base_* columns.
        sqlx::query(
            "CREATE TABLE task_lists (id TEXT PRIMARY KEY, title TEXT NOT NULL,
                 etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL,
                 sync_state TEXT NOT NULL, pending_op TEXT,
                 local_only INTEGER NOT NULL DEFAULT 0);
             CREATE TABLE tasks (id TEXT PRIMARY KEY, list_id TEXT NOT NULL,
                 parent_id TEXT, position TEXT NOT NULL, title TEXT NOT NULL,
                 notes TEXT, status TEXT NOT NULL, due TEXT, completed_at TEXT,
                 etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL,
                 sync_state TEXT NOT NULL, pending_op TEXT);",
        )
        .execute(&pool)
        .await
        .unwrap();
        // Stamp a stale (non-zero, non-matching) fingerprint so the mismatch —
        // not an accidental 0 — triggers the wipe path.
        sqlx::query("PRAGMA user_version = 3")
            .execute(&pool)
            .await
            .unwrap();
        pool
    }

    fn sample_task(id: &str, list_id: &str, parent: Option<&str>) -> StoredTask {
        use crate::model::{Task, TaskStatus};
        StoredTask {
            task: Task {
                id: id.into(),
                parent: parent.map(str::to_string),
                position: "00000000000001".into(),
                title: id.into(),
                notes: None,
                status: TaskStatus::NeedsAction,
                due: None,
                completed: None,
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
                web_view_link: None,
                deleted: false,
            },
            list_id: list_id.into(),
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
        }
    }

    fn sample_list(id: &str, title: &str) -> StoredTaskList {
        use crate::model::TaskList;
        StoredTaskList {
            list: TaskList {
                id: id.into(),
                title: title.into(),
                etag: None,
                updated: "2026-01-01T00:00:00Z".into(),
            },
            sync_state: SyncState::Clean,
            local_updated: "2026-01-01T00:00:00Z".into(),
            pending_op: None,
            local_only: false,
        }
    }

    fn prewipe_backups_in(dir: &std::path::Path) -> Vec<PathBuf> {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return Vec::new();
        };
        entries
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                let is_json = p
                    .extension()
                    .is_some_and(|e| e.eq_ignore_ascii_case("json"));
                let named = p
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("axiotask-prewipe-"));
                is_json && named
            })
            .collect()
    }
}
