# Axiotask Flutter

Axiotask is a native Flutter client for Google Tasks on Fedora GNOME and
Android. The current Linux shell opens the versioned, account-scoped
Drift/SQLite store, renders cached Google lists/tasks immediately, and presents
truthful Inactive, Pending, Failed, or Good synchronization health with exact
reason, unresolved counts, and last-success time. It also provides durable
offline list create/rename plus task create/title/notes/due/completion editing,
and explicit Refresh and Stop/Resume actions. List and task edits become visible
only after the projected row and coalesced desired state commit together. Stop
is a durable account-scoped scheduler control: it cancels an active read, prevents
new Google requests, and preserves authorization, cache, and unresolved work;
Resume immediately verifies and catches up. One deterministic coordinator
serializes startup, Linux resume, Refresh, production connectivity-restored
hints, five-minute foreground cadence, and future durable-edit notifications.
Linux remains eligible while its window is minimized or unfocused. Trigger
bursts merge into at most one follow-up; edits use a five-second trailing
debounce capped at ten seconds, and every run has a two-minute monotonic
deadline. Validated pages appear incrementally; only complete durable
finalization can show Synced. Partial, malformed, unavailable, unauthorized, or
timed-out results preserve usable cache under an explicit non-green status.
Eligible provisional list, top-level-task, and child-task creates publish after
complete applicable enumeration in strict list→parent→child order. Each request
is durably claimed first; a canonical response atomically binds the Google ID
and remote base without changing local identity. Independent creates continue
after a conclusive failure, failed dependencies remain unattempted, confirmed
creates never replay, and uncertain creates remain non-green without content
matching until a later run retries the original create generation. Recovery
binds only the first returned Google ID received durably, preserves any newer
edit/move/delete generation, and diagnoses the accepted possibility that an
earlier response-lost create remains as a separate Google resource. Eligible
complete task-content updates and list renames also publish
after enumeration. Base-aware reconciliation selects one whole local or Google
record, gives Google timestamp ties, fails closed without required conflict
evidence, and refetches/replans task PATCH precondition races. Task deletion
hides a supported task/subtree only after a durable tombstone transaction,
offers Undo from that durable state for exactly 30 seconds, and cannot issue a
Google DELETE during the grace window even on Refresh or restart. Expiry strips
the content snapshot and schedules authoritative deletion with positive task
tombstone verification. List deletion has an explicit irreversible
confirmation and no Undo. Response-lost content updates, list renames, and
stable-ID moves are read back by their own complete-record or placement rules
before a newer generation can publish. Response-lost task deletes still require
the stable task tombstone in its current list, while response-lost list deletes
use an exact list-identity read: only a direct 404 confirms deletion, and a live
identity permits one newly claimed replay followed by the same positive check.
Unresolved or failed read-back stays non-green and never acknowledges success.
Every synchronization run now has a durable account-scoped lifecycle. Startup
atomically marks abandoned runs interrupted, converts every claimed mutation to
operation-specific uncertainty, retains partial-page checkpoints and newer
desired generations, and restores one verification obligation before Google
work. Repeating recovery is idempotent, and a late finalizer cannot overwrite a
newer run or advance last verified success. Database startup validates a
temporary copy of an existing main/WAL/SHM set before opening the originals.
Open, schema, integrity, or initial-read failure preserves those files,
constructs no Google transport, and shows Tasks unavailable instead of an
empty account. Retry Open repeats the same non-destructive validation. If
storage becomes unreadable during synchronization, no later Google operation
starts and the same recovery surface replaces the task UI.
The header also exposes Local data recovery for a readable selected account.
It previews every discarded class and requires explicit Reset and rebuild
confirmation. The coordinator cancels and drains active synchronization before
one rollback-safe partition transaction; authorization, device preferences,
and other accounts remain. A successful full Google rebuild is the only reset
outcome labeled healthy, while unavailable Google leaves the empty cache
visibly Failed. Retry Open remains non-destructive and never invokes reset.
The responsive desktop task detail pane reads and edits long multiline notes
as untrusted plain text, preserves null, intentionally empty, and Unicode
content, and shows completed/total progress for direct children. It provides
complete/reopen actions, effective-date provenance, clamped local-calendar
shortcuts, exact date selection, clear, and one restart-durable Undo for every
accepted related-task due cascade. It can create, edit, delete, promote, demote,
or reorder a direct subtask, or move a stable task/subtree between Google lists.
Narrow desktop details provide explicit
Back/Escape behavior, while the wide layout keeps the detail pane visible.
Every action routes through the shared durable task commands. Structure changes
commit durably, survive restart, and
publish through Google MOVE with valid remote `parent`/`previous` anchors.
Canonical response positions replace projected order; competing Google
placement wins without replay while content edits remain independent. Invalid
deeper, missing-anchor, or cross-scope relationships fail before mutation.
Unexpected deeper Google hierarchy keeps the last valid cache visible under an
application failure, records decoded evidence only in sensitive development
diagnostics, and issues no repair mutation. Linux bounded retry,
refresh/Reauthorize, and first-run Connect are wired through the normal
coordinator. Android authorization, lifecycle, and device qualification remain
later work.

