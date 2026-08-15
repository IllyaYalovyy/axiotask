# Axiotask Flutter

Axiotask is a native Flutter client for Google Tasks on Fedora GNOME and
Android. The current foundation provides a minimal launchable shell,
constructor-injected core/authorization/diagnostic boundaries, and the
versioned Drift/SQLite persistence foundation. Linux additionally has a
capability-proven GNOME Secret Service credential boundary and a Linux system-
browser authorization adapter. A strict, injected Google Tasks HTTP boundary
can read validated list/task pages and issue strict typed mutations;
synchronization orchestration and task workflows arrive only in their approved
later slices.

## Supported development environment

- Fedora Linux 43 or a later supported Fedora release with GNOME.
- Flutter stable `>=3.44.0 <3.45.0` (validated with `3.44.8`).
- Dart `>=3.12.0 <3.13.0` (validated with `3.12.2`).
- Android SDK 36.1, Android SDK Build-Tools 36.1, Android Platform-Tools, and
  an API 36.1 emulator or attached Android device.
- JDK 21, either Fedora OpenJDK or Android Studio's bundled JDK.

Install the Fedora build prerequisites:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel \
  libsecret libsecret-devel gnome-keyring libstdc++-devel \
  java-21-openjdk-devel
```

Install Flutter `3.44.8` from the official Flutter archive, add its `bin`
directory to `PATH`, and use Android Studio's SDK Manager to install the Android
components above. Then verify both toolchains:

```bash
flutter config --enable-linux-desktop
flutter doctor -v
```

The Linux and Android sections of `flutter doctor -v` must pass before building.
Chrome and unsupported Apple/Windows targets are not required.

## Clean-checkout setup

```bash
git clone --branch flutter2 --single-branch \
  https://github.com/IllyaYalovyy/axiotask.git axiotask_flutter2
cd axiotask_flutter2
flutter pub get
./scripts/quality.sh
```

`pubspec.lock` is committed. Do not run a dependency upgrade as part of normal
setup. SQLite is supplied as a native asset by the locked `sqlite3` package; do
not install `sqlite3_flutter_libs` or a system SQLite development package.
Linux secure storage requires an active Secret Service in the user session;
GNOME normally supplies it through `gnome-keyring`.

## Linux build, local launch, and development run

Build the relocatable debug bundle and launch it directly:

```bash
flutter build linux --debug
./build/linux/x64/debug/bundle/axiotask
```

For a normal production-safe development session with hot reload:

```bash
flutter run -d linux --debug -t lib/main.dart
```

System-wide packaging or installation is deliberately out of scope.

## Compile-time application compositions

Composition is selected only by the Dart entry point. The release root has no
runtime option that can construct sensitive diagnostics:

| Composition | Entry point | Google access | Diagnostic boundary |
|---|---|---|---|
| Production-safe | `lib/main.dart` | No Google service is composed in the current shell | Safe structured fields only |
| Sensitive development | `lib/main_development.dart` | Must match an explicit dedicated-account subject before any Google read or mutation | Local private context retained; credentials always redacted |
| Synthetic test | `lib/main_test.dart` | Disabled; injected synthetic authorization only | Safe in-memory history |

Run the synthetic composition with a unique lowercase instance name:

```bash
flutter run -d linux --debug -t lib/main_test.dart \
  --dart-define=AXIOTASK_TEST_INSTANCE=manual-synthetic
```

Run sensitive development only with a dedicated Google account. Obtain that
account's stable Google subject through the later opt-in authorization probe;
do not use an email address and do not guess it. Supply it at compilation:

```bash
flutter run -d linux --debug -t lib/main_development.dart \
  --dart-define=AXIOTASK_DEVELOPMENT_ACCOUNT_SUBJECT=<dedicated-subject>
```

Omitting the subject is safe: the dedicated-account guard rejects every Google
access attempt. A mismatched authenticated subject also fails before a Tasks
read or mutation. The current application entry points do not yet compose the
strict HTTP service, so launching these shells does not enumerate Google data.

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
uncertain results for later synchronization work.

Each composition injects a distinct database filename, preferences namespace,
secure-storage namespace, OAuth-configuration identity, and diagnostic
namespace. Synthetic instance names additionally partition parallel runs. The
production database factory resolves only its injected filename in the native
application-support directory. The current shell does not open it until a later
composition slice wires repositories; diagnostic history remains in memory and
preferences/secure storage are not created. Development and synthetic database
names never equal the normal `axiotask.sqlite` name.

Sensitive development diagnostics may retain synthetic or dedicated-account
task/API/storage context locally. Production diagnostics discard private fields.
Both paths redact credential fields and recognizable authorization material,
including bearer/refresh tokens and OAuth callback URLs, before storage. There
is no telemetry, automatic upload, or committed diagnostic output.

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

## Isolated Google Tasks mutation probe

The S07 P7/P12-style probe is destructive only to uniquely prefixed disposable
data in the pinned dedicated account. It creates two scratch lists, proves JSON
`null` clearing for synthetic notes and due values, moves a synthetic task
between those lists, and exercises DELETE through its stale source-list path.
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

This scaffold does not read credentials, application storage, or Google Tasks.
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

Before the Linux browser authorization slice, confirm `pkg-config --exists
libsecret-1` succeeds and run the app from a GNOME user session with Secret
Service available, then run:

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
flutter test test/app/composition/composition_test.dart
flutter test test/app/composition/isolation_test.dart
flutter test test/data/database/app_database_test.dart
flutter test test/data/database/file_database_test.dart
flutter test test/data/database/native_database_probe_test.dart
flutter test test/data/auth/linux/secure_credentials_test.dart
flutter test test/data/google_tasks/decoder_test.dart
flutter test test/data/google_tasks/http_service_test.dart
flutter test test/data/google_tasks/mutation_http_service_test.dart
./scripts/check_generated.sh
./test/privacy_check_test.sh
./scripts/privacy_check.sh
```

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
