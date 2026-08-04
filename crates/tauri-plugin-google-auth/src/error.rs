use serde::{Serialize, Serializer};

/// Errors surfaced by the google-auth plugin.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A failure crossing into the Kotlin plugin (Android).
    #[cfg(mobile)]
    #[error(transparent)]
    PluginInvoke(#[from] tauri::plugin::mobile::PluginInvokeError),
    /// Any other failure, carrying a human-readable message.
    #[error("{0}")]
    Message(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Serialize for Error {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_ref())
    }
}
