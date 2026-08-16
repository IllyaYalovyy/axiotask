# Security and privacy design

## Threat model

Axiotask protects against accidental repository disclosure, log/screenshot
leakage, another unprivileged local application reading credentials, stolen
OAuth bearer tokens, malformed/untrusted API data, unsafe external links, and
cross-account cache mixing.

It does not claim to protect task contents from an attacker who controls the
running OS user session, a rooted Android device, or a compromised Google
account. Android device encryption/application sandboxing and Fedora user/home
security are part of the cache-at-rest boundary. Full database encryption is
not selected initially; see [DEPENDENCIES.md](DEPENDENCIES.md) for the tradeoff.

## OAuth

- Use the minimum scopes required for Google Tasks plus identity needed to bind
  cache data to the correct Google subject.
- Android uses the maintained Flutter Google identity integration and system
  consent UI.
- Linux uses the system browser, loopback redirect, PKCE S256, cryptographically
  random state and verifier, exact redirect/state validation, and short-lived
  callback listeners.
- Linux sender-constrains the long-lived refresh token with DPoP. A
  per-installation P-256 private key is kept in secure storage and signs a unique
  ES256 proof for every authorization-code exchange and refresh, including
  Google's DPoP nonce. The resource access token remains a short-lived bearer
  token as documented by Google.
- Embedded web views and custom URI-scheme shortcuts are forbidden.
- An installed-app client secret is not treated as confidential or as proof of
  client identity.
- Refresh/access tokens and DPoP private keys are nevertheless confidential user
  credentials and are stored only through platform secure storage where
  persistence is needed.
- Authorization codes, tokens, PKCE verifiers, and full callback URLs never
  enter logs.

## Credential lifecycle

Linux secure storage is wrapped by a narrow `CredentialStore` with explicit
read/write/delete outcomes. There is no plaintext fallback. Android authorization
state is owned by `google_sign_in`; Axiotask does not copy an Android refresh
token into its own storage.

On Linux the refresh token and DPoP private key are encoded together as one
strict, versioned bundle beneath one validated application namespace. Initial
storage and replacement therefore cannot expose a usable half-bundle.
Replacement and deletion are verified by exact read-back, including after a
plugin error that may have followed a commit. An absent value is reported as no
saved authorization. Locked, unavailable, denied, malformed, and unverified
states are distinct failures; no exception detail or secure-store value reaches
diagnostics.

Malformed storage is not silently reset. It remains an actionable
reauthorization failure until a later complete replacement repairs it. Probe
cleanup and any future reviewed credential lifecycle delete only the exact
namespaced bundle key; global secure-store deletion is prohibited because it
could affect another composition or application use.

Stopping synchronization changes only the durable account-scoped sync-enabled
flag. It does not delete or revoke credentials, delete cached task data, or
discard pending changes. While stopped, no new Google request is started and the
UI remains explicitly Inactive with reason `syncStopped`.

Account removal, local sign-out, Google authorization revocation, and their
credential-deletion recovery behavior are not initial product features. They
must receive a separate reviewed lifecycle design before implementation.

## Local task data

- Runtime data is account-scoped by stable Google subject.
- Database and support directories are created with user-only permissions where
  the platform exposes meaningful POSIX modes.
- Database backup/export and restore/import are explicit user safety features.
  Export clearly identifies that the resulting file contains task data. Import
  validates the entire input before mutation, preserves account isolation, and
  cannot bypass the durable Google synchronization pipeline.
- Version-1 account export accepts only the typed supported projection and
  repeats the exact warning “This file contains private Google Tasks data.
  Store and share it carefully.” in the document and export UI. The save dialog
  identifies a private backup. Credentials, authorization state, sync evidence,
  diagnostics, preferences, and raw storage rows are structurally unavailable
  to the encoder.
- An unreadable/corrupt database and its WAL/SHM companions are preserved in
  place; they are not automatically quarantined, rewritten, or replaced with
  an empty cache. Validation operates on a private temporary copy that is
  removed immediately after the check.
- Tests and screenshot modes use separate temporary roots and synthetic data.
- Reset Local Data is an explicit selected-account action with a destructive
  warning. It deletes no credential or device-preference key and cannot target
  another account partition. Development/test reset additionally requires the
  exact isolated database boundary and dedicated account guard; a missing or
  mismatched subject fails before the transaction.