The desktop collection also provides one-line quick capture with an explicit
Google-list target. A terminal ISO date or the exact today, tomorrow, next week,
or next month phrase produces a visible stripped-title/date preview before
Enter; dismissing the date keeps the phrase as literal title text. Smart views
show their honest date default before acknowledgement, and every accepted task
uses the same restart-safe desired-state create and Google publication path as
ordinary task creation.

Validated bulk paste accepts either one non-empty task per line or
blank-line-separated paragraphs whose first line is the title and remaining
lines are notes. The dialog previews every task and the Google-list target,
states its 100-task and field bounds, and rejects the whole input if any entry
is invalid. One SQLite transaction acknowledges all tasks or none; each task
then follows ordinary ordered Google create publication with honest pending or
failed sync health.

The desktop collection supports transient multi-select complete, reschedule,
cross-list move, and delete. It validates the entire selection and acknowledges
every affected local projection/desired generation in one transaction or none. A
durable result reports exact confirmed, pending, and failed Google-resource
counts across restart; confirmed remote successes are never rolled back. Bulk
delete creates one durable 30-second Undo group whose complete task/subtree
snapshot restores all selected delete roots or none, including after restart. A
parent plus selected child is one independent MOVE, while due consistency still
records every affected row. Clear completed is a separate confirmed action for
the selected Google list: it has no Undo, deletes eligible completed subtrees
immediately, and preserves every completed parent that still has an unfinished
child.

Fedora users can export the current Google account's supported projected lists
and tasks from the header save action. The strict `axiotask.accountBackup`
version-1 JSON preserves acknowledged offline edits, Google identity when
available, hierarchy, manual order, completion, notes, and due dates. It uses
document-local keys rather than SQLite IDs and excludes credentials,
authorization, synchronization evidence, diagnostics, and preferences. The UI,
native save dialog, and file identify the backup as private task data; a cancel
writes nothing and a successful result reports only the filename and counts.
The same surface restores a completely validated v1 file only after the target
account reports a fresh successful sync. Matching Google identities within the
same Google subject remain unchanged; content is never matched. One transaction
creates every absent provisional record, ordinary desired state, and a durable
document manifest, or creates none. A repeat is a no-op in that local account
partition. Cross-account import or deleted manifest history cannot prevent
duplicates, and the preview states that limitation.

Search finds supported cached tasks by title or notes without crossing account
or protected-data boundaries. A matching subtask is labeled beneath its parent
and opens that parent detail context. Pointer and keyboard activation share the
same result path, while search, compact navigation, detail, selection, and
tracked-dialog state use one deterministic Navigator-backed back stack.

On Fedora, pointer users can drag a top-level task before or after a canonical
sibling while **My order** is selected, or drop it on another Google task list.
The overlay preview and insertion marker never replace repository order;
cancel, invalid targets, local rejection, and Google-canonical failure recovery
cannot leave a false placement. Edge dragging autoscrolls the collection.
Focusable detail buttons for Move up, Move down, and Move to list remain the
equivalent non-pointer route.

The desktop shell also projects Focus, Upcoming, Missed, Unscheduled, All, and
per-list collections from the cached supported task graph. A parent's effective
date is the earlier of its explicit date and unfinished direct-child dates;
children remain detail-only rows. Account-scoped SQLite preferences drive list
order/exclusion plus per-view manual, effective-date, title, or reverse ordering
and completion visibility. Smart-view badges are the exact lengths of the same
projections rendered in the collection.

The cache stores stable local list/task identities separately from nullable,
account-unique Google IDs and retains confirmed remote bases plus page-scope
completeness. Every repository query requires an account partition. Cached rows
are always labeled unverified; even a complete recorded page walk is not a
freshness or healthy-sync claim. Durable account-scoped health facts retain the
last verified success, newest failure, unresolved counts, and scheduler latches;
runtime authorization/connectivity/activity facts are projected separately.
Read walks use durable run rows plus publication/completeness checkpoints and
update last success only during the matching complete finalization. Durable
list/task desired state, dependency metadata, and immutable attempt snapshots
are part of schema version 1; unresolved local work keeps health non-green until
remote confirmation. The exact schema-v1 contract is documented in
[`docs/DATABASE_SCHEMA.md`](docs/DATABASE_SCHEMA.md).

## Supported Linux development environment

- Fedora Linux 43 or a later supported Fedora release with GNOME.
- Flutter stable `>=3.44.0 <3.45.0` (validated with `3.44.8`).
- Dart `>=3.12.0 <3.13.0` (validated with `3.12.2`).

Install the Fedora Linux build and runtime prerequisites:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel \
  libsecret libsecret-devel gnome-keyring libstdc++-devel
```

`libsecret`, `gnome-keyring`, and an unlocked Secret Service are runtime
requirements for authorization storage.

Install Flutter `3.44.8` from the official Flutter archive, add its `bin`
directory to `PATH`, and verify the Linux toolchain:

```bash
flutter config --enable-linux-desktop
flutter doctor -v
```

The Linux section of `flutter doctor -v` must pass before a Linux build.
Android SDK/JDK status, Chrome, and unsupported Apple/Windows targets do not
block Linux development. Android work is sequenced later and then requires SDK
36.1, Build-Tools 36.1, Platform-Tools, an API 36.1 emulator or physical device,
and JDK 21.

## Clean-checkout setup

```bash
git clone --branch flutter2 --single-branch \
  https://github.com/IllyaYalovyy/axiotask.git axiotask_flutter2
