//! Bidirectional sync between the local store and a [`GoogleTasksClient`].
//!
//! See `designs/RFC-004-sync-engine.md` for the conflict table.

mod engine;
mod error;

pub use engine::{SyncEngine, SyncOutcome};
pub use error::SyncError;
