//! Google Tasks API client trait and implementations.
//!
//! [`GoogleTasksClient`] is the only abstraction between the rest of the app
//! and Google's API, per the project's VISION. A single contract-test suite
//! runs against both [`InMemoryClient`] and [`HttpClient`] so the two
//! implementations cannot drift.

mod error;
mod http;
pub mod in_memory;
mod traits;

#[cfg(test)]
mod contract;

pub use error::ApiError;
pub use http::HttpClient;
pub use in_memory::InMemoryClient;
pub use traits::GoogleTasksClient;
