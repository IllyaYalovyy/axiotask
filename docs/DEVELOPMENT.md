# Local development and repository workflow

This document defines the local workflow for the generated Linux and Android
Flutter projects. The reproducible setup, build, install, launch, and
verification commands are maintained in the repository [README](../README.md).

## Supported development targets

- Fedora Linux 43+ with GNOME while the selected Fedora release remains
  supported. Release-readiness testing must also cover the then-current stable
  Fedora release; the application must not depend on Fedora-version string
  checks when the required native libraries and services are available.
- Android through a current supported SDK/emulator and at least one physical
  Google Play Services device for authentication validation.
- Flutter stable `>=3.44.0 <3.45.0` and Dart `>=3.12.0 <3.13.0` are enforced by
  `pubspec.yaml`. S00 was validated with Flutter 3.44.8 and Dart 3.12.2.

No effort is allocated to Windows, macOS, iOS, web, distribution packaging,
hosted CI, or release automation.

## Locked scaffold toolchain and dependencies

The S00 lock was resolved on Fedora 43 with Android SDK 36.1.0, Build-Tools
36.1.0, JDK 21.0.8, clang 21.1.8, CMake 3.31.11, Ninja 1.13.1, GTK 3.24.52,
and pkg-config 2.3.0. The generated Android runner pins Android Gradle Plugin
9.0.1, Kotlin 2.3.20, and Gradle 9.1.0.

Direct package dependencies are exact: Flutter and `flutter_test` come from the
locked Flutter 3.44.8 SDK, and `flutter_lints` is 6.0.0. `pubspec.lock` records
the complete exact transitive resolution. Supported ranges permit Flutter patch
updates within 3.44.x and Dart patch updates within 3.12.x; any upgrade still
requires the dependency admission review and both native build gates.

S02 additionally locks `drift` 2.34.3, `sqlite3` 3.5.1 with bundled SQLite
3.53.4 native assets, `path_provider` 2.1.6, `drift_dev` 2.34.5, and
`build_runner` 2.15.1. The generated Drift output is committed. The normal
quality gate regenerates it and fails if any generated Dart file changes.

The version-1 database contains only account identity. File-backed connections
run on a Drift background isolate and measured `foreign_keys=ON`,
`journal_mode=WAL`, `synchronous=FULL`, `busy_timeout=5000`, and
`wal_autocheckpoint=1000` on Fedora and the API 36 Android emulator. Explicit
`wal_checkpoint(TRUNCATE)` is supported and tested. In-memory tests retain
SQLite's required `journal_mode=memory` while using the other selected
settings. Existing files are checked read-only for schema version, exact schema,
integrity, and foreign-key violations before Drift can migrate or create
anything. Unknown, malformed, and corrupt files are closed and preserved.

S04 locks `flutter_secure_storage` 10.3.1 and the resolved Linux implementation
3.0.2. Linux builds require Fedora's `libsecret` and `libsecret-devel` packages;
runtime access requires an active Secret Service, normally `gnome-keyring` in a
GNOME user D-Bus session. The opt-in probe command and exact isolation behavior
are maintained in the README. Normal tests fake the secure-value boundary and
never open Secret Service.

## Branch and commits

Development occurs on the independent orphan branch `flutter2` in the same
remote repository as the Rust reference. The older `flutter` branch is ignored.
Commit identity and message style follow the existing repository, without AI
attribution or co-author trailers.

For each coherent change:

1. write or update the behavioral test/specification;
2. implement the smallest complete slice;
3. format and analyze;
4. run focused tests, then the normal local quality gate;
5. inspect actual screenshots when UI changed;
6. inspect generated files and the complete diff;
7. scan the staged diff for privacy/security issues;
8. commit with a concise imperative subject;
9. repeat the repository privacy check and push `flutter2` directly.

Broken intermediate commits and enormous cross-subsystem commits are avoided.

## Local verification

The scaffold provides one normal entry point:

```text
./scripts/quality.sh
```