cd axiotask_flutter2
flutter pub get
dart run build_runner build --delete-conflicting-outputs
./scripts/quality.sh
```

The generation command must leave the committed generated Dart files
unchanged. `./scripts/quality.sh` checks formatting, generated-source
freshness, static analysis, Flutter tests, shell safety tests, and repository
privacy. It does not read private OAuth configuration or call Google.

The deterministic deep synchronization evidence is a separate, more expensive
local command. It uses only temporary SQLite databases and synthetic Google
state; it never reads OAuth configuration, credentials, or network state.

```bash
./scripts/deep_sync.sh
```

The default command runs the fixed S33 replay corpus twice. To replay one
reported generated failure, run
`AXIOTASK_REPLAY_SEED=<seed> ./scripts/deep_sync.sh`; the seed is the exact
integer printed by a failing model run.

`pubspec.lock` is committed. Do not run a dependency upgrade as part of normal
setup. SQLite is supplied as a native asset by the locked `sqlite3` package; do
not install `sqlite3_flutter_libs` or a system SQLite development package.
`shared_preferences` 2.5.5 is locked for namespaced theme, density, and
onboarding dismissal through `SharedPreferencesAsync`; relational/query and
synchronization settings remain in SQLite.
`connectivity_plus` 7.3.1 observes Linux NetworkManager only for no-route and
may-have-returned scheduling hints; an available interface never proves Google
reachability or healthy sync.
`file_selector` 1.1.0 supplies the Fedora native account-backup save dialog
behind an injected adapter. Android save-dialog behavior is not claimed by this
desktop-first slice.
Linux secure storage requires an active Secret Service in the user session;
GNOME normally supplies it through `gnome-keyring`.

## Linux private configuration, build, run, and local install

The production entry point requires a Google OAuth **Desktop app** client ID
and client secret. Create the ignored private file once and restrict it to the
current user:

```bash
mkdir -p .ktask/gates
chmod 700 .ktask .ktask/gates
touch .ktask/gates/stage7.env
chmod 600 .ktask/gates/stage7.env
```

Open `.ktask/gates/stage7.env` in your preferred text editor without placing
either value in shell history.

Its contents are:

```text
AXIOTASK_LINUX_AUTH_CLIENT_ID=<desktop-client-id>.apps.googleusercontent.com
AXIOTASK_LINUX_AUTH_CLIENT_SECRET=<desktop-client-secret>
```

No account subject, token, or existing authorization is required. A fresh
production app offers **Connect**, obtains and verifies the signed-in Google
subject, and only then creates that account's durable local partition. The
interactive sign-in is therefore separate from build configuration.

Use the checked wrapper for every production run or build:

```bash
./scripts/linux_app.sh run
./scripts/linux_app.sh build debug
./scripts/linux_app.sh build release
```

The wrapper validates that the private file is a mode-`600`, current-user-owned
regular file with both required values before invoking Flutter. It passes only
the filename through `--dart-define-from-file`; it neither sources the file nor
prints its values. Missing, malformed, unignored in-worktree, or incomplete
configuration fails before launch or compilation. Do not replace these commands
with plain `flutter run` or `flutter build`: those commands can compile empty
OAuth constants into an unusable production app.

Debug and release bundles are produced under
`build/linux/x64/<debug|release>/bundle` on supported Fedora x86-64 hosts. To
build and atomically copy a relocatable bundle to a user-selected directory
inside the current user's home, then run and remove it:

```bash
./scripts/linux_app.sh install release "$HOME/.local/opt/axiotask"
"$HOME/.local/opt/axiotask/axiotask"
./scripts/linux_app.sh remove "$HOME/.local/opt/axiotask"
```

Install refuses paths outside the current user's home, existing targets, and
the source worktree.
Remove accepts only a directory carrying the wrapper's local-install marker.
It does not create desktop entries, modify the system, or package the app.
System-wide installation and packaging remain out of scope.

## Linux release acceptance

Run the complete noninteractive Linux gate from a clean worktree:

```bash
./scripts/verify_linux_acceptance.sh
```

It fails fast through `quality.sh`, deterministic deep-sync evidence, every
classified non-live Linux integration test, privacy scanning, an actual
synthetic bundle launch bounded to ten seconds, and configured debug/release
production builds. The smoke bundle is built in a detached temporary worktree,
uses the non-Google synthetic composition, and launches with temporary XDG data,
config, cache, and state roots. Default mode never opens OAuth, calls Google, or
reads a token. It does require the ignored desktop OAuth configuration because
the final production builds are deliberately config-validated.

For final interactive product review, run:

```bash
./scripts/verify_linux_acceptance.sh --human
```

That reruns the noninteractive gate, checks the configured GNOME Secret Service,
prints the concise product checklist, and opens the configured production
release app. It does not declare approval; close the app when review is done.
Only when the dedicated test account is ready, explicitly include the isolated
authorization, secure-storage, and cleanup-backed Google contract probes:

```bash
./scripts/verify_linux_acceptance.sh --human --live-probes
```

`--live-probes` is rejected without `--human`. These commands are Linux release
evidence only; Android remains unverified. The live-account/product observation
is deliberately the remaining evidence for **HUMAN task 56**: do not record
approval until that checklist has been exercised with the dedicated account.

## Compile-time application compositions

Composition is selected only by the Dart entry point. The release root has no
runtime option that can construct sensitive diagnostics:

| Composition | Entry point | Google access | Diagnostic boundary |
|---|---|---|---|
| Production-safe | `lib/main.dart` | Offers first-run Connect, verifies the Google subject before creating its account partition, restores existing Linux authorization, and uses the normal synchronization coordinator; missing build configuration fails visibly and authorization failures remain non-green | Up to 500 persisted safe structured records in `axiotask-diagnostics-safe.json` |
| Sensitive development | `lib/main_development.dart` | Verification and eligible create publication require the explicit dedicated-account subject to match before any Google request | Up to 1000 persisted private-context records in `axiotask-development-diagnostics-sensitive.json`; credentials always redacted |
| Synthetic test | `lib/main_test.dart` | Creates only its isolated synthetic account and verifies against an in-process synthetic read service | Safe in-memory history |

Run the synthetic composition with a unique lowercase instance name through
the same safe command surface:

```bash
./scripts/linux_app.sh synthetic manual-synthetic
```

The first run creates only `axiotask-test-manual-synthetic.sqlite`, displays
Pending while its synthetic walk executes, then displays the validated
synthetic list/task as Synced. A subsequent launch displays that cache
immediately and verifies it again. This composition never loads OAuth
configuration, secure storage, normal preferences, normal diagnostics, or
Google Tasks. Its compile-time composition has `allowsRealGoogle: false`, and
the instance name partitions its SQLite filename and
preferences/credential/diagnostic namespaces from production. The generated
Linux runner retains its compiled native application ID and explicitly uses
`G_APPLICATION_NON_UNIQUE`, so concurrent processes are permitted; isolation
comes from the injected storage and service boundaries, not from a distinct GTK
application ID. Use a new instance name for a separate manual test.

Run sensitive development only with a dedicated Google account. Obtain that
account's stable Google subject through the opt-in authorization probe; do not
use an email address and do not guess it. Add the subject to the ignored,
mode-`600` `.ktask/gates/stage7.env` beside the OAuth values:

```text
AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT=<dedicated-subject>
```

Supply that file at compilation without putting credential values directly on
the command line:

```bash
flutter run -d linux --debug -t lib/main_development.dart \
  --dart-define-from-file=.ktask/gates/stage7.env
