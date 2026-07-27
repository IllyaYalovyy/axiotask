//! Errors surfaced by the store.

use thiserror::Error;

/// Persistence-layer errors.
#[derive(Debug, Error)]
pub enum StoreError {
    /// Could not open / create the database file.
    #[error("open db: {0}")]
    Open(String),

    /// A migration failed.
    #[error("migrate: {0}")]
    Migrate(String),

    /// A pre-1.0 wipe-and-recreate was refused because the local store holds
    /// data not yet on Google (local-only or unsynced) and the pre-wipe backup
    /// could not be written durably to disk. Startup fails open — the data is
    /// left intact — rather than destroy it silently.
    #[error("{0}")]
    WipeAborted(String),

    /// Underlying SQL execution failed.
    #[error("sql: {0}")]
    Sql(String),

    /// Row decode (unexpected shape) failed.
    #[error("decode: {0}")]
    Decode(String),

    /// Requested row does not exist.
    #[error("not found")]
    NotFound,
}

impl From<sqlx::Error> for StoreError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => Self::NotFound,
            _ => Self::Sql(e.to_string()),
        }
    }
}
