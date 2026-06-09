//! Google Tasks API client trait and implementations.
//!
//! [`GoogleTasksClient`] is the only abstraction between the rest of the app
//! and Google's API, per the project's VISION. [`InMemoryClient`] is a
//! fully-behaving test double (unit-tested directly), and [`HttpClient`] is the
//! real implementation (covered by `wiremock`-backed tests), so the two stay in
//! step.

mod error;
mod http;
pub mod in_memory;
mod traits;

pub use error::ApiError;
pub use http::HttpClient;
pub use in_memory::InMemoryClient;
pub use traits::GoogleTasksClient;