```

Omitting the subject or OAuth configuration is safe: the composition fails
closed as No authorization. A mismatched authenticated subject also fails
before a Tasks read. Initial authorization still requires the configured
dedicated account and its composition-specific credential namespace. After a
terminal rejection, S19B wires the Linux Reauthorize action through the same
isolated authorization adapter and requires a matching subject before a full
verification run.

The read service itself is page-oriented so later synchronization can publish
validated pages incrementally. Task-list requests use the documented maximum
page size. Task requests use `maxResults=100`, explicitly include completed,
hidden, and deleted tasks, and keep assigned tasks excluded. Responses must be
JSON within the eight-MiB safety bound; supported fields, etags, tombstones,
timestamps, and UTC-midnight due dates are decoded strictly. A malformed row
fails its scope rather than being skipped. Each attempt has a 30-second timeout,
supports transport cancellation, does not follow redirects, and never retries
inside the adapter.

The mutation service supports task-list create/rename/delete and task
create/complete-snapshot patch/delete/move. It sends task ETags with `If-Match`,
encodes due dates at UTC midnight, uses the live-proven JSON `null` spelling to
clear notes and due, and requires canonical 200 resource or empty 204 responses.
It performs no retries or reconciliation: response loss, malformed success,
unknown responses, and possibly stale source-list paths remain explicit
uncertain results. A separate recovery capability performs the exact task-list
identity GET required to distinguish a live list from a direct 404 without
making generic collection absence into delete evidence. The engine consumes
ordered list/task creates, eligible
complete task-content PATCHes and list-title updates, deletion work, and
structure MOVE work. Confirmed operations and read-proven no-ops are not
replayed; cross-list MOVE keeps the same Google task ID and subtree.

Each composition injects a distinct database filename, preferences namespace,
secure-storage namespace, OAuth-configuration identity, and diagnostic
namespace. Synthetic instance names additionally partition parallel runs. The
production database factory resolves and opens only its injected filename in
the native application-support directory. Development and synthetic entry
points open only their distinct database names and never the normal
`axiotask.sqlite` store. Production and development diagnostics use separate,
versioned files in application support storage; oldest records are removed at
their fixed bounds. Synthetic history remains in memory, and the synthetic
shell never creates preferences or secure storage. Production and development
read transport use only their declared secure-storage namespace.

Sensitive development diagnostics may retain synthetic or dedicated-account
task/API/storage context locally. Production diagnostics discard private fields.
Both paths redact credential fields and recognizable authorization material,
including bearer/refresh tokens and OAuth callback URLs, before storage. There
is no telemetry, automatic upload, runtime sensitive-mode switch, or committed
diagnostic output. The receipt icon in the always-visible synchronization
header opens Diagnostics in one interaction. Both compositions provide live
search, copy-visible, explicit local JSON export, and clear. The development
surface keeps a sensitive-data warning visible; the release entry point imports
and constructs only the production-safe surface.

Explicit exports are written beneath the same application-support boundary as
their source history, in `axiotask-diagnostic-exports/` for release or
`axiotask-development-diagnostic-exports/` for development. The UI reports only
the created filename, not a machine-specific path. Export performs an additional
credential-redaction pass and never uploads or opens the result automatically.

## Linux secure credential storage

`flutter_secure_storage` 10.3.1 is locked with its resolved Linux implementation
3.0.2. The adapter stores the refresh token and DPoP private key together as one
versioned JSON value in GNOME Secret Service. The application namespace is part
of the one key, and no token or key is written to SQLite, preferences, a file,
or a fallback store.

An absent value means no saved authorization. A locked login keyring asks the
user to unlock and retry; unavailable Secret Service or denied access produces
an actionable configuration failure. A malformed or unsupported bundle is
preserved and requires reauthorization rather than being silently deleted. A
later successful complete replacement repairs that state. Replacement and
deletion are read back before success; an operation that throws after committing
is accepted only when the exact resulting state can be verified.

The native capability probe requires an unlocked GNOME session and is
deliberately opt-in. It writes only fixed synthetic canaries beneath a dedicated
probe namespace, verifies store/read/replace/delete, and removes only that key
in a `finally` cleanup. It never reads normal application credentials:

```bash
AXIOTASK_RUN_LINUX_SECURE_STORAGE_PROBE=1 \
  ./scripts/probe_linux_secure_storage.sh
