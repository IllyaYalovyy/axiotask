# Local development and repository workflow

This document defines the workflow before scaffolding. Exact Fedora packages,
Android SDK components, Flutter constraints, build commands, and troubleshooting
will be validated and expanded when the generated Flutter projects exist.

## Supported development targets

- Fedora Linux 43+ with GNOME while the selected Fedora release remains
  supported. Release-readiness testing must also cover the then-current stable
  Fedora release; the application must not depend on Fedora-version string
  checks when the required native libraries and services are available.
- Android through a current supported SDK/emulator and at least one physical
  Google Play Services device for authentication validation.
- Flutter stable 3.44.x / Dart 3.12.x is the researched baseline. The scaffold
  will pin an explicit compatible SDK range and document upgrades.

No effort is allocated to Windows, macOS, iOS, web, distribution packaging,
hosted CI, or release automation.

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

The scaffold will provide one normal entry point:

```text
./scripts/quality.sh
```

It will be deterministic, fail fast with useful output, and invoke formatting,
analysis, generated-code freshness, tests, and privacy checks. Separate explicit
commands will run application integration tests, goldens, actual screenshot
capture, physical-device auth validation, real Google API tests, and the deep
sync oracle.

No command silently selects a real Google account or normal application-data
directory.

## Development versus release diagnostics

The scaffold must provide a clearly named debug development entry point that
composes the sensitive local diagnostic sink and its in-app viewer. It records
all application failures and the boundary/state-transition evidence needed to
reproduce them, including test-account task content and detailed API/database
context, without sampling or suppressing errors. The viewer is one interaction
from sync details and supports live search, copy, explicit export, and clear.
Rotating log files and exports remain inside ignored development storage.

The normal release entry point cannot construct that sink or viewer. It exposes
only production-safe local summaries. Tests must prove the separation; it is
not a convention and cannot be changed with a runtime flag. Credential and
authorization material is redacted before either logging path in every build.

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
