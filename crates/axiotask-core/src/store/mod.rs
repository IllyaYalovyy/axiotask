//! Local SQLite cache.
//!
//! Uses `sqlx` runtime queries (not the compile-time-checked macros) so the
//! crate builds without a live `DATABASE_URL`. Trade-off: query strings are
//! validated only at test time. Acceptable for MVP; revisit if churn grows.

mod error;
mod repo;

pub use error::StoreError;
pub use repo::{Store, StoredTask, StoredTaskList, SyncState};

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

/// Apply the initial migration. Idempotent.
async fn migrate(pool: &SqlitePool) -> Result<(), StoreError> {
    sqlx::query(include_str!("../../migrations/20260101000000_initial.sql"))
        .execute(pool)
        .await
        .map_err(|e| StoreError::Migrate(e.to_string()))?;
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
}