```

The probe presents no expected user dialog. If Secret Service unexpectedly
presents one, stop and review it rather than accepting the run unattended.

## Isolated Linux Google authorization probe

The S05 development probe uses the system browser, an ephemeral
`127.0.0.1` callback, PKCE S256, state and OpenID nonce validation, DPoP, and a
dedicated Secret Service namespace. It reads at most one task-list summary and
does not create, update, or delete Google Tasks data. The authenticated Google
subject is pinned in ignored private development state before the first Tasks
request; a different account fails closed.

Put the dedicated development OAuth client's ID and secret in the ignored file
`.ktask/gates/stage7.env` with mode `600`:

```text
AXIOTASK_LINUX_AUTH_CLIENT_ID=<desktop-client-id>
AXIOTASK_LINUX_AUTH_CLIENT_SECRET=<desktop-client-secret>
```

Run the preflight and the explicitly opted-in probe from an unlocked GNOME
session:

```bash
./scripts/preflight_capability_gate.sh linux-auth
AXIOTASK_RUN_LINUX_AUTH_PROBE=1 ./scripts/probe_linux_auth.sh
```

The probe displays pending, success, or a selectable failure report in its own
window. Development failures include safe phase/classification diagnostics and
a stack trace in the launching terminal; OAuth codes, tokens, client secrets,
PKCE verifiers, DPoP private keys, and callback URLs remain redacted. The probe
verifies restart/refresh behavior and deletes only its isolated credential
bundle afterward. It never reads or changes normal Axiotask credentials or
local data.

The application synchronization boundary refreshes once only for the exact
structured read rejection admitted by the controlled P11 evidence. A second
rejection, terminal refresh, missing Tasks scope, or subject mismatch persists
an account-scoped reauthorization latch. Cached tasks and durable pending intent
remain visible and untouched; restart suppresses further Google work and shows
Inactive / No authorization with Reauthorize. Cancelling leaves the latch in
place. A matching successful Reauthorize clears it and starts a complete
verification, which remains Pending until that run finalizes successfully.
Unknown 401/403 shapes and mutation-side authorization-like responses are never
blindly replayed.

## Isolated Google Tasks mutation probe

The S07 P7/P12-style probe is destructive only to uniquely prefixed disposable
data in the pinned dedicated account. It creates two scratch lists, proves JSON
`null` clearing for synthetic notes and due values, moves a synthetic task
between those lists, and exercises DELETE through its stale source-list path.
It also completes a fresh local sync, imports one synthetic list/task through
the S30B transaction, publishes them through the normal sync engine, and reads
them back from Google.
It preserves that stale-path outcome as uncertain and performs a positive
destination read-back. Cleanup deletes both scratch lists, confirms no matching
prefix remains, deletes only the probe's separate secure-storage bundle, and
verifies that deletion.

Use the same ignored mode-`600` OAuth configuration and pinned subject as the
Linux authorization probe, then opt in explicitly:

```bash
AXIOTASK_RUN_GOOGLE_TASKS_MUTATION_PROBE=1 \
  ./scripts/probe_google_tasks_mutations.sh