It is deterministic, fails fast with useful output, and invokes formatting,
generated-code freshness, analysis, tests, privacy-check fixtures, and the
repository privacy scan. Separate explicit commands run application
integration tests, goldens, actual screenshot capture, physical-device auth
validation, real Google API tests, and the deep sync oracle when those
capabilities exist.

No command silently selects a real Google account or normal application-data
directory.

## Development versus release diagnostics

S01 provides a clearly named debug development entry point that composes the
sensitive local diagnostic sink. The full in-app viewer remains a later UI
slice. The sink records
all application failures and the boundary/state-transition evidence needed to
reproduce them, including test-account task content and detailed API/database
context, without sampling or suppressing errors. When the later viewer slice is
implemented, it is one interaction from sync details and supports live search,
copy, explicit export, and clear. Its rotating log files and exports remain
inside ignored development storage.

The normal release entry point constructs only the production-safe sink and has
no runtime diagnostic-mode flag. Behavioral composition tests prove the
separation. Credential and authorization material is redacted before either
logging path in every build.

`lib/main.dart`, `lib/main_development.dart`, and `lib/main_test.dart` are the
production-safe, sensitive-development, and synthetic-test roots respectively.
Their injected database filename, preferences namespace, secure-storage
namespace, OAuth configuration identity, diagnostics namespace, authorization,
clock, and randomness are distinct. On first authorization, development Google
access obtains the stable account subject from the authenticated identity and
pins it in ignored private development storage before any Google Tasks request.
Later absence or mismatch fails closed; a subject is never guessed or required
before authorization.
The reproducible launch, isolation, and current cleanup commands are maintained
in the repository README.

## `ktask`

`ktask` state is local orchestration, not product source. `.ktask/` remains
ignored. Useful local mechanisms are:

- small ordered tasks with a hard stop on failed verification;
- retry with the previous failure/report context;
- a concise cross-cutting invariant checklist;
- normal fast verification separated from an expensive sync oracle;
- attempt logs and handoff summaries;
- timeouts and explicit external-test opt-in.

Machine-specific executor paths, prompts, transcripts, and agent state must not
be committed. Human-useful decisions discovered during a task are moved into
the product documentation or ADRs.

Interactive capability proofs are preceded by HUMAN queue gates. A gate may be
acknowledged only after its checked preflight command succeeds; missing hardware,
credentials, or desktop services therefore pause orchestration instead of
consuming a failed implementation attempt. The preflight reads only
`.ktask/gates/stage7.env` (or the explicitly named equivalent), requires the
file to be ignored and mode `600`, and never prints configured values. It proves
prerequisite availability, not the behavior that the following slice must test.

Implementation is deliberately Linux-desktop-first. Shared behavior and the
complete Fedora product are implemented, verified, and manually accepted before
Android authorization, lifecycle, UI, device, or release work resumes. Android
remains a supported target; it is sequenced later so unfinished mobile capability
cannot block or dilute desktop completion.

## Documentation map

- `VISION.md`: stable product intent and non-goals.
- `docs/ARCHITECTURE.md`: component boundaries and data flow.
- `docs/adr/`: meaningful decisions and rejected alternatives.
- `docs/SYNC_SPEC.md`: Stage 4 synchronization state machine and guarantees.
- `docs/SYNC_TEST_MATRIX.md`: Stage 4 behavioral evidence plan.
- `docs/FUNCTIONAL_PARITY.md`: Rust behavior disposition and verification.
- `docs/EXECUTION_PLAN.md`: ordered Stage 6 implementation slices and gates.
- `docs/TESTING.md`: local test layers and isolation.
- `docs/UX.md`: adaptive interaction and visual review principles.
- `docs/SECURITY.md`: threat model and privacy controls.
- `docs/DEPENDENCIES.md`: admitted/rejected dependencies and rationale.
- `README.md`: supported build/run/test instructions once executable code exists.

Documentation is updated in the same coherent commit as the behavior it governs.
