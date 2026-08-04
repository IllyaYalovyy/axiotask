# RFC-010: Android Auth via Play Services AuthorizationClient

| Field         | Value                                      |
|---------------|--------------------------------------------|
| Status        | Accepted                                   |
| Author(s)     | Illya Yalovyy                              |
| Supersedes    | the Android portion of [[RFC-001-auth-oauth-pkce]] (#158) |
| Superseded by | —                                          |

---

## Summary

Google sign-in on Android is broken and cannot be fixed within the #158 design:
Google **rejects all custom URI scheme redirects on Android** ("Custom URI
schemes are no longer supported on Android and Chrome apps" — [OAuth 2.0 for
iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app));
the loopback redirect is deprecated on Android too. Every consent attempt dies
with `Error 400: invalid_request` before consent is even shown (#165, first
on-device run 2026-08-02). This RFC replaces the Android redirect-based flow
with Google's sanctioned mechanism: the Play Services
[`AuthorizationClient`](https://developer.android.com/identity/authorization)
reached through a small in-repo Tauri mobile plugin. Desktop auth (loopback
PKCE, RFC-001) is untouched.

---

## Goals

- **G1** — Working Google sign-in on a real Android device, on the mechanism Google supports and recommends for Android.
- **G2** — `axiotask-core` stays free of Android/Tauri dependencies; the sync engine and `AuthedClient` are unchanged (the plugin plugs in via the existing `RefreshFn` seam).
- **G3** — The custom-scheme machinery from #158 is erased without trace, per project principle: no compat paths, no dead constants, no references in code, tests, or docs.
- **G4** — No OAuth token material persisted by the app on Android — Play Services owns the grant (strictly better than the `tokens.json` it replaces).
- **G5** — A live on-device sign-in plus one authorized Tasks API call is a **merge gate** for this work (the #158 lesson: an auth flow is not done until it has run against the real endpoint).

## Non-Goals

- **NG1** — iOS. (Custom-scheme PKCE remains Google-supported on iOS; when iOS lands it gets its own flow.)
- **NG2** — Any change to desktop auth, token storage, or the sync engine.
- **NG3** — Multi-account.
- **NG4** — Devices without Google Play Services (de-Googled ROMs): they stay in local-only mode, which is already fully functional. Accepted limitation — the only thing sign-in buys is sync with Google's own service.

---

## Background & Motivation

#158 shipped browser-consent PKCE with a `com.axiotask.app:/oauth2redirect`
custom-scheme redirect delivered through `tauri-plugin-deep-link`. The pattern
is the IETF standard for native apps (RFC 8252) and is what Google still
supports on iOS and desktop — but Google has closed it on Android specifically,
in favor of Play Services. No console configuration can re-enable it. The flow
had never executed on a device before merge; the first real run (2026-08-02)
failed at Google's front door.

What Google supports on Android today:

- **Authorization** (what we need — an access token for the `tasks` scope):
  `Identity.getAuthorizationClient(activity).authorize(request)` from
  `play-services-auth`. After the first consent it returns access tokens
  **silently**; when user interaction is needed it returns a `PendingIntent`
  the app launches to show Google's account picker + consent UI. The client is
  identified by the app's **package name + signing-certificate SHA-1** matched
  against the registered Android OAuth client — no client id or secret ships
  in the binary at all.
- **Authentication** (Sign in with Google / ID tokens via Credential Manager):
  **not needed** — we never establish user identity, we only call the Tasks
  API. Do not add it.

## Considered Options

### Option A — HTTPS App Links redirect

Keep browser-consent PKCE; register a Web-type OAuth client with an `https://`
redirect on a domain we control, serve `assetlinks.json`, declare a verified
App Link so the OS routes the redirect back into the app.

**Pros**: keeps the flow vendor-neutral and in our code; PKCE path reused as-is.
**Cons**: requires owning + serving a domain forever; Web clients expect the
client secret at code exchange (an installed app can't hold one honestly);
App-Link verification is a notorious source of silent breakage; still a
browser round-trip on every re-consent.

### Option B — Play Services `AuthorizationClient` via a Tauri mobile plugin

**Pros**: the mechanism Google builds for and won't break next; silent token
renewal after one consent; no token material or client id in the app; no
domain, no secret, no redirect at all; smallest on-device UX (native sheet).
**Cons**: a small Kotlin plugin to write and maintain; ties Android sign-in to
devices with Play Services (NG4); token acquisition is not exercisable in
plain unit tests (mitigated in Testing).

---

## Decision

**Chosen option: Option B** — user ruling 2026-08-02 ("the Play Services
plugin is the obvious answer"). Sign-in on Google's platform uses Google's
platform mechanism.

---

## Design

### Token model on Android (the real change)

The app stops owning tokens on Android. Play Services holds the grant; the app
asks for an access token whenever it needs one:

- First sign-in: `authorize()` reports interaction required → plugin launches
  the `PendingIntent` → account picker + consent → access token returned.
- Every later need (including expiry): `authorize()` returns a fresh token
  silently. There is no refresh token to store, so on Android `tokens.json` is
  never written and `TokenStore` holds nothing.
- `needs_reauth` maps to `authorize()` demanding interaction outside a
  sign-in gesture (grant revoked from Google's side).

`AuthedClient` is unchanged: it already takes a pluggable `RefreshFn`
(`crates/axiotask-core/src/auth/client.rs`). Desktop keeps the
token-endpoint refresh; Android's `RefreshFn` calls the plugin. On 401 the
existing retry path just ends up asking Play Services for a new token.

### The plugin

In-repo Tauri v2 mobile plugin (`crates/tauri-plugin-google-auth/`, Kotlin
side generated by the Tauri plugin scaffold), wrapping
`com.google.android.gms:play-services-auth`:

- `authorize(interactive: bool) -> { access_token: String }` — requests scope
  `https://www.googleapis.com/auth/tasks` only. Non-interactive calls never
  show UI (background sync must not pop consent); interactive calls may launch
  the `PendingIntent` and await its result.
- `sign_out()` — drops the account association so the next sign-in shows the
  picker. Local `logout()` semantics (switch to offline client) are unchanged.
- No `requestOfflineAccess`: that is the server-auth-code path and would need
  a Web client id + backend. We want on-device tokens only.

### GCP configuration

The existing Android OAuth client (package `com.axiotask.app`, debug SHA-1
registered) is exactly what `AuthorizationClient` validates against. The
release-keystore SHA-1 is added to the same client when #162 lands. The
compiled-in `ANDROID_OAUTH_CLIENT_ID` constant is deleted — nothing in the
binary identifies the client anymore.

### Erasure of #158 (no trace)

Removed entirely: `tauri-plugin-deep-link` dependency and init, the
`AndroidManifest.xml` intent-filter, `MobileAuthBridge`, the custom-scheme
body of `start_login_mobile`, `MOBILE_REDIRECT_URI`, `complete_mobile_login`,
`OAuthConfig::google_tasks_mobile`, `ANDROID_OAUTH_CLIENT_ID`, and the mobile
branch of `parse_redirect` docs/tests. `start_login_mobile` remains as the
command entry point but its body becomes: interactive `authorize()` via the
plugin, build the HTTP client with the returned token and the plugin-backed
`RefreshFn`. Desktop loopback parsing stays.

---

## Testing Strategy

- **Unit (core/app)**: a fake plugin bridge behind the same Rust trait the
  real plugin implements — sign-in success path swaps in the HTTP client;
  interaction-required outside a gesture sets `needs_reauth`; 401 retry pulls
  a fresh token from the provider. Standard red-check discipline.
- **Emulator smoke (#161)**: switch the AVD to a **Google-APIs image** so
  Play Services exists; smoke asserts the sign-in gesture reaches the plugin
  and surfaces the native account sheet (full consent can't run headless).
- **On-device merge gate (G5)**: live sign-in on the real phone + one
  authorized `tasklists.list` round-trip, before merge, every time this flow
  changes. This rule exists because #158 merged without it.
- **Untestable in CI**: Google's server-side validation of package/SHA-1 —
  covered only by the on-device gate.

---

## Development Plan

- [x] **Step 1** — Plugin scaffold (`crates/tauri-plugin-google-auth`): Kotlin `authorize`/`sign_out` over `AuthorizationClient`, Rust bindings, Android-only wiring in `lib.rs` *(prerequisite: —)*
- [x] **Step 2** — Rust token-provider trait + fake; Android `RefreshFn` over the plugin; `start_login_mobile` rewritten onto it; silent startup session restore (no re-tap per launch) *(prerequisite: Step 1)*
- [x] **Step 3** — Erase #158 custom-scheme machinery (list above), including its tests and doc references *(prerequisite: Step 2)*
- [ ] **Step 4** — Emulator smoke on a Google-APIs image asserting the sign-in sheet appears *(prerequisite: Step 2)*
- [ ] **Step 5** — On-device gate: live sign-in + authorized Tasks call on the real phone; only then merge *(prerequisite: Steps 3–4)*

---

## Open Questions

- [ ] **Q1** — Sign-out: also revoke at `oauth2.googleapis.com/revoke` with the last access token, or only drop the local association? (Desktop precedent: RFC-001 Q4, still open.)
- [ ] **Q2** — Minimum `play-services-auth` version / minSdk interaction — pin during Step 1.
- [ ] **Q3** — Behavior on Play-Services-less devices: hide the sign-in button via a plugin `is_available()` probe, or show it and surface the plugin error? (NG4 accepts the limitation either way.)