```

The command opens the system browser. Complete authorization only with the
already pinned dedicated test account. The subject mismatch guard runs before
any Google Tasks enumeration or mutation.

## Full Google Tasks contract suite

The S34A contract suite is a separate, destructive, dedicated-account check;
it is intentionally not part of `quality.sh`. It uses the same ignored
mode-`600` Linux OAuth client configuration and pinned subject as the
development application. Authorization is restored from the development
application's secure DPoP credential bundle. If that bundle is absent or no
longer usable, this one acceptance command opens the normal system-browser
authorization flow and replaces it through the shipped authorization adapter:

```bash
AXIOTASK_RUN_GOOGLE_CONTRACT=1 ./scripts/test_google.sh
```

The suite has no raw access-token or refresh-token configuration. It executes
through the shipped `LinuxAuthorization`, secure storage, account guard, and
`HttpGoogleTasksService` boundaries. The account guard checks the pinned
dedicated subject on every Tasks operation. The suite uses a fresh
`axiotask-contract-probe-<UTC>-<random>` prefix and deletes only matching
scratch lists in final cleanup. It prints that safe prefix before its first
mutation so an interrupted run can be cleaned precisely. Ordinary and recurring
link navigation belongs to the final Linux HUMAN approval gate. If an
interrupted process leaves a reported prefix, remove only that exact prefix:

```bash
AXIOTASK_RUN_GOOGLE_CONTRACT_CLEANUP=1 \
AXIOTASK_GOOGLE_CONTRACT_CLEANUP_PREFIX=axiotask-contract-probe-YYYYMMDDTHHMMSSZ-abcdef \
./scripts/cleanup_google_contract.sh
```

The cleanup command verifies the prefix syntax, dedicated subject, and zero
remaining matching lists through the same application adapters. It never
accepts a broad cleanup target.

## Android build, local installation, and development run

Build the debug APK:

```bash
flutter build apk --debug
```

Start an Android Studio AVD or an isolated command-line emulator, then obtain
its ID:

```bash
flutter emulators
flutter emulators --launch <emulator-id>
flutter devices
```

Install the built debug APK and launch a hot-reload development session using
the device ID printed by `flutter devices`:

```bash
flutter install --debug -d <device-id>
flutter run --debug -d <device-id>
```

The Android shell may open its own selected composition database but does not
read credentials or Google Tasks and does not run background synchronization.
Future real-service tests must use the dedicated isolated configuration defined
by the accepted testing and security documents.

## Interactive authorization capability gates

Real authorization work is opt-in and uses an ignored, private configuration
file. Create `.ktask/gates/stage7.env`, set its permissions to `600`, and add
only the values required by the platform being proved:

```text
AXIOTASK_ANDROID_AUTH_CLIENT_ID=<android-oauth-client-id>
AXIOTASK_LINUX_AUTH_CLIENT_ID=<linux-oauth-client-id>
AXIOTASK_LINUX_AUTH_CLIENT_SECRET=<linux-oauth-client-secret>
```

Do not invent or preconfigure a Google account subject. The authorization
capability proof obtains the stable `sub` claim from the authenticated identity,
records it only in ignored private development storage, and pins subsequent
development access to that exact subject before any Google Tasks request.

Never use a normal personal account, put these values on a command line, or
commit this file. Before the Android authorization slice, connect, unlock, and
authorize exactly one physical Google Play Services device, then run:

```bash
./scripts/preflight_capability_gate.sh android-auth
```

Before interactive Linux authorization or final human review, confirm
`pkg-config --exists libsecret-1` succeeds and run from a GNOME user session
with Secret Service available, then run:

```bash
./scripts/preflight_capability_gate.sh linux-auth
```

These checks disclose no configured value and only prove that required inputs
are present. The following opt-in probes must still establish actual behavior.

## Verification

The normal fail-fast local gate is:

```bash
./scripts/quality.sh
```

It verifies formatting, strict analysis, all Flutter tests, the privacy
checker's rejection fixtures, generated Drift freshness, and the repository
privacy scan. Useful focused
commands are:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos --fatal-warnings
flutter test test/app_smoke_test.dart
flutter test test/core/failure_outcome_test.dart
flutter test test/core/clock_randomness_test.dart
flutter test test/core/diagnostics_test.dart
flutter test test/data/diagnostics/local_diagnostic_exporter_test.dart
flutter test test/domain/account_backup_codec_test.dart
flutter test test/domain/account_backup_import_planner_test.dart
flutter test test/domain/local_data_recovery_service_test.dart
flutter test test/data/database/account_partition_reset_store_test.dart
flutter test test/features/recovery/local_data_recovery_view_model_test.dart
flutter test test/features/recovery/local_data_recovery_view_test.dart
flutter test test/features/recovery/local_data_recovery_golden_test.dart
flutter test test/data/database/account_backup_repository_test.dart
flutter test test/data/backup/local_account_backup_exporter_test.dart
flutter test test/features/backup/account_backup_view_model_test.dart
flutter test test/features/backup/account_backup_view_test.dart
flutter test test/features/diagnostics/diagnostics_view_model_test.dart
flutter test test/features/diagnostics/diagnostics_view_test.dart
flutter test test/features/diagnostics/diagnostics_golden_test.dart
flutter test test/app/composition/composition_test.dart
flutter test test/app/composition/isolation_test.dart
flutter test test/app/first_run_authorization_test.dart
flutter test test/features/settings/settings_view_model_test.dart
flutter test test/features/settings/settings_view_test.dart
flutter test test/data/database/app_database_test.dart
flutter test test/data/database/file_database_test.dart
flutter test test/data/database/native_database_probe_test.dart
flutter test test/domain/task_list_commands_test.dart
flutter test test/domain/task_commands_test.dart
flutter test test/domain/tasks_repository_test.dart
flutter test test/data/database/task_lists_repository_test.dart
flutter test test/data/database/task_edits_repository_test.dart
flutter test test/data/database/hierarchy_repository_test.dart
flutter test test/data/database/structure_repository_test.dart
flutter test test/domain/hierarchy_policy_test.dart
flutter test test/data/database/delete_repository_test.dart
flutter test test/data/database/tasks_repository_test.dart
flutter test test/data/database/sync_health_repository_test.dart
flutter test test/data/database/sync_settings_repository_test.dart
flutter test test/data/preferences/relational_preferences_test.dart
flutter test test/data/preferences/device_preferences_test.dart
flutter test test/data/preferences/preferences_repository_test.dart
flutter test test/domain/effective_due_test.dart
flutter test test/domain/smart_views_test.dart
flutter test test/domain/subtask_progress_test.dart
flutter test test/domain/date_workflow_policy_test.dart
flutter test test/domain/task_links_test.dart
flutter test test/data/links/url_launcher_adapter_test.dart
flutter test test/features/tasks/task_links_widget_test.dart
flutter test test/data/database/due_cascade_repository_test.dart
flutter test test/sync/health/sync_health_test.dart
flutter test test/sync/read_sync_engine_test.dart
flutter test test/sync/create_sync_engine_test.dart
flutter test test/sync/update_sync_engine_test.dart
flutter test test/sync/reconciliation/structure_policy_test.dart
flutter test test/sync/structure_reconciliation_multi_host_test.dart
flutter test test/sync/delete_sync_engine_test.dart
flutter test test/sync/read_sync_process_death_test.dart
flutter test test/sync/process_death_recovery_test.dart
flutter test test/sync/persistence_failure_recovery_test.dart
flutter test test/sync/coordinator/sync_coordinator_test.dart
flutter test test/sync/auth/sync_authorization_recovery_test.dart
flutter test test/sync/auth/sync_reauthorization_coordinator_test.dart
flutter test test/app/foreground_read_coordinator_test.dart
flutter test test/app/linux_platform_adapters_test.dart
flutter test test/features/tasks/tasks_view_model_test.dart
flutter test test/features/tasks/task_detail_view_model_test.dart
flutter test test/domain/quick_capture_parser_test.dart
flutter test test/features/tasks/quick_add_view_model_test.dart
flutter test test/features/tasks/smart_views_view_model_test.dart
flutter test test/features/tasks/adaptive_shell_test.dart
flutter test test/features/tasks/smart_views_widget_test.dart
flutter test test/app/database_recovery_test.dart
flutter test test/features/tasks/adaptive_shell_golden_test.dart
flutter test test/features/tasks/smart_views_golden_test.dart
flutter test test/features/tasks/task_details_golden_test.dart
flutter test test/data/database/search_repository_test.dart
flutter test test/app/navigation_state_test.dart
flutter test test/app/desktop_shortcuts_test.dart
flutter test test/app/desktop_task_drag_test.dart
flutter test test/features/search/search_view_model_test.dart
flutter test test/features/search/search_overlay_test.dart
flutter test test/features/search/search_navigation_golden_test.dart
flutter test test/domain/bulk_capture_parser_test.dart
flutter test test/data/database/bulk_capture_repository_test.dart
flutter test test/features/tasks/bulk_add_view_model_test.dart
flutter test test/features/tasks/bulk_add_widget_test.dart
flutter test test/domain/bulk_task_operations_test.dart
flutter test test/data/database/bulk_task_operations_repository_test.dart
flutter test test/features/tasks/bulk_operations_view_model_test.dart
flutter test test/data/auth/linux/secure_credentials_test.dart
flutter test test/support/fake_auth_test.dart
flutter test test/support/fake_lifecycle_test.dart
flutter test test/support/fake_connectivity_test.dart
flutter test test/support/multi_host_test.dart
flutter test test/support/reference_model_test.dart
flutter test test/support/replay_seed_test.dart
flutter test test/data/google_tasks/decoder_test.dart
flutter test test/data/google_tasks/http_service_test.dart
flutter test test/data/google_tasks/mutation_http_service_test.dart
flutter test test/data/google_tasks/google_tasks_shared_contract_test.dart
flutter test integration_test/offline_list_edits_linux_test.dart -d linux
flutter test integration_test/offline_task_edits_linux_test.dart -d linux
flutter test integration_test/read_slice_linux_test.dart -d linux
flutter test integration_test/create_publish_linux_test.dart -d linux
flutter test integration_test/update_publish_linux_test.dart -d linux
flutter test integration_test/delete_publish_linux_test.dart -d linux
flutter test integration_test/hierarchy_commands_linux_test.dart -d linux
flutter test integration_test/preferences_native_smoke_test.dart -d linux
flutter test integration_test/smart_views_restart_linux_test.dart -d linux
flutter test integration_test/task_details_linux_test.dart -d linux
flutter test integration_test/quick_capture_linux_test.dart -d linux
flutter test integration_test/bulk_capture_linux_test.dart -d linux
flutter test integration_test/bulk_operations_linux_test.dart -d linux
flutter test integration_test/search_navigation_linux_test.dart -d linux
flutter test integration_test/desktop_drag_reorder_linux_test.dart -d linux
flutter test integration_test/diagnostics_linux_test.dart -d linux
flutter test integration_test/account_backup_linux_test.dart -d linux
flutter test integration_test/local_data_recovery_linux_test.dart -d linux
./scripts/check_generated.sh
./test/linux_app_test.sh
./test/verify_linux_acceptance_test.sh
./test/privacy_check_test.sh
./scripts/privacy_check.sh
```

