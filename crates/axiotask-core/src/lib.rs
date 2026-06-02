//! axiotask core: auth, API client, store, sync engine.
//!
//! No UI framework dependency. Pure logic, fully testable.

pub mod api;
pub mod auth;
pub mod config;
pub mod dates;
pub mod error;
pub mod model;
pub mod store;
pub mod sync;

pub use error::{Error, Result};
