//! Token persistence. Real storage uses the OS keychain via the `keyring`
//! crate; tests use [`InMemoryTokenStore`].

use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use super::error::AuthError;

/// Tokens we persist between sessions. Access tokens are short-lived; the
/// refresh token is the long-term credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredTokens {
    /// Bearer access token.
    pub access_token: String,
    /// Refresh token issued by Google.
    pub refresh_token: String,
    /// Optional Unix-epoch seconds at which `access_token` expires.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_expires_at: Option<i64>,
    /// Granted scopes (space-separated, as Google returns).
    #[serde(default)]
    pub scope: String,
}

/// Persistence boundary for the auth subsystem.
pub trait TokenStore: Send + Sync {
    /// Read the persisted tokens, or `Ok(None)` if not signed in.
    fn load(&self) -> Result<Option<StoredTokens>, AuthError>;
    /// Persist a token bundle, replacing whatever was stored before.
    fn save(&self, tokens: &StoredTokens) -> Result<(), AuthError>;
    /// Remove any persisted tokens.
    fn clear(&self) -> Result<(), AuthError>;
}

/// Volatile, in-process token store. Round-trips through [`TokenStore`]
/// exactly like the real one.
#[derive(Debug, Default)]
pub struct InMemoryTokenStore {
    inner: Mutex<Option<StoredTokens>>,
}

impl InMemoryTokenStore {
    /// Construct an empty store.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(None),
        }
    }
}

impl TokenStore for InMemoryTokenStore {
    fn load(&self) -> Result<Option<StoredTokens>, AuthError> {
        Ok(self.inner.lock().unwrap().clone())
    }

    fn save(&self, tokens: &StoredTokens) -> Result<(), AuthError> {
        *self.inner.lock().unwrap() = Some(tokens.clone());
        Ok(())
    }

    fn clear(&self) -> Result<(), AuthError> {
        *self.inner.lock().unwrap() = None;
        Ok(())
    }
}

/// OS-keychain-backed store. Uses one entry per `service` + `user`.
pub struct KeyringTokenStore {
    service: String,
    user: String,
}

impl KeyringTokenStore {
    /// Construct against a specific keyring entry. Convention: `service`
    /// uniquely names this app; `user` discriminates between accounts (use
    /// `"default"` for single-account MVP).
    pub fn new(service: impl Into<String>, user: impl Into<String>) -> Self {
        Self {
            service: service.into(),
            user: user.into(),
        }
    }

    fn entry(&self) -> Result<keyring::Entry, AuthError> {
        keyring::Entry::new(&self.service, &self.user)
            .map_err(|e| AuthError::Keyring(e.to_string()))
    }
}

impl TokenStore for KeyringTokenStore {
    fn load(&self) -> Result<Option<StoredTokens>, AuthError> {
        let entry = self.entry()?;
        match entry.get_password() {
            Ok(s) => {
                let tokens: StoredTokens =
                    serde_json::from_str(&s).map_err(|e| AuthError::Format(e.to_string()))?;
                Ok(Some(tokens))
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(AuthError::Keyring(e.to_string())),
        }
    }

    fn save(&self, tokens: &StoredTokens) -> Result<(), AuthError> {
        let entry = self.entry()?;
        let json = serde_json::to_string(tokens).map_err(|e| AuthError::Format(e.to_string()))?;
        entry
            .set_password(&json)
            .map_err(|e| AuthError::Keyring(e.to_string()))
    }

    fn clear(&self) -> Result<(), AuthError> {
        let entry = self.entry()?;
        match entry.delete_credential() {
            Ok(()) => Ok(()),
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(AuthError::Keyring(e.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> StoredTokens {
        StoredTokens {
            access_token: "at".into(),
            refresh_token: "rt".into(),
            access_expires_at: Some(1_700_000_000),
            scope: "https://www.googleapis.com/auth/tasks".into(),
        }
    }

    #[test]
    fn in_memory_round_trips() {
        let s = InMemoryTokenStore::new();
        assert!(s.load().unwrap().is_none());
        s.save(&sample()).unwrap();
        assert_eq!(s.load().unwrap().unwrap(), sample());
        s.clear().unwrap();
        assert!(s.load().unwrap().is_none());
    }

    #[test]
    fn stored_tokens_serialize_round_trip() {
        let t = sample();
        let j = serde_json::to_string(&t).unwrap();
        let back: StoredTokens = serde_json::from_str(&j).unwrap();
        assert_eq!(t, back);
    }
}