Capture the isolated synthetic Linux states, including persistent
no-authorization with Reauthorize and preserved cached/unresolved work, pending
provisional list and task creates, stopped list/task content edits, active Stop,
stopped Resume, retry waiting/execution/exhaustion, hierarchy controls, and
protected-depth failure, fixed-time light/dark smart views, and long-content
light/dark task details plus effective-date/completion/durable-Undo workflow
states, plus keyboard-focused light/dark quick-capture previews and validated
light/dark bulk-capture preview/result states and title/notes search with child
parent context, plus Fedora desktop interactions at 1024×720 light and
1280×720 dark, plus an in-progress light drag preview and dark canonical
drag-failure recovery, plus bulk-operation selection, exact result, local
confirmation, grouped-delete Undo, and Clear-completed confirmation states,
into the ignored `screenshots/actual/` directory, then inspect each PNG:

```bash
./scripts/capture_linux_health_screenshots.sh
./scripts/capture_linux_diagnostics_screenshots.sh
./scripts/capture_linux_account_backup_screenshots.sh
./scripts/capture_linux_local_data_recovery_screenshots.sh
./scripts/capture_linux_onboarding_screenshots.sh
```

That command also captures `database-recovery.png` at the Linux runner's
1280×720 size. The recovery image contains no path, exception, account
identity, task content, or credential material.

