# RFC-001: Authentication via OAuth 2.0 PKCE

| Field         | Value         |
|---------------|---------------|
| Status        | Draft         |
| Author(s)     | Illya Yalovyy |
| Supersedes    | —             |
| Superseded by | —             |

---

## Summary

Establish the project workspace and implement Google OAuth 2.0 with PKCE for
desktop. Store the refresh token in the OS-native keychain and transparently
refresh access tokens on `401`. This RFC is the foundation every later RFC
depends on — without it, no API call can be made.

---

## Goals

- **G1** — User signs in once with Google; the app remains authenticated across launches.
- **G2** — Refresh token is stored in the OS keychain (Secret Service / Keychain / Credential Manager); never written to disk in plaintext.
- **G3** — A `TokenStore` trait exists so tests can run without touching the real keychain.
- **G4** — Access-token refresh-on-`401` happens transparently inside the HTTP client wrapper used by [[RFC-002-google-tasks-api-client]].
- **G5** — Workspace layout (`axiotask-core`, `axiotask-app`) and CI gate (`fmt`, `clippy -D warnings`, `cargo test`) are in place.

## Non-Goals

- **NG1** — Multi-account support.
- **NG2** — In-app account-switching UI.
- **NG3** — Sign-in UX polish (a hidden CLI subcommand is sufficient for MVP foundation).

---

## Background & Motivation

The Google Tasks API requires OAuth 2.0. For installed/desktop apps Google
recommends the PKCE flow with a loopback redirect URI; no client secret is
embedded. Every later phase (sync, UI, etc.) depends on having a valid access
token, so auth must land first and must be testable in isolation.

---

## Considered Options

### Option A — PKCE with loopback redirect

**Pros**: Recommended by Google for desktop apps. No client secret embedded. Standard `oauth2` crate support.
**Cons**: Briefly opens a local HTTP server on an ephemeral port.

### Option B — Out-of-band (copy/paste) code

**Pros**: No local server.
**Cons**: Deprecated by Google; user-hostile.

### Option C — Custom URI scheme (`axiotask://`)

**Pros**: No local port.
**Cons**: Requires OS-level scheme registration per platform; brittle on Linux.

---

## Decision

**Chosen option: Option A** — PKCE with loopback redirect, using the [`oauth2`](https://crates.io/crates/oauth2) crate. Single embedded client ID (public, per [[OAuth-decision-from-plan]]).

---

## Design

- **`axiotask-core::auth`** module exposes:
  - `trait TokenStore { fn load(&self) -> Result<Option<RefreshToken>>; fn save(&self, t: &RefreshToken) -> Result<()>; fn clear(&self) -> Result<()>; }`
  - `KeyringTokenStore` (real impl) and `InMemoryTokenStore` (test impl).
  - `AuthFlow::sign_in()` → spawns loopback server on `127.0.0.1:0`, opens consent URL with `code_challenge`, awaits redirect, exchanges code for tokens.
  - `AuthedClient` — wraps `reqwest::Client`, holds an `Arc<RwLock<AccessToken>>`, refreshes on `401`.
- **Scopes**: `https://www.googleapis.com/auth/tasks` (read+write). Confirm in Open Questions.
- **Workspace layout**: cargo workspace with `crates/axiotask-core` and `crates/axiotask-app` (Tauri binary). `axiotask-core` has **no** Tauri dependency.

---

## Testing Strategy

- **Unit**: `InMemoryTokenStore` round-trip; PKCE `code_verifier` ↔ `code_challenge` derivation; CSRF state validation.
- **Integration**: `wiremock` stands in for Google's token endpoint; refresh-on-`401` test asserts one retry on stale token, no retry on hard `401`.
- **Manual smoke**: hidden CLI `axiotask auth login` against a real GCP test project, gated by env var so CI doesn't depend on it.
- **Untestable**: actual keychain interaction on each OS — tracked in `TECH_DEBT.md` if it proves so.

---

## Development Plan

- [ ] **Step 1** — Cargo workspace scaffold + Tauri 2 + Svelte 5 frontend skeleton *(prerequisite: —)*
- [ ] **Step 2** — CI pipeline: fmt / clippy / test / frontend lint *(prerequisite: Step 1)*
- [ ] **Step 3** — `TokenStore` trait + `InMemoryTokenStore` + tests *(prerequisite: Step 1)*
- [ ] **Step 4** — `KeyringTokenStore` over `keyring` crate *(prerequisite: Step 3)*
- [ ] **Step 5** — PKCE flow w/ loopback redirect, write tests against `wiremock` *(prerequisite: Step 3)*
- [ ] **Step 6** — `AuthedClient` refresh-on-`401` wrapper + tests *(prerequisite: Step 5)*
- [ ] **Step 7** — Hidden CLI subcommand `axiotask auth login` *(prerequisite: Step 6)*

---

## Open Questions

- [ ] **Q1** — Scope: `tasks` (full) vs `tasks.readonly`? MVP needs full.
- [ ] **Q2** — Who owns the GCP project that hosts the client ID? Personal dev project for MVP, organization later?
- [ ] **Q3** — Headless-Linux keyring fallback: prompt user to install Secret Service, or fall back to encrypted file (with passphrase)?
- [ ] **Q4** — Sign-out: revoke refresh token at `oauth2.googleapis.com/revoke` or just delete locally?