## Configuration

Development OAuth identifiers/configuration are supplied through documented,
ignored local files or platform configuration. A sanitized example containing
placeholders may be committed. Required fields are strictly validated.

Missing/malformed configuration disables connection with a precise diagnosis;
the application does not guess, silently create a production-looking default,
or scan the developer's home directory for credentials.

Client identifiers that are public by OAuth design are still kept out of this
repository when they identify a developer's Google Cloud project.

## Network and API data

- HTTPS Google endpoints are fixed in production composition.
- Redirects, timeouts, body-size bounds, content types, and JSON shapes are
  validated explicitly.
- Unknown enum values and malformed identifiers become typed failures, not
  unchecked casts or silently invented values.
- Retry policy honors safe operation semantics and server guidance; it is not a
  generic HTTP interceptor.
- Task content is untrusted text and is never interpreted as markup.
- External links allow only explicitly supported schemes (`https`, and `http`
  where intentionally accepted) after parsing; shell invocation is forbidden.

## Diagnostics

Production and development diagnostics are separate security products, not two
verbosity settings on the same unrestricted logger.

The **production diagnostic sink** accepts structured safe fields: stable
event/error code, operation kind, phase, duration, status class, retry count,
aggregate counts, and a sanitized cause. It rejects task titles/notes, email
addresses, raw remote IDs, raw request/response bodies, SQL values, and full URLs
with query parameters.

The release-safe history and sensitive-development history use separate
versioned application-support files and product discriminators. They retain the
newest 500 and 1000 records respectively; each event accepts at most 32 fields
and each rendered value is bounded. Reopen reapplies the record bound before
new events are accepted.

The **development sensitive sink** exists only in debug development
composition. It records enough local evidence to investigate content-dependent
and state-dependent failures without sampling or suppressing failures or
boundary/state transitions: task titles/notes, decoded Google request and
response data, redacted authorization state/errors, remote IDs,
desired-state/attempt/coordinator transitions, database operations/values,
repository/UI commands, stack traces, and timing. Debug builds label this
history as containing private task data and expose a searchable live view with
copy, explicit export, and clear actions. Its files and exports are bounded,
local, and ignored by Git. They are never loaded from or written to normal
release diagnostic storage.

Some data is forbidden in **every** sink: bearer and refresh tokens,
authorization headers and codes, client secrets, PKCE verifiers, DPoP private
keys, secure-store values, and unredacted OAuth callback URLs. Redaction occurs
at the sensitive adapter boundary before an event can reach either sink; a
debug flag cannot bypass it.

Tests feed recognizable credential and task-content canaries through every
error path. Production output must contain neither. Development output must
retain the task-content canary needed to reproduce the issue while still
excluding every credential canary. A release-composition test proves that the
sensitive sink and renderer cannot be constructed or enabled at runtime.
Credential-shaped material is scrubbed even when a producer mistakenly labels
its field safe; explicitly credential-classified fields are dropped entirely.

There is no telemetry, remote crash reporting, or automatic diagnostics upload.

Backup import treats selected JSON as bounded untrusted private data. The file
adapter reads no more than 64 MiB and rejects invalid UTF-8; the strict v1 codec
rejects unknown fields, unsupported versions/values, invalid identity or
hierarchy references, and excessive counts before a database write. Release
errors expose no paths, subjects, remote IDs, task content, or raw JSON. A
backup cannot supply credential, authorization, sync, diagnostic, preference,
or database-row state to the restore transaction.

## Repository checks

Before every commit:

- inspect the staged diff;
- scan for secrets, personal data, absolute local paths, private hostnames,
  generated credentials, screenshots, databases, and AI-only files;
- verify ignored local authentication and test-account files remain untracked.

Before every push, repeat the repository-wide privacy scan. A false positive is
reviewed and narrowly documented; the check is never disabled globally to make
a commit pass.

`scripts/privacy_check.sh` implements the scaffold check over tracked and
non-ignored working-tree files. It rejects orchestration/diagnostic/output
artifacts, credential-shaped content, absolute developer-home paths, and AI
attribution. `test/privacy_check_test.sh` exercises a clean synthetic Git
fixture and each rejection class without loading normal credentials or data.