The diagnostics capture command writes `diagnostics-release-light.png` and
`diagnostics-development-dark.png` at the Linux runner's 1280×720 size. Inspect
both images: release must show safe summaries and redaction only; development
must show the persistent warning, allowed synthetic private context, and the
same credential redaction. The runner opens no database, OAuth configuration,
secure storage, or Google connection.

The account-backup capture writes `account-backup-warning-light.png`,
`account-backup-result-dark.png`, `account-restore-preview-light.png`, and
`account-restore-result-dark.png` at 1280×720. Inspect all four: scope, exact v1
contents/exclusions, private-data warning, source mismatch/duplicate limitation,
existing-wins counts, and local acceptance versus Google publication must remain
visible. The runner uses only in-memory synthetic data and opens no storage,
credentials, OAuth configuration, diagnostics, or Google connection.

The local-data-recovery capture writes
`local-data-reset-warning-light.png`, `local-data-reset-rebuilt-light.png`, and
`local-data-reset-failed-dark.png` at 1280×720. Inspect all three for the
destructive class list, already-sent limitation, preserved authorization/device
preferences, Good-only rebuilt claim, and visibly failed empty-cache outcome.
It uses in-memory synthetic state and opens no database, preference, credential,
OAuth, diagnostic, or Google boundary.

## Native SQLite capability probe

The native probe uses the same background-isolate file connection and
application-support path resolver as production. It creates a filename prefixed
`axiotask-native-database-probe-`, writes one fixed synthetic subject, verifies
stream/transaction/checkpoint/close/reopen behavior, records no path or subject,
and removes only its exact database plus WAL/SHM companions.

Run it on Fedora:

```bash
flutter test integration_test/database_native_probe_test.dart -d linux
```

Run it on the dedicated emulator. Then build the Android APK and verify that the
same locked SQLite native asset is packaged for the supported Android ABIs,
including physical-device ARM64. Physical Google Play Services behavior is
validated separately by the authorization slices where hardware matters.

```bash
flutter emulators --launch Axiotask_Test_API_36_1
flutter devices
flutter test integration_test/database_native_probe_test.dart -d emulator-5554
flutter build apk --debug
./scripts/check_android_native_assets.sh
```

Expected facts on both supported platforms are schema version 1, one synthetic
account, SQLite 3.53.4, foreign keys enabled, WAL, synchronous FULL, a 5000 ms
busy timeout, and a 1000-page automatic checkpoint. A failure does not fall
back to an empty database. No screenshots or Google credentials are involved.

There is no hosted CI, packaging workflow, or support for web, Windows, macOS,
or iOS.

## Engineering references

- [Product vision](VISION.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Vertical-slice execution plan](docs/EXECUTION_PLAN.md)
- [Testing strategy](docs/TESTING.md)
- [Security and privacy](docs/SECURITY.md)
- [Dependency decisions](docs/DEPENDENCIES.md)
- [Database schema v1](docs/DATABASE_SCHEMA.md)
