//! Local SQLite cache.
//!
//! Uses `sqlx` runtime queries (not the compile-time-checked macros) so the
//! crate builds without a live `DATABASE_URL`. Trade-off: query strings are
//! validated only at test time. Acceptable for MVP; revisit if churn grows.

mod error;
mod repo;

pub use error::StoreError;
pub use repo::{PendingMove, Store, StoredTask, StoredTaskList, SyncState};

use sqlx::SqlitePool;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use std::path::Path;
use std::str::FromStr;

/// Open a pool against the given file path; creates the file and runs
/// migrations if needed.
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
    migrate(&pool).await?;
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
    migrate(&pool).await?;
    Ok(pool)
}

/// Ordered schema migrations. Index + 1 == the `user_version` after applying.
/// To evolve the schema, append a new `&str` here — never edit an applied one.
const MIGRATIONS: &[&str] = &[
    include_str!("../../migrations/v1_initial.sql"),
    include_str!("../../migrations/v2_local_only_lists.sql"),
    include_str!("../../migrations/v3_web_view_link.sql"),
];

/// Apply any migrations the database hasn't seen yet, tracked by
/// `PRAGMA user_version`. Idempotent: re-running is a no-op once current.
async fn migrate(pool: &SqlitePool) -> Result<(), StoreError> {
    let current: i64 = sqlx::query_scalar("PRAGMA user_version")
        .fetch_one(pool)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;

    for (idx, sql) in MIGRATIONS.iter().enumerate() {
        let version = idx as i64 + 1;
        if current >= version {
            continue;
        }
        sqlx::query(sql)
            .execute(pool)
            .await
            .map_err(|e| StoreError::Migrate(format!("v{version}: {e}")))?;
        // PRAGMA can't be parameterized; version is a trusted integer.
        sqlx::query(&format!("PRAGMA user_version = {version}"))
            .execute(pool)
            .await
            .map_err(|e| StoreError::Migrate(e.to_string()))?;
    }
    Ok(())
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
    async fn migrate_sets_user_version() {
        let pool = open_memory().await.expect("open");
        let version: i64 = sqlx::query_scalar("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[tokio::test]
    async fn migrate_is_idempotent() {
        let pool = open_memory().await.expect("open");
        // Re-running migrate must be a no-op (CREATE TABLE without IF NOT
        // EXISTS would error if it re-ran).
        migrate(&pool).await.expect("second migrate is a no-op");
        let version: i64 = sqlx::query_scalar("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[tokio::test]
    async fn dropped_legacy_tables_absent() {
        // id_remap was dead weight (write-only) and is gone.
        let pool = open_memory().await.expect("open");
        let row: (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='id_remap'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(row.0, 0);
    }

    #[tokio::test]
    async fn migrate_resets_legacy_pre_versioning_db() {
        // Simulate a dev DB created by the old unversioned schema: tables exist
        // and PRAGMA user_version is still 0. migrate() must reset to v1 cleanly
        // (the bug: bare CREATE TABLE errored with "table already exists").
        let opts = SqliteConnectOptions::from_str("sqlite::memory:")
            .unwrap()
            .foreign_keys(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .unwrap();
        // Legacy schema fragment (note: no pending_op on task_lists, has id_remap).
        sqlx::query(
            "CREATE TABLE task_lists (id TEXT PRIMARY KEY, title TEXT NOT NULL,
                 etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL,
                 sync_state TEXT NOT NULL, deleted_at TEXT);
             CREATE TABLE id_remap (local_id TEXT PRIMARY KEY, remote_id TEXT);",
        )
        .execute(&pool)
        .await
        .unwrap();
        // user_version defaults to 0 — the legacy state.

        migrate(&pool).await.expect("legacy DB resets cleanly");

        // Now at the latest version with the new schema.
        let ver: i64 = sqlx::query_scalar("PRAGMA user_version").fetch_one(&pool).await.unwrap();
        assert_eq!(ver, MIGRATIONS.len() as i64);
        let store = Store::new(pool);
        // Exercising a query that references pending_op proves the new schema.
        assert!(store.all_lists().await.unwrap().is_empty());
        assert!(store.drain_dirty_lists().await.unwrap().is_empty());
    }
}
