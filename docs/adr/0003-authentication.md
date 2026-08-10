# ADR 0003: Platform-specific Google authorization behind one port

- Status: Accepted
- Date: 2026-08-09

## Problem

Android and Linux have different correct native OAuth integrations. The previous
Android authorization implementation behaved poorly on a physical device, and
the previous desktop app persisted bearer credentials in plaintext.

## Alternatives considered

1. One browser-based Dart OAuth implementation on both platforms. Uniform, but
   discards Android's supported identity/authorization integration and creates
   mobile redirect/lifecycle risk.
2. A custom Kotlin AuthorizationClient plugin plus a Dart desktop flow. Maximum
   control, but repeats fragile platform work already maintained by Flutter.
3. Official Flutter `google_sign_in` on Android; system-browser PKCE/loopback
   OAuth on Linux; both behind one application authorization port.
4. A backend token broker. It could protect refresh tokens, but introduces a
   server, operations, privacy surface, and deployment explicitly outside scope.

## Decision

Choose option 3, conditional on an early physical Android capability proof.
Android requests Google Tasks authorization through `google_sign_in`. Linux uses
the Dart `oauth2` grant implementation with application-owned browser/callback
validation and DPoP sender-constraining of the refresh token. A maintained JOSE
library creates ES256 proofs; the per-installation DPoP key and refresh token use
`flutter_secure_storage`. Android authorization state remains owned by
`google_sign_in`; Axiotask does not persist an Android refresh token. Plaintext
fallback is prohibited.

Authentication identity, Tasks-scope authorization, credential persistence,
and user-visible connection health remain separate states. Platform exceptions
are mapped into one typed authorization failure model.

If the official Android plugin fails the documented real-device gate, stop and
research/report upstream behavior before selecting another integration. Do not
quietly resurrect the failed private plugin approach.

The Linux proof must also verify Google's PKCE/DPoP token exchange and nonce
behavior against a dedicated test account. If the standards libraries cannot be
composed without private protocol hacks, stop and review alternatives rather
than silently dropping DPoP.

## Rationale

Android and Linux have different supported authorization lifecycles. Using the
maintained Android integration and the installed-application browser flow on
Linux avoids a fragile private mobile plugin while keeping platform details
behind one application port. Mandatory device and endpoint proofs prevent this
choice from becoming an assumption-driven workaround.

## Consequences

- Correct platform UX and lifecycle handling outweigh identical implementation.
- The shared application never depends directly on a Google plugin class.
- Linux requires libsecret and an available GNOME Secret Service.
- Linux credential loss includes loss of the DPoP key; recovery is explicit
  reauthorization rather than attempting to detach a bound refresh token.
- Android and Linux adapter contract suites must prove equivalent application
  semantics even though token ownership differs.
- Stopping synchronization preserves authorization, account-scoped tasks, and
  queued work. Sign-out, account removal, and authorization revocation are not
  part of the initial product.
