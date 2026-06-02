//! PKCE (Proof Key for Code Exchange) primitives.
//!
//! Pure, no IO. The redirect-flow controller in `client.rs` consumes these.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use sha2::{Digest, Sha256};

/// A generated PKCE verifier and the derived challenge plus method.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pkce {
    /// High-entropy verifier the client keeps secret until the token exchange.
    pub verifier: String,
    /// `S256(verifier)` base64url-no-pad.
    pub challenge: String,
    /// Challenge method literal — always `S256` here.
    pub method: &'static str,
}

/// Parameters expected on the loopback redirect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PkceParams {
    /// Authorization code from Google.
    pub code: String,
    /// State parameter we generated; must match what the client sent.
    pub state: String,
}

impl Pkce {
    /// Generate a fresh verifier (43 bytes of entropy) and its `S256` challenge.
    pub fn generate() -> Self {
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let verifier = URL_SAFE_NO_PAD.encode(bytes);
        let challenge = Self::challenge_for(&verifier);
        Self {
            verifier,
            challenge,
            method: "S256",
        }
    }

    /// Derive the challenge for a given verifier. Public for testing.
    pub fn challenge_for(verifier: &str) -> String {
        let digest = Sha256::digest(verifier.as_bytes());
        URL_SAFE_NO_PAD.encode(digest)
    }
}

/// Generate a random state token (32 bytes base64url-no-pad).
pub fn random_state() -> String {
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_is_deterministic_for_known_verifier() {
        // Test vector from RFC 7636 §4.6.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
        assert_eq!(Pkce::challenge_for(verifier), expected);
    }

    #[test]
    fn generate_produces_unique_verifiers() {
        let a = Pkce::generate();
        let b = Pkce::generate();
        assert_ne!(a.verifier, b.verifier);
        assert_eq!(a.method, "S256");
        assert_eq!(Pkce::challenge_for(&a.verifier), a.challenge);
    }

    #[test]
    fn verifier_meets_rfc_length_minimum() {
        // RFC 7636 requires verifier length 43..=128.
        let p = Pkce::generate();
        assert!(
            p.verifier.len() >= 43,
            "verifier too short: {}",
            p.verifier.len()
        );
        assert!(p.verifier.len() <= 128);
    }

    #[test]
    fn random_state_is_unique() {
        assert_ne!(random_state(), random_state());
    }
}
