# Vertical-slice execution plan

- Status: **Accepted**
- Scope: Flutter implementation on Fedora GNOME and Android
- Updated: 2026-08-12

This plan turns the accepted architecture, synchronization specification, test
matrix, and functional-parity plan into ordered implementation tasks. Every
numbered slice is intended to fit one reliable agent task, leave the branch
buildable, and end in one reviewed commit pushed to `origin/flutter2`.

## Rules for every slice

Before a slice starts, `flutter2` must be clean, current, and tracking its
remote. The implementer reads the cited contracts, writes the smallest test that
fails for the intended reason, implements only that slice, and runs both its
focused checks and the normal local gate. Generated code is committed only when
its source belongs to the slice and regeneration is clean.

Every slice must also:

- keep domain and synchronization behavior independent of widgets;
- use synthetic or dedicated-test-account data and injected storage paths;
- update the cited parity rows from `Not started`/`Not run` only for evidence
  actually completed by that slice;
- update affected architecture, behavior, test, security, or development
  documentation in the same commit;
- inspect significant UI on the affected form factor, including goldens and
  actual screenshots when required;
- run `./scripts/quality.sh`, inspect the complete staged diff, run the staged
  privacy check, commit with the listed subject, push `flutter2`, and confirm a
  clean tracking branch;
- stop without a workaround when a capability gate fails or a required API,
  security, schema, or product decision is not established.

Normal tests never access Google, platform credentials, production application
storage, or wall-clock sleeps. Opt-in probes must fail closed on missing or
mismatched isolation configuration. No slice adds CI, packaging, unsupported
platforms, legacy migration, local-only lists, Android background sync, or
AI-only committed artifacts.

## Dependency shape and earliest useful slice

```text
S00 scaffold
 ├─ S01 core boundaries/build modes
 ├─ S02 SQLite native-assets proof ── S10 cache repository ── S11 health shell
 ├─ S03 Android authorization proof                             │
 ├─ S04 Linux secure storage ── S05 Linux PKCE/DPoP proof       │
 └─ S06 HTTP reads ── S07 HTTP writes/errors ── S08, S09A–C fake ──┤
                                                               ▼
                 S12B first useful end-to-end read/verify slice
                                  │
                 S13A–B scheduling → S14A–S21B sync writes/recovery
                                  │
                 S22A–S32B product workflows and recovery tools
                                  │
                 S33–S35 deep, live, platform, and release gates
```

The capability proofs precede dependent production work because failure changes
the accepted architecture. **S12B is the earliest useful end-to-end slice.** It
launches with cached Google lists/tasks, immediately performs foreground
verification through the real repository/engine boundary, incrementally shows
validated remote data, and displays Pending, Good, Failed, or Inactive from
facts. It does not pretend that authentication, connectivity, or cached data is
successful synchronization.

## Foundation and risky capability proofs

### S00 — Scaffold supported Flutter targets and the local gate

- **Capability:** A developer can build and launch a minimal native Flutter app
  on Linux and Android and run one honest local quality command.
- **Scope / non-goals:** Create only the Flutter package, Linux/Android runners,
  strict analyzer configuration, deterministic smoke test, dependency lock,
  privacy checker, and `scripts/quality.sh`. Do not add product architecture,
  plugins not yet earned, CI, packaging, other platforms, or placeholder checks.
- **Expected modules/files:** `pubspec.yaml`, `pubspec.lock`,
  `analysis_options.yaml`, `lib/main.dart`, `test/app_smoke_test.dart`,
  `scripts/quality.sh`, `scripts/privacy_check.sh`, `linux/`, and `android/`.
- **Tests first:** Add the launch/render smoke test and a privacy-check fixture
  test before the smallest application widget; prove quality fails on formatting,
  analysis, test, and privacy violations.
- **Verification / visuals:** Run format check, analyze, smoke test, quality
  script, Linux debug build/run, and Android debug build. Inspect the minimal
  synthetic screen on Linux and an emulator; no golden baseline yet.
- **Docs / acceptance / gates:** Pin the supported Flutter/Dart range and exact
  dependency versions in development docs. Accept only if both generated targets
  build locally and `quality.sh` contains no fake Flutter checks. Gate: supported
  SDK/toolchains are installed and dependency admission review passes.
- **Commit / push:** `Scaffold Flutter application and local quality gate`;
  push `flutter2`.

### S01 — Establish shared boundaries and verified build compositions

- **Capability:** Developers can run production-safe, synthetic-test, and
  sensitive-development compositions whose differences are compile-time entry
  points, not runtime secret switches.
- **Scope / non-goals:** Add injected clock/randomness, typed `Outcome`/`Failure`,
  authorization and diagnostic ports, credential redaction, and composition
  roots. Do not add task policy, persistence, sync behavior, or full diagnostics
  UI.
- **Expected modules/files:** `lib/src/core/{clock,outcome,failure}.dart`,
  `lib/src/core/diagnostics/`, `lib/src/data/auth/authorization.dart`,
  `lib/src/app/composition/`, `lib/main.dart`, `lib/main_development.dart`, and
  `lib/main_test.dart`.
- **Tests first:** Failure mapping/equality, deterministic time/randomness,
  credential-canary redaction, and a release-composition test proving the
  sensitive sink cannot be constructed or enabled at runtime.
- **Verification / visuals:** Focused core/composition tests plus quality. No
  screenshot is required because no product UI changes beyond the S00 shell.
- **Docs / acceptance / gates:** Document entry points and diagnostic privacy
  boundary. Accept when dependencies are constructor-injected, no service
  locator/global mutable singleton exists, and every credential canary is absent
  from both compositions. Gate: S00.
- **Commit / push:** `Establish application composition boundaries`; push.

### S02 — Prove Drift native-assets SQLite on Linux and Android

- **Capability:** The real production database connection opens, transacts,
  streams, closes, and reopens through Drift/sqlite3 native assets on both
  supported platforms.
- **Scope / non-goals:** Admit Drift, code generation, path resolution, and the
  initial versioned `accounts`/schema metadata foundation. Select and test
  foreign keys, WAL, busy handling, checkpoint, and synchronous settings. Do not
  add task/sync tables or silently recreate corrupt databases.
- **Expected modules/files:** `lib/src/data/database/{app_database,connection,
  schema_verifier}.dart`, generated Drift output, database tests, a native DB
  probe entry point, and generated-code freshness in `quality.sh`.
- **Tests first:** In-memory constraint/transaction/stream tests; temporary-file
  close/reopen, concurrent-read, rollback, malformed-schema, and unavailable
  path tests; native probe records only synthetic non-secret values.
- **Verification / visuals:** Focused persistence tests, regeneration-no-diff,
  quality, Linux native probe, Android emulator probe, and Android APK native-
  asset inspection for ARM64, ARMv7, and x86_64. No screenshots.
- **Docs / acceptance / gates:** Record locked package/native versions and
  measured pragma behavior. Accept only if both platforms use the same schema
  contract and unreadable state never becomes an empty database. Gates: S00 and
  dependency admission; failure stops all persistence-dependent work.
- **Commit / push:** `Prove native SQLite persistence`; push.

### S03 — Prove Android Google authorization on a physical device

- **Capability:** A dedicated physical-device harness connects through the
  official Flutter plugin, authorizes the Tasks scope, calls `tasklists.list`,
  restores after process death, and reports cancellation/reauthorization
  truthfully.
- **Scope / non-goals:** Implement the Android authorization adapter behind the
  shared port and an isolated debug probe. Do not add a private Kotlin auth
  plugin, persist Android refresh tokens, sync task data, or support devices
  without Google Play Services.
- **Expected modules/files:** `lib/src/data/auth/android/`, fake/contract tests,
  Android configuration, `lib/main_auth_probe.dart`, and
  `scripts/probe_android_auth.sh` with ignored configuration/output.
- **Tests first:** Adapter contracts for connect, scope denial, cancellation,
  cached restore, token refresh request, terminal rejection, subject mismatch,
  and Stop Sync preserving plugin authorization.
- **Verification / visuals:** Contract tests and quality, then explicit physical
  device runs for interactive connect, Tasks call, cancel, restart/restore,
  expiry/refresh or reauthorization, and Stop/Resume. Inspect each native consent
  and failure screen; sanitized evidence contains no account/task data.
- **Docs / acceptance / gates:** Update Android setup with the exact plugin/API
  behavior observed. Accept only with real-device evidence for `API-006`'s
  Android portion. Gates: S00–S01 and dedicated account/configuration. Plugin
  failure stops dependent Android work for upstream research.
- **Commit / push:** `Prove Android Google authorization`; push.

### S04 — Prove Linux secure credential storage

- **Capability:** Linux can atomically store, retrieve, replace, and delete a
  synthetic refresh-token/DPoP-key bundle in GNOME Secret Service without a
  plaintext fallback.
- **Scope / non-goals:** Admit and wrap `flutter_secure_storage`; define one
  namespaced credential-bundle contract and recovery failures. Do not begin OAuth
  or touch normal application credentials.
- **Expected modules/files:** `lib/src/data/auth/linux/secure_credentials.dart`,
  fake/contract tests, Linux plugin configuration, secure-store probe entry
  point, and `scripts/probe_linux_secure_storage.sh`.
- **Tests first:** Missing store, locked service, denied access, partial/failed
  replacement, malformed bundle, namespace isolation, deletion failure, and
  credential-canary logging tests.
- **Verification / visuals:** Focused adapter tests, quality, and an opt-in GNOME
  session probe using a dedicated namespace that cleans only that namespace. No
  screenshot unless the platform unexpectedly presents a user dialog.
- **Docs / acceptance / gates:** Record Fedora packages, Secret Service
  prerequisites, exact locked plugin version, and self-healing/actionable failure
  behavior. Gates: S00–S01; any plaintext or silent fallback rejects the slice.
- **Commit / push:** `Prove Linux secure credential storage`; push.

### S05 — Prove Linux browser PKCE, DPoP, and refresh

- **Capability:** Linux connects a dedicated Google account using the system
  browser, loopback PKCE, state validation, a DPoP-bound refresh token, secure
  persistence, and authenticated `tasklists.list`.
- **Scope / non-goals:** Implement the Linux authorization adapter and opt-in
  probe, including ephemeral callback port, cancellation, nonce handling, key
  lifecycle, subject check, and typed recovery. Do not use an embedded webview,
  custom URI workaround, plaintext token, or silently drop DPoP.
- **Expected modules/files:** `lib/src/data/auth/linux/{browser_flow,dpop,
  linux_authorization}.dart`, JOSE/oauth contracts, fake browser/callback/token
  endpoints, probe entry point, and `scripts/probe_linux_auth.sh`.
- **Tests first:** PKCE/state/callback mismatch, port conflict, browser-launch
  failure, cancellation, DPoP claims/signature/nonce rotation, missing/wrong key,
  refresh rejection, secure-store failure, subject mismatch, and secret-redaction
  tests.
- **Verification / visuals:** Focused tests and quality; controlled local token
  server; explicit Google probe for exchange, nonce, refresh, wrong/missing key,
  restart restore, Tasks call, and cancellation. Inspect browser/application
  success and failure states using the dedicated account only.
- **Docs / acceptance / gates:** Record exact endpoint observations and update
  `API-006`. Accept only if the standards libraries compose without private
  protocol hacks. Gates: S04 and ignored dedicated-account configuration;
  failure stops Linux-auth-dependent work.
- **Commit / push:** `Prove Linux PKCE and DPoP authorization`; push.

### S06 — Implement strict Google Tasks read adapter

- **Capability:** The app can strictly enumerate all task-list/task pages and
  decode supported resources through the production HTTP boundary.
- **Scope / non-goals:** Implement read DTOs, exact query flags, pagination,
  etags/tombstones, date-only mapping, bounded decoding, cancellation/timeouts,
  and typed errors. Do not add synchronization policy, retries, writes, or skip
  malformed resources as success.
- **Expected modules/files:** `lib/src/data/google_tasks/{service,http_service,
  dto,decoder,request}.dart`, scripted HTTP server tests, and sanitized
  diagnostic tests.
- **Tests first:** Contract evidence `API-001`–`API-003`, `API-005`, `API-007`,
  `API-008`, read portions of `API-009`, pagination, exact flags/headers, malformed
  body/row, size limit, cancellation, timeout, and release/development canaries.
- **Verification / visuals:** Focused adapter tests and quality. Optional
  dedicated-account read probe only through the isolated harness; no UI review.
- **Docs / acceptance / gates:** Update API evidence only for newly observed
  facts. Accept when no API inference is hidden in decoding and assigned results
  remain excluded. Gates: S01 plus an authorization fake; real probe requires S03
  or S05.
- **Commit / push:** `Implement strict Google Tasks reads`; push.

### S07 — Implement strict Google Tasks mutation and error adapter

- **Capability:** The production adapter can create, patch, delete, move, and
  rename with exact headers/bodies and preserve ambiguous outcomes for callers.
- **Scope / non-goals:** Add operation DTOs/results and structured auth, quota,
  `Retry-After`, conditional, transient, permanent, and unknown error mapping.
  Do not retry, reconcile, content-deduplicate, or claim idempotency here.
- **Expected modules/files:** mutation additions under
  `lib/src/data/google_tasks/` and scripted operation/error contract tests.
- **Tests first:** `API-004`, `API-007`, mutation portions of `API-009`, every
  supported request/response shape, lost/truncated responses, 401/403/404/412/429,
  unknown responses, optional-field clearing, and stale-source delete/move.
- **Verification / visuals:** Focused adapter suite, full S06 suite, and quality;
  then isolated P7/P12-style probes for exact field clearing and stale-source
  DELETE. No screenshots.
- **Docs / acceptance / gates:** Record sanitized probe results. Optional-field
  writes remain disabled until their clear representation is proved; stale-path
  delete confirmation remains conservative until observed. Gates: S06 and
  dedicated account for live evidence.
- **Commit / push:** `Implement Google Tasks mutation contracts`; push.

### S08 — Establish the stateful fake and shared contract

- **Capability:** Tests can run the same read/write service contract against a
  strict in-memory Google model and the HTTP adapter without network access.
- **Scope / non-goals:** Implement remote lists/tasks, hierarchy, canonical
  ordering, pagination, etags, tombstones, and all ordinary mutations plus an
  exact call ledger. Do not implement sync or convenient behavior absent from
  the verified contract.
- **Expected modules/files:** `test/support/fake_google_tasks_service.dart`,
  `test/support/google_tasks_contract.dart`, fake qualification tests, and HTTP
  contract adapters.
- **Tests first:** Fake rejection of invalid methods/paths/flags/parents,
  deterministic page/order behavior, etag changes, duplicate creates, move
  identity, delete representations, and equality of shared observable outcomes.
- **Verification / visuals:** Fake qualification, shared fake/HTTP contract,
  adapter regression, and quality. No screenshots.
- **Docs / acceptance / gates:** Maintain a documented mapping from each fake
  behavior to API evidence. Accept when the fake fails closed and exact call
  counts are assertable. Gates: S06–S07; unknown contract behavior stays absent.
- **Commit / push:** `Add strict stateful Google Tasks fake`; push.

### S09A — Add deterministic clock, randomness, barriers, and observations

- **Capability:** Tests can advance exact deadlines, choose replayable jitter,
  pause named request/transaction boundaries, and inspect a structured ledger.
- **Scope / non-goals:** Implement only `F-TIME`, `F-BARRIER`, and `F-OBS`,
  including partial response delivery versus server commit. Do not add lifecycle,
  auth, connectivity, multi-host behavior, or the production engine.
- **Expected modules/files:** `test/support/{fake_clock,fake_random,barriers,
  observation_ledger}.dart` and their qualification tests.
- **Tests first:** Exact boundary release, independent barrier addressing,
  cancellation ordering, deterministic jitter/clock discontinuity, ledger order,
  and self-tests proving a deliberately wrong consumer fails.
- **Verification / visuals:** Focused support/fake qualifications, shared adapter
  contract regression, and quality. No visuals.
- **Docs / acceptance / gates:** Mark only these three fake capabilities ready.
  Accept with no wall-clock sleep or generic call-N-only hook. Gate: S08.
- **Commit / push:** `Add deterministic sync test controls`; push.

### S09B — Add auth, lifecycle, and connectivity fakes

- **Capability:** Tests can drive every authorization, foreground/background,
  process-exit, and connectivity-hint transition through production ports.
- **Scope / non-goals:** Implement `F-AUTH`, `F-LIFE`, and `F-CONN`. Do not infer
  reachability from connectivity or emulate Google remote state here.
- **Expected modules/files:** `test/support/{fake_auth,fake_lifecycle,
  fake_connectivity}.dart` and contract/qualification tests.
- **Tests first:** Auth restore/refresh/terminal/cancel/mismatch, Android pause/
  resume/no-callback, Linux focus independence, repeated hint coalescing, and
  fake self-failure tests.
- **Verification / visuals:** Focused qualifications, platform authorization
  contract regressions, and quality. No visuals.
- **Docs / acceptance / gates:** Accept when each fake emits typed facts only and
  cannot directly set SyncHealth. Gates: S03, S05, and S09A.
- **Commit / push:** `Add auth and lifecycle test fakes`; push.

### S09C — Add multi-host and reference-model harnesses

- **Capability:** Deterministic tests can run several independent local stores
  against one fake Google service and compare transitions to an independent
  invariant model with replayable seeds.
- **Scope / non-goals:** Implement `F-MULTI`, `F-MODEL`, and `MOD-005` harness
  qualification only. Do not copy production reconciliation or implement sync.
- **Expected modules/files:** `test/support/{multi_host,reference_model,
  replay_seed}.dart` and harness self-tests.
- **Tests first:** Account/store isolation, host ordering permutations, model
  rejection of deliberately invalid transitions, seed printing/replay, and a
  mutation that proves the oracle is not the production algorithm.
- **Verification / visuals:** Harness qualifications plus all S08–S09B tests and
  quality. No visuals.
- **Docs / acceptance / gates:** Accept only when hosts use production ports and
  the reference model asserts invariants rather than reproducing implementation
  decisions. Gates: S08–S09B.
- **Commit / push:** `Add multi-host sync model harness`; push.

## Trustworthy read path

### S10 — Persist account-scoped cached Google data

- **Capability:** Synthetic Google lists/tasks survive restart and stream from a
  selected account partition with stable local IDs and separate remote IDs.
- **Scope / non-goals:** Add account, list, task, remote-base, scope-completeness,
  and relational preference tables; strict row/domain mapping; read-only
  repository queries. Do not add desired mutations, sync attempts, multi-account
  UI, or local-only records.
- **Expected modules/files:** Drift tables/DAOs/mappers under
  `lib/src/data/database/`, immutable models/query types under `lib/src/domain/`,
  `TasksRepository` read surface, and generated code.
- **Tests first:** `DUR-003`, `DUR-008`, account isolation, nullable/unique remote
  IDs, one-level foreign-key rules, transaction rollback, streams, page
  publication completeness, restart, and unsupported-row preservation boundary.
- **Verification / visuals:** Persistence/domain focused tests,
  regeneration-no-diff, S02 native reopen regression, and quality. No screenshots.
- **Docs / acceptance / gates:** Document schema v1 and explicit invariants.
  Accept when no query can cross account partitions and cached data cannot be
  mistaken for freshness. Gates: S02 and accepted schema.
- **Commit / push:** `Persist account-scoped Google task cache`; push.

### S11 — Render cached tasks with truthful SyncHealth

- **Capability:** Linux/Android shells render cached list/task data immediately
  and show exactly Inactive, Pending, Failed, or Good with reason, counts, and
  last-success time.
- **Scope / non-goals:** Implement sync-fact storage/projection, repository and
  ViewModel, minimal adaptive shell/list, and details surface. Do not run a sync,
  mutate tasks, or polish final navigation.
- **Expected modules/files:** `lib/src/sync/health/`, sync-fact Drift tables/DAO,
  `lib/src/features/tasks/`, `lib/src/app/adaptive_shell.dart`, and health widgets.
- **Tests first:** `HLT-001`–`HLT-009`, `HLT-012`, `HLT-013`, startup/resume
  verification obligation, five-minute staleness, precedence, pending counts,
  and ViewModel/widget semantics for every reason/action.
- **Verification / visuals:** Focused health/persistence/ViewModel/widget tests,
  quality, curated Linux/phone goldens for cached Pending, stale Failed,
  noAuthorization, and syncStopped; inspect actual synthetic screenshots.
- **Docs / acceptance / gates:** Update UX only if rendering clarifies without
  changing vocabulary. Accept when green is impossible from cache, connectivity,
  or token presence. Gates: S01 and S10.
- **Commit / push:** `Render cached tasks with truthful sync health`; push.

### S12A — Implement read-only synchronization runs

- **Capability:** A headless run fully enumerates the fake/HTTP port, publishes
  validated pages, records completeness, and finalizes a truthful durable result.
- **Scope / non-goals:** Implement read-only Recover, eligibility, authorize,
  begin, enumerate, publish, and finalize phases. Do not wire Flutter lifecycle,
  UI triggers, outbound mutations, or retries.
- **Expected modules/files:** `lib/src/sync/{engine,run,phase}.dart`, read plan,
  page-publication transactions, and engine integration tests.
- **Tests first:** `RUN-001`, `RUN-011`, `RUN-012`, `REL-001`–`REL-003`, `REL-018`,
  `CRS-008`–`CRS-010`, cold/warm cache, unsupported hierarchy, page failure,
  malformed row, and no-op second run.
- **Verification / visuals:** Engine/store/fake tests, HTTP adapter regression,
  killed/reopen page-boundary cases, and quality. No visuals.
- **Docs / acceptance / gates:** Accept when only a complete finalized run
  advances last success and incomplete publication never deletes valid cache or
  claims completeness. Gates: S06, S08–S11, and S09A.
- **Commit / push:** `Implement read-only synchronization runs`; push.

### S12B — Deliver the first useful read/verify vertical slice

- **Capability:** On launch/resume/Refresh, the app displays cached data, runs
  foreground verification, incrementally shows validated remote data, and moves
  among Pending, Good, Failed, and Inactive from durable facts.
- **Scope / non-goals:** Wire one configured account, the read engine, platform
  authorization ports, minimal lifecycle/manual triggers, repositories, and the
  S11 shell in fake and production compositions. Do not add writes, automatic
  cadence/retry, conflict policy, or Android background work.
- **Expected modules/files:** composition/read-run wiring, startup/resume bridge,
  Refresh ViewModel action, and Linux/Android application integration tests.
- **Tests first:** `RUN-005`, `HLT-005`–`HLT-008`, cold/warm launch, resume,
  manual Refresh, partial-data failure, malformed data, no authorization, and
  first successful verification.
- **Verification / visuals:** Isolated fake application integration on Linux and
  Android, focused engine/health regressions, quality, and actual screenshots for
  cached Pending, partial Failed, first Good, stale, and noAuthorization.
- **Docs / acceptance / gates:** This is the earliest useful slice. Accept when
  cache/auth/connectivity alone can never produce green and old valid cache
  remains usable under an explicit non-green result. Gates: S03, S05, S09B,
  S11, and S12A. Live account smoke remains opt-in.
- **Commit / push:** `Deliver verified Google Tasks read slice`; push.

### S13A — Add serialized trigger coalescing and cadence

- **Capability:** Startup, Refresh, connectivity-restored, foreground cadence,
  and later local-edit triggers request at most one active run and one coalesced
  follow-up with exact deterministic timing.
- **Scope / non-goals:** Implement coordinator serialization, trigger merging,
  5–10 second edit debounce, five-minute cadence, quiescence, and two-minute run
  deadline. Do not add platform background rules, Stop/Resume, retries, or writes.
- **Expected modules/files:** `lib/src/sync/coordinator/` and deterministic
  coordinator tests.
- **Tests first:** `RUN-002`–`RUN-006`, `RUN-010`, `RUN-014`, `REL-005`, exact
  time boundaries, bursts during a run, repeated hints, stale finalizer, and
  no-work cadence.
- **Verification / visuals:** Coordinator/health/fake integration and quality.
  No new screenshot unless coordinator activity changes visible wording.
- **Docs / acceptance / gates:** Accept when no overlapping run is possible,
  connectivity never changes health directly, and idle work does not poll.
  Gates: S09A–S09B and S12B.
- **Commit / push:** `Add deterministic sync coordination`; push.

### S13B — Add platform lifecycle and Stop/Resume Sync

- **Capability:** Android syncs only while resumed, Linux remains eligible while
  minimized, and Stop/Resume preserves authorization, cache, and durable work.
- **Scope / non-goals:** Wire lifecycle/connectivity adapters, safe cancellation,
  durable `syncEnabled`, Stop/Resume UI, and resume catch-up. Do not add Android
  background workers or correctness that depends on an exit callback.
- **Expected modules/files:** lifecycle/connectivity adapters, coordinator
  eligibility policy, settings repository, Stop/Resume ViewModel/widgets, and
  platform integration tests.
- **Tests first:** `RUN-007`–`RUN-009`, `REL-006`, pause during read, hard exit,
  Linux focus/minimize, stop idle/active, edit-while-stopped fixture, and resume.
- **Verification / visuals:** Coordinator tests, Android lifecycle integration,
  Linux minimize/unfocus check, quality, and actual Stop/Resume screenshots on
  both form factors.
- **Docs / acceptance / gates:** Accept when Android initiates no background
  request and Stop never removes auth/cache/work. Gates: S13A and S09B.
- **Commit / push:** `Add foreground lifecycle sync control`; push.

## Durable mutations and reconciliation

### S14A — Acknowledge local list edits durably

- **Capability:** Offline list create/rename updates the UI only after one
  transaction commits projected state plus coalesced desired state.
- **Scope / non-goals:** Add desired-state/dependency tables and list repository
  commands. Do not add task commands, Google calls, delete, reorder, or bulk.
- **Expected modules/files:** desired-state Drift schema/DAOs, domain commands and
  validators, list repository transactions, ViewModel state, and list widgets.
- **Tests first:** list variants of `DUR-001`–`DUR-007` and `DUR-009`–`DUR-011`,
  rollback, rename coalescing, restart, stable provisional identity, account
  validation, no local-only option, and duplicate-tap prevention.
- **Verification / visuals:** Domain/persistence/ViewModel/widget tests,
  regeneration, offline restart integration, health regression, quality, and
  actual list create/rename states on Linux/phone.
- **Docs / acceptance / gates:** Update `PAR-LIST-002/005`. Accept when UI
  success cannot precede durability and stopped-sync editing works. Gates:
  S10–S13B.
- **Commit / push:** `Add durable offline list edits`; push.

### S14B — Acknowledge local task content edits durably

- **Capability:** Offline task create/title/notes/due/completion commands become
  visible only with one durable projected-state/desired-state transaction.
- **Scope / non-goals:** Add task commands and validation on the S14A schema. Do
  not call Google, delete, move, reorder, cascade related tasks, or add bulk.
- **Expected modules/files:** task domain commands/validators, repository
  transactions, task ViewModel command states/widgets, and focused tests.
- **Tests first:** task variants of `DUR-001`–`DUR-007` and `DUR-009`–`DUR-011`,
  rollback, edit coalescing, restart, stable provisional identity, account and
  one-level validation, empty/Unicode content, and duplicate taps.
- **Verification / visuals:** Domain/store/ViewModel/widget tests, offline restart
  integration, S14A regression, quality, and actual task edit states.
- **Docs / acceptance / gates:** Update `PAR-TASK-001/002/004/005`. Accept when
  every acknowledged task edit is discoverable after immediate process death.
  Gates: S14A.
- **Commit / push:** `Add durable offline task edits`; push.

### S15A — Publish creates and bind Google identities

- **Capability:** Eligible list, top-level task, and child-task creates publish
  in dependency order and bind returned Google IDs without changing local IDs.
- **Scope / non-goals:** Add operation claiming, create payloads, remote-ID/base
  acknowledgement, and list→parent→child ordering. Do not add updates, conflict
  resolution, deletes, moves, retries, or content matching.
- **Expected modules/files:** sync planner/executor, operation mapper, attempt
  tables/DAO, engine phase-7 wiring, and integration tests.
- **Tests first:** create portions of `RUN-013`, `REL-004`, `CRS-003`–`CRS-007`,
  ordinary `REL-013`, dependencies, partial success, restart, ID binding,
  duplicate-content independence, and exact call ledger.
- **Verification / visuals:** Focused engine/store/fake tests, application
  integration for offline create→resume→remote confirmation, quality, and
  Pending→Good/partial Failed screenshot inspection.
- **Docs / acceptance / gates:** Accept when confirmed creates never replay and
  content is never used for deduplication. Gates: S07–S09C and S14A–S14B.
- **Commit / push:** `Publish Google list and task creates`; push.

### S15B — Publish list titles and complete task content

- **Capability:** Eligible list renames and task content snapshots publish and
  acknowledge independently without replaying confirmed operations.
- **Scope / non-goals:** Add PATCH/update planning, payloads, no-op suppression,
  and per-operation acknowledgement. Do not add conflict resolution, deletes,
  moves, retries, or uncertainty recovery.
- **Expected modules/files:** update planner/executor, content mappers, attempt
  transactions, and integration tests.
- **Tests first:** update portions of `RUN-013`, `REL-004`, `REL-014`,
  `CRS-003`–`CRS-007`, optional clears, partial success, newer local generation,
  restart, and exact call ledger.
- **Verification / visuals:** Engine/store/fake tests, offline update integration,
  adapter regression, S15A regression, and quality. Inspect partial result only
  if UI changed.
- **Docs / acceptance / gates:** Accept when payloads are complete supported
  snapshots, confirmations cannot clear newer intent, and no-op writes disappear.
  Gates: S15A and accepted optional-clear `API-009` evidence.
- **Commit / push:** `Publish Google task content updates`; push.

### S16 — Reconcile whole-record content and list titles

- **Capability:** Offline and multi-device edits converge by the accepted
  whole-record timestamp policy, with Google winning ties or missing/invalid
  conflict evidence failing safely.
- **Scope / non-goals:** Implement base-aware reconciliation for title, notes,
  due, completion, and list title plus 412 refetch/replan. Do not merge fields,
  create conflict copies, resolve structure, or ask per-task questions.
- **Expected modules/files:** `lib/src/sync/reconciliation/content_policy.dart`,
  base comparison/planning, typed supersession results, and model tests.
- **Tests first:** `REC-001`–`REC-007`, `REC-021`, relevant `MOD-001`/`MOD-002`,
  local/remote/both/equal timestamps, optional clears, malformed timestamps,
  412 races, and restart after supersession.
- **Verification / visuals:** Policy, engine, multi-host, and application
  integration tests plus quality. Inspect aggregate Google-won replacement
  detail; no new golden unless its surface changes.
- **Docs / acceptance / gates:** Accept when the entire newer record wins, older
  fields are intentionally discarded only within that record, and hosts reach a
  stable result. Gates: S15B and optional-field contract evidence.
- **Commit / push:** `Reconcile task content deterministically`; push.

### S17 — Add durable delete grace, Undo, and hard deletion

- **Capability:** Task/bulk-task deletion hides locally, remains durably Undoable
  for exactly 30 seconds, then dispatches authoritative deletion; list delete and
  Clear completed require confirmation and have no Undo.
- **Scope / non-goals:** Add tombstone snapshots, `notBefore`, cleanup on
  startup/resume, task/list deletion execution, subtree scope safety, and Undo
  UI for one task. Bulk grouping and Clear completed UI land later.
- **Expected modules/files:** delete domain policy, tombstone Drift tables/DAO,
  repository delete/Undo commands, scheduler eligibility, engine delete executor,
  and Undo widget.
- **Tests first:** `RUN-016`, `REC-016`, delete portions of `REC-017`/`REC-019`,
  `REL-015`, `REL-020`, `MOD-003`, expiry boundaries, explicit Refresh during
  grace, restart at cleanup/claim, parent subtree safety, and unrelated scope.
- **Verification / visuals:** Domain/store/coordinator/engine/restart tests,
  integration delete→Undo and expiry→Google delete, quality, golden plus actual
  desktop/phone Undo and destructive confirmation review.
- **Docs / acceptance / gates:** Accept when no DELETE occurs before expiry,
  Undo restores the same identities before dispatch, delete always wins after
  dispatch, and no unrelated resource is lost. Gates: S13B, S15B, S16, and
  stale-source DELETE evidence/conservative recovery from S07.
- **Commit / push:** `Add durable task deletion and undo`; push.

### S18A — Add one-level hierarchy commands and protection

- **Capability:** Users can add, promote, and demote subtasks within exactly one
  supported level while unexpected deeper remote data is protected and visible
  as an affected-scope failure.
- **Scope / non-goals:** Implement parent validation, hierarchy repository
  commands, subtree projections, and unsupported-depth handling. Do not add
  manual ordering, cross-list move, or remote MOVE execution.
- **Expected modules/files:** hierarchy domain policy/commands, repository
  transactions, task-detail hierarchy controls, and adapter/engine protection.
- **Tests first:** `REC-022`, `REC-023`, local depth/cross-list/account/deleted
  parent rejection, child-before-parent publication, protected raw evidence,
  unrelated-scope visibility, restart, and no remote mutation.
- **Verification / visuals:** Domain/store/adapter/engine/widget/integration tests,
  quality, and actual desktop/phone hierarchy/error screenshots.
- **Docs / acceptance / gates:** Accept when the domain cannot create depth 3 and
  unsupported data is never flattened, edited, moved, or deleted. Gates: S14B,
  S15A, and S12A.
- **Commit / push:** `Add protected one-level task hierarchy`; push.

### S18B — Add move, reparent, and manual ordering reconciliation

- **Capability:** Users can move/reorder tasks and Google-authoritative structure
  resolves concurrent placement without oscillation.
- **Scope / non-goals:** Implement structure desired facets, valid `previous`
  anchors, cross-list MOVE by stable ID, canonical returned order, and structure
  reconciliation. Do not alter content conflict policy or repair deeper data.
- **Expected modules/files:** hierarchy/structure domain policies, repository
  commands, MOVE planner/executor, canonical order projection, and task-detail
  structure controls.
- **Tests first:** `REC-008`–`REC-013`, `REC-017`–`REC-020`, `REC-022`, `REC-023`,
  concurrent moves, deleted/missing anchors, move-plus-edit independence,
  cross-list subtree, unsupported depth, and account/list boundary rejection.
- **Verification / visuals:** Unit/store/engine/multi-host tests, task detail and
  reorder integration, adapter regression, quality, and actual desktop/phone
  hierarchy/reorder screenshots.
- **Docs / acceptance / gates:** Accept when all clients converge to canonical
  Google structure without oscillation and unsupported data is never flattened,
  edited, moved, or deleted. Gates: S17, S18A, and MOVE/API evidence.
- **Commit / push:** `Add Google-authoritative task movement`; push.

### S19A — Add bounded retry and exhaustion

- **Capability:** Retryable failures back off from one second with deterministic
  jitter/`Retry-After`, stop automatic retry after five minutes, and expose Retry
  immediately while waiting remains Failed.
- **Scope / non-goals:** Implement request budgets, between-run retry episode,
  exhaustion latch, and typed transient/rate-limit classification. Do not add
  token refresh/reauthorization or classify unknown Google responses as retryable.
- **Expected modules/files:** retry policy, coordinator episode state, scheduler
  integration, Retry UI action, and deterministic tests.
- **Tests first:** `REL-007`–`REL-012`, `REL-019`, `HLT-002`–`HLT-004`, jitter,
  `Retry-After`, exact five-minute exhaustion, run deadline, restart, and explicit
  Retry latch clearing.
- **Verification / visuals:** Policy/coordinator/health/fake integration, quality,
  and screenshots for failed waiting, executing retry, and exhausted Retry.
- **Docs / acceptance / gates:** Accept when detection is red immediately, only
  an executing retry is Pending, and unknown responses fail closed. Gates: S13A
  and S15B.
- **Commit / push:** `Add bounded synchronization retry`; push.

### S19B — Add token refresh and persistent reauthorization

- **Capability:** Refreshable authorization retries once; terminal rejection
  persists noAuthorization with Reauthorize while preserving cache and intent.
- **Scope / non-goals:** Implement refresh-once policy, adapter classification,
  subject validation, reauthorization latch/action, and post-login verification.
  Do not generalize unobserved 401/403 shapes or add sign-out.
- **Expected modules/files:** sync retry policy/coordinator additions, auth
  recovery state, failure UI actions, and deterministic tests.
- **Tests first:** `AUTH-001`–`AUTH-003`, `AUTH-006`, `HLT-001`, refresh success,
  second rejection, wrong scope/subject, cancel, restart, stopped sync, unknown
  auth-like response, and successful reauthorization requiring a full run.
- **Verification / visuals:** Policy/coordinator/auth/health tests, fake app
  integration, platform adapter contract regression, quality, and screenshots
  for Reauthorize on both layouts.
- **Docs / acceptance / gates:** Accept when auth failure never deletes cache or
  intent and login alone never produces Good. Gates: S19A, S03/S05 evidence, and
  S09B.
- **Commit / push:** `Add synchronization reauthorization recovery`; push.

### S20A — Recover uncertain creates

- **Capability:** Lost list/task create responses recover without false
  acknowledgement; an accepted duplicate may result and is never content-matched.
- **Scope / non-goals:** Implement create attempt recovery, returned-ID binding,
  newer desired generation handling, and duplicate diagnostics. Do not resolve
  update/delete/move uncertainty or promise idempotency.
- **Expected modules/files:** create uncertainty resolver, recovery transactions,
  diagnostic codes, and restart/multi-host tests.
- **Tests first:** `REL-013`, create portions of `API-004`, `CRS-004`–`CRS-007`,
  landed/not-landed/unknown, repeated loss, newer edit/move/delete, parent/list
  dependency, restart, and identical-content independence.
- **Verification / visuals:** Engine/store/restart/multi-host tests, adapter/fake
  contracts, quality, and duplicate diagnostic detail inspection.
- **Docs / acceptance / gates:** Accept when no remote success is invented and
  content matching is impossible. Gates: S15A, S19A–S19B, and P5 evidence.
- **Commit / push:** `Recover uncertain Google creates`; push.

### S20B — Recover uncertain updates, deletes, and moves

- **Capability:** Lost content/list-title/delete/move responses resolve by their
  separate evidence rules without false acknowledgement or collateral deletion.
- **Scope / non-goals:** Implement non-create read-back/replay with newer desired
  generations. Do not introduce a generic replay rule or weaken positive-delete
  evidence.
- **Expected modules/files:** operation-specific uncertainty resolvers, recovery
  queries/transactions, diagnostic result codes, and restart tests.
- **Tests first:** `REL-014`–`REL-017`, `REL-020`, `API-004`, `API-009`,
  `CRS-004`–`CRS-007`, landed/not-landed/unknown variants, repeated response
  loss, newer edit/move/delete during uncertainty, and unrelated-resource safety.
- **Verification / visuals:** Engine/store/restart/multi-host tests, adapter
  contract, fake application integration, deep focused matrix, and quality.
  Inspect the aggregate accepted-duplicate/failure detail if its UI changes.
- **Docs / acceptance / gates:** Accept when no remote success is invented, no
  unrelated resource is touched, and health stays non-green until explicit
  resolution. Gates: S17–S19B, S20A, and controlled API evidence.
- **Commit / push:** `Recover uncertain Google mutations`; push.

### S21A — Complete interrupted-run and restart recovery

- **Capability:** Startup converts abandoned runs/attempts into the exact
  pending/uncertain state and resumes only unresolved work idempotently.
- **Scope / non-goals:** Implement interrupted-run discovery, attempt recovery,
  checkpoint/finalizer rules, and repeated recovery. Do not add database-open/
  corruption UI or claim real process-death evidence yet.
- **Expected modules/files:** sync startup recovery, store transactions, barrier
  integration, and reopen tests.
- **Tests first:** `CRS-001`–`CRS-011` at transaction/barrier level, partial page,
  partial operation, acknowledgement failure, newer generations/latches, stale
  finalizer, repeated recovery, and no-exit-callback.
- **Verification / visuals:** Store/engine/reopen tests, all uncertainty
  regressions, and quality. No visual work.
- **Docs / acceptance / gates:** Accept when recovery is transactional and
  idempotent and no half-acknowledgement is reachable. Gates: S20A–S20B.
- **Commit / push:** `Add synchronization restart recovery`; push.

### S21B — Prove process-death and database recovery

- **Capability:** A killed process at every durable boundary reopens correctly;
  unavailable/corrupt storage stops Google work and presents non-destructive
  recovery rather than an empty account.
- **Scope / non-goals:** Add killed-child-process harness, database open/read/
  write/integrity recovery, WAL/SHM preservation, and Retry Open UI. Do not
  auto-delete/quarantine production storage or simulate death only by exceptions.
- **Expected modules/files:** sync/store recovery modules, child-process barrier
  harness, temporary real-SQLite fixtures, Retry Open UI, and persistence
  diagnostics.
- **Tests first:** `CRS-001`–`CRS-012`, `DUR-009`, partial-page and partial-write
  publication, WAL/SHM preservation, open/integrity/read/write failure, repeated
  recovery, stale finalizer, and no-exit-callback cases.
- **Verification / visuals:** Killed-process suite, full persistence/sync focused
  matrix, quality, and actual Linux/phone recovery screens with synthetic paths
  and safe messages.
- **Docs / acceptance / gates:** Accept when reopen is equivalent to a permitted
  durable state, no half-acknowledgement exists, and unreadable storage cannot
  trigger sync or display invented emptiness. Gates: S02 and S21A.
- **Commit / push:** `Prove synchronization crash recovery`; push.

## Core product workflows

### S22A — Add typed relational and device preferences

- **Capability:** List order/exclusion, view sort/completed settings, theme,
  density, and onboarding dismissal survive restart in their correct storage.
- **Scope / non-goals:** Implement one typed repository backed by Drift for
  account/relational/query settings and `SharedPreferencesAsync` for disposable
  device presentation. Do not implement smart-view membership or let callers
  select storage.
- **Expected modules/files:** `lib/src/data/preferences/`, Drift preference
  tables/DAO, device adapter/in-memory fake, and repository contracts.
- **Tests first:** Account isolation, list foreign keys, defaults, restart,
  malformed device values, write failure, quarantine/default diagnostics,
  reactive updates, and proof sync-critical settings cannot use device storage.
- **Verification / visuals:** Unit/persistence/adapter contract, regeneration,
  native platform smoke, and quality. No visuals.
- **Docs / acceptance / gates:** Accept when storage selection is invisible and
  device preference failure cannot corrupt task/sync behavior. Gates: S10 and
  dependency admission for `shared_preferences`.
- **Commit / push:** `Add typed application preferences`; push.

### S22B — Add effective dates and smart-view projections

- **Capability:** Focus, Upcoming, Missed, Unscheduled, All, per-list views, and
  their counts/sorts derive consistently from cached tasks and preferences.
- **Scope / non-goals:** Implement pure effective-date/membership/sort policies,
  ViewModels, and view controls. Do not add capture or task detail behavior.
- **Expected modules/files:** `lib/src/domain/policy/{effective_due,smart_views}.dart`,
  smart-view query/repository projections, ViewModels, and widgets.
- **Tests first:** `PAR-LIST-003/004`, `PAR-STRUCT-009`, `PAR-VIEW-001`–`007`,
  date boundaries/locale, counts=visible rows, exclusion, new/deleted lists,
  effective child dates, completed filtering, sort stability, and restart.
- **Verification / visuals:** Unit/persistence/preference/ViewModel/widget tests,
  integration restart, quality, curated light/dark desktop/phone goldens, and
  actual smart-view screenshots.
- **Docs / acceptance / gates:** Accept when every membership rule has one domain
  implementation and counts exactly match visible rows. Gates: S18A and S22A.
- **Commit / push:** `Add smart views and typed preferences`; push.

### S23A — Complete task detail and subtask workflows

- **Capability:** Users can inspect/edit long notes, create/manage one-level
  subtasks, and see direct-child progress in desktop detail and mobile routes.
- **Scope / non-goals:** Build detail ViewModel/layout, notes, subtask CRUD,
  progress, focus/back, and responsive presentation. Do not add date cascade,
  completion semantics, or recurrence editing.
- **Expected modules/files:** task-detail ViewModel, desktop pane/mobile route,
  notes/subtask/progress widgets, and integration tests.
- **Tests first:** `PAR-TASK-004`, `PAR-STRUCT-003/005/007`, long/empty/Unicode
  notes, one-level validation, subtask CRUD/reorder, progress, focus/back, safe
  areas, and text scaling.
- **Verification / visuals:** Domain/ViewModel/widget/integration/sync tests,
  quality, long-content/light/dark goldens, and actual desktop/phone detail
  screenshots.
- **Docs / acceptance / gates:** Accept when collections never duplicate child
  rows and every detail action uses shared domain commands. Gates: S18A–S18B and
  S22B.
- **Commit / push:** `Complete task details and subtasks`; push.

### S23B — Add completion and date behavior

- **Capability:** Users can complete/reopen tasks, apply date shortcuts, see
  effective dates, and atomically Undo the accepted due-consistency cascade.
- **Scope / non-goals:** Add completion/date ViewModel actions, P8 Google cascade
  projection, clamped calendar policy, and grouped due-change Undo. Do not add
  recurrence editing or per-field sync semantics.
- **Expected modules/files:** completion/date domain policies, due-cascade
  command, date widgets/actions, task-detail integration, and tests.
- **Tests first:** `PAR-TASK-002`, `PAR-TASK-005`–`007`,
  `PAR-STRUCT-008/009`, P8, clamped/local dates, clear, cascade all-or-none,
  Undo/restart, impossible child reopen, and Google-won result.
- **Verification / visuals:** Domain/store/sync/ViewModel/widget/integration,
  S23A regression, quality, and actual date/completion state screenshots.
- **Docs / acceptance / gates:** Accept when returned Google completion state is
  authoritative and related date changes are one durable command. Gates: S16,
  S18B, and S23A.
- **Commit / push:** `Add task completion and date workflows`; push.

### S24A — Add quick capture with explicit date preview

- **Capability:** Users can rapidly create one task in a visible target list and
  accept or dismiss a narrow parsed-date preview.
- **Scope / non-goals:** Implement quick add and only the accepted terminal ISO,
  today, tomorrow, next week, and next month grammar. Do not add paste/bulk input,
  broad natural language, or silent interpretation.
- **Expected modules/files:** capture parser/domain command, quick-add ViewModel/
  widgets, and focused tests.
- **Tests first:** `PAR-CAPTURE-001/002`, exact grammar/boundaries, ambiguous text,
  preview dismissal, invalid target, smart-view visibility, duplicate submit,
  rollback, restart, and publication.
- **Verification / visuals:** Unit/ViewModel/widget/application integration,
  quality, desktop/phone quick-add goldens, and actual keyboard/touch screenshots.
- **Docs / acceptance / gates:** Accept when target and interpreted date are
  visible before acknowledgement and creation uses normal desired state. Gates:
  S14B, S15A, S22B, and S23B.
- **Commit / push:** `Add explicit quick task capture`; push.

### S24B — Add validated bulk paste

- **Capability:** Users can preview and atomically acknowledge bounded multi-task
  paste input into one visible target list.
- **Scope / non-goals:** Implement line/paragraph parsing, validation, bounds,
  preview, and one local repository transaction. Do not add other bulk operations
  or partially accept invalid input.
- **Expected modules/files:** bulk-add parser/command, repository transaction,
  ViewModel/widgets, and tests.
- **Tests first:** `PAR-CAPTURE-003`, empty/large/malformed input, line/paragraph
  rules, invalid target, all-or-none rollback, restart, dependencies, remote
  per-create partial result, and duplicate submission.
- **Verification / visuals:** Unit/store/ViewModel/widget/integration, S24A
  regression, quality, and actual desktop/phone preview/result screenshots.
- **Docs / acceptance / gates:** Accept when local acknowledgement is all-or-none
  and each task publishes through ordinary create handling. Gates: S24A.
- **Commit / push:** `Add validated bulk task capture`; push.

### S25 — Add search and deterministic navigation state

- **Capability:** Search finds title/notes including child matches in parent
  context, and navigation/back closes surfaces in a tested deterministic order.
- **Scope / non-goals:** Implement search repository/ViewModel/overlay and the
  small Navigator-based route/state model. Do not add deep links or `go_router`.
- **Expected modules/files:** `lib/src/features/search/`, navigation state under
  `lib/src/app/`, search queries, route widgets, and tests.
- **Tests first:** `PAR-SEARCH-001`, child-parent context, account/supported-data
  isolation, empty/Unicode/long queries, result updates, keyboard/touch parity,
  selection/dialog/detail/drawer/back ordering, and predictive-back state.
- **Verification / visuals:** Repository/ViewModel/widget/integration tests,
  quality, search/back goldens, and actual desktop/phone search screenshots.
- **Docs / acceptance / gates:** Accept when search never exposes protected
  unsupported rows and back never depends on ad hoc widget flags. Gates: S22B,
  S23A, and S23B.
- **Commit / push:** `Add task search and navigation state`; push.

### S26A — Add Fedora multi-pane, keyboard, and context interactions

- **Capability:** Fedora users get an efficient multi-pane layout, discoverable
  keyboard/focus behavior, and hover/context accelerators with visible routes.
- **Scope / non-goals:** Implement desktop composition, shortcut/focus policy,
  and context/hover actions. Do not add drag/reorder or fork domain behavior.
- **Expected modules/files:** desktop shell/panes, shortcut/focus policy,
  context/hover widgets, and desktop tests/goldens.
- **Tests first:** `PAR-DESKTOP-001/002`, text-input conflicts, discoverable
  equivalents, semantics, no-hover reflow, focus transitions, multiple widths,
  and high text scaling.
- **Verification / visuals:** Widget/integration, quality, curated desktop
  goldens, and actual Fedora screenshots at named widths/light/dark states.
- **Docs / acceptance / gates:** Accept when no action requires hover/right-click
  or an undiscoverable shortcut. Gates: S22B–S25.
- **Commit / push:** `Add Fedora task interactions`; push.

### S26B — Add Fedora pointer drag and reorder

- **Capability:** Pointer users can reorder/move with preview, cancel, and
  canonical failure recovery while keyboard/button alternatives remain usable.
- **Scope / non-goals:** Implement drag adapters and desktop presentation over
  existing structure commands. Do not add a second ordering policy.
- **Expected modules/files:** drag/reorder widgets/adapters, desktop integration
  tests, and failure-state goldens.
- **Tests first:** `PAR-DESKTOP-003`, preview/drop/cancel, invalid targets,
  autoscroll, remote failure canonical restore, accessibility alternatives, and
  no layout reflow.
- **Verification / visuals:** Widget/integration/sync, S26A regression, quality,
  and actual Fedora drag preview/failure screenshots.
- **Docs / acceptance / gates:** Accept when failed structure never leaves a
  false placement and non-pointer alternatives are equivalent. Gates: S18B and
  S26A.
- **Commit / push:** `Add Fedora task drag and reorder`; push.

### S27A — Add Android adaptive shell and navigation

- **Capability:** Android users get native list/detail navigation, drawer/FAB,
  safe areas, predictive back, rotation, and accessible responsive layout.
- **Scope / non-goals:** Implement the Android shell/routes and layout only. Do
  not add gestures, pull-to-refresh, lifecycle scheduling, background work, or
  duplicate shared policy.
- **Expected modules/files:** Android shell/routes/drawer/FAB widgets, navigation
  integration, phone/tablet goldens, and device tests.
- **Tests first:** `PAR-ANDROID-001/002/005/006`, system/predictive back,
  keyboard/insets, text scaling, rotation, narrow/wide constraints, semantics,
  and touch targets.
- **Verification / visuals:** Widget/integration, emulator and physical-device
  smoke, quality, goldens, and actual phone/tablet screenshots.
- **Docs / acceptance / gates:** Accept when native navigation is accessible at
  every supported constraint and back order matches S25. Gates: S03, S23A–S25.
- **Commit / push:** `Add Android adaptive task shell`; push.

### S27B — Add Android gestures, refresh, and lifecycle behavior

- **Capability:** Android users get pull-to-refresh, gesture accelerators with
  visible alternatives, and foreground/resume-only synchronization.
- **Scope / non-goals:** Wire gestures, refresh result, pause/resume eligibility,
  and catch-up to the S27A shell. Do not add hidden gesture-only actions,
  authless mode, or background workers.
- **Expected modules/files:** touch/refresh widgets, lifecycle integration,
  gesture alternatives, emulator/device tests, and goldens.
- **Tests first:** `PAR-ANDROID-003/004`, pause/resume during read/mutation,
  refresh success/failure, gesture cancel/failure, visible alternatives, and no
  background request across cadence.
- **Verification / visuals:** Widget/integration, emulator lifecycle, physical
  device, S27A regression, quality, and actual refresh/gesture/health screenshots.
- **Docs / acceptance / gates:** Accept when resume catches up and no network
  work begins while inactive. Gates: S13B and S27A.
- **Commit / push:** `Add Android foreground task interactions`; push.

### S28A — Add atomic non-destructive bulk operations

- **Capability:** Multi-select complete/reschedule/move acknowledges all-or-none
  locally and reports exact independent Google outcomes.
- **Scope / non-goals:** Implement transient selection, validated non-destructive
  bulk commands, one desired row per resource, and result summary. Do not add
  bulk delete, Clear completed, or roll back confirmed remote successes.
- **Expected modules/files:** bulk domain commands/repository transactions,
  selection/bulk ViewModels/widgets, sync result summary, and tests.
- **Tests first:** `PAR-BULK-001/002` non-delete cases, every local validation/
  transaction failure, remote partial success/dependency, exact counts, restart,
  mixed hierarchy, and selection/back behavior.
- **Verification / visuals:** Domain/store/sync/ViewModel/widget/integration tests,
  quality, desktop/phone bulk goldens, and actual selection/result/confirmation
  screenshots.
- **Docs / acceptance / gates:** Accept when local acceptance is all-or-none and
  exact confirmed/pending/failed counts survive restart. Gates: S18B, S23B,
  S26B, and S27B.
- **Commit / push:** `Add reliable bulk task updates`; push.

### S28B — Add grouped bulk delete and Clear completed

- **Capability:** Bulk delete has one durable 30-second Undo group; Clear
  completed requires confirmation, has no Undo, and preserves unfinished trees.
- **Scope / non-goals:** Add only destructive bulk policy/UI on S28A. Do not
  partially restore an Undo group or treat Clear completed as ordinary Undoable
  delete.
- **Expected modules/files:** grouped tombstone transaction, Clear-completed
  selector, confirmation/Undo/result widgets, and tests.
- **Tests first:** destructive `PAR-BULK-002`, `PAR-TASK-008`, group all-or-none,
  expiry/restart/refresh, remote partial delete, exact counts, completed parent
  with unfinished child, confirmation cancel, and unrelated-resource safety.
- **Verification / visuals:** Domain/store/sync/widget/integration, S17/S28A
  regression, quality, and actual group Undo/Clear confirmation screenshots.
- **Docs / acceptance / gates:** Accept when group restoration is all-or-none and
  Clear completed never removes an unfinished subtree. Gates: S17 and S28A.
- **Commit / push:** `Add safe bulk task deletion`; push.

## Safety, diagnostics, and completion

### S29A — Persist separated release and development diagnostics

- **Capability:** All relevant failures/transitions enter a bounded local
  release-safe sink or debug-only sensitive sink with unconditional credential
  scrubbing.
- **Scope / non-goals:** Implement event types, persistence, bounds/cleanup,
  redaction, and composition wiring. Do not add UI/export, upload, sampling, or a
  runtime switch that enables the sensitive sink.
- **Expected modules/files:** diagnostic event/store/sinks/redactor, composition
  wiring, persistence schema, and canary tests.
- **Tests first:** `HLT-010/011` sink cases, every sync/API/storage/UI event,
  release task/account/URL/SQL canaries, development task/payload retention,
  credential canaries, bounds, restart, and release construction proof.
- **Verification / visuals:** Security/unit/persistence/integration, all event
  producer regressions, and quality. No visuals.
- **Docs / acceptance / gates:** Accept when release cannot construct the
  sensitive sink and neither sink can retain credential material. Gates: S01 and
  representative S12A–S21B events.
- **Commit / push:** `Persist separated diagnostic events`; push.

### S29B — Deliver diagnostics viewing and export surfaces

- **Capability:** Users can inspect/copy/export/clear safe diagnostics;
  development builds expose the sensitive searchable stream in one interaction
  with a persistent warning.
- **Scope / non-goals:** Add release/dev ViewModels/views and explicit local
  export over S29A. Do not alter sink privacy, upload, or expose dev UI in release.
- **Expected modules/files:** diagnostic store/sinks/redactor, release/dev
  features, composition wiring, export helper, and canary tests.
- **Tests first:** `HLT-010/011` UI cases, search, copy/export/clear, warning,
  one-interaction reachability, export privacy, empty/error states, and release
  inability to navigate/construct the development view.
- **Verification / visuals:** Security/unit/persistence/widget/integration tests,
  quality, release/dev goldens, and actual desktop/phone diagnostics screenshots
  with synthetic sensitive content.
- **Docs / acceptance / gates:** Accept when release binaries cannot construct
  the sensitive sink/view and developers can inspect all allowed failure context
  without terminal access. Gate: S29A.
- **Commit / push:** `Deliver local diagnostics surfaces`; push.

### S30A — Add versioned account backup/export

- **Capability:** Users can export one selected account's supported projected
  lists/tasks to a bounded versioned file with a private-data warning.
- **Scope / non-goals:** Implement export format, validation of produced data,
  file adapter/picker, and export UI. Do not export credentials, authorization,
  sync attempts, diagnostics, device preferences, or raw database rows.
- **Expected modules/files:** backup format/encoder/validator, file adapter,
  export ViewModel/view, fixtures, and tests.
- **Tests first:** `PAR-DATA-001`, supported field round-trip, account selection,
  offline acknowledged edits, hierarchy/order, deterministic bounds/version,
  file failure/cancel, and privacy canaries.
- **Verification / visuals:** Unit/repository/widget/application integration,
  privacy scan, quality, and actual desktop/phone export warning/result screens.
- **Docs / acceptance / gates:** Publish exact v1 format and private-data warning.
  Accept when excluded data cannot enter the encoder. Gates: S23B, S28B, S29B.
- **Commit / push:** `Add versioned task backup export`; push.

### S30B — Add safe restore/import

- **Capability:** Users can restore absent records into an empty/mostly empty
  account after a fresh successful sync while existing identities always win.
- **Scope / non-goals:** Implement complete input validation/preview, freshness
  prerequisite, durable manifest, dependency ordering, and normal desired-state
  publication. Do not overwrite/delete existing records, match by content, or
  claim cross-account duplicate prevention.
- **Expected modules/files:** backup domain format/validator/planner, import
  manifest schema/DAO, file adapter, ViewModels/views, and integration tests.
- **Tests first:** `PAR-DATA-002`, v1 round-trip plus hostile/
  oversized/malformed files, identity/referential/account/hierarchy checks,
  stale/offline/stopped refusal, existing-wins, empty restore, restart/retry,
  local rollback, remote partial success, and privacy canaries.
- **Verification / visuals:** Unit/store/sync/widget/application integration,
  isolated real-Google empty-list smoke, quality, and actual desktop/phone
  preview/warning/result screenshots.
- **Docs / acceptance / gates:** Publish exact format/version documentation.
  Accept when validation mutates nothing, import is locally all-or-none, manifest
  retry is idempotent in one partition, and limitations are explicit. Gates:
  S19A–S21B, S24B, S29B, and S30A.
- **Commit / push:** `Add safe task backup restore`; push.

### S31 — Add Reset Local Data and recovery controls

- **Capability:** A user can Retry Open non-destructively or explicitly reset one
  selected local account partition, discard its pending state, preserve auth and
  device preferences, and rebuild from Google with truthful health.
- **Scope / non-goals:** Implement reset preview/confirmation, synchronization
  serialization/cancellation, controlled account-partition transaction, rebuild,
  and isolated development reset. Do not silently reset on open, recall already
  sent uncertain mutations, or delete credentials.
- **Expected modules/files:** reset/recovery domain service, database transaction,
  ViewModel/views, coordinator integration, and development-isolation adapter.
- **Tests first:** `PAR-DATA-003`, `PAR-RECOVERY-001`, every pending/uncertain/
  undo/preference/manifest class, auth/device preference preservation, active
  request uncertainty, transaction failure, unavailable Google after reset,
  cross-account isolation, repeated reset, and corrupt DB Retry Open.
- **Verification / visuals:** Store/sync/ViewModel/widget/application integration,
  quality, recovery/reset goldens, and actual desktop/phone warnings and failed/
  rebuilt outcomes.
- **Docs / acceptance / gates:** Accept when only the selected partition is
  discarded after explicit confirmation and an empty cache cannot look Good.
  Gates: S21B, S22A, and S30B.
- **Commit / push:** `Add explicit local data recovery`; push.

### S32A — Add recurrence escape hatch and external links

- **Capability:** Users can manage recurrence through a validated Google
  `webViewLink` and separately open safe user-authored web links.
- **Scope / non-goals:** Implement URL policy/launcher port, separate labels, and
  launch failures. Do not simulate recurrence, conflate link types, or
  shell-execute URLs.
- **Expected modules/files:** URL domain policy/launcher adapter, recurrence and
  user-link widgets, fake launcher, and tests.
- **Tests first:** `PAR-LINK-001`–`003`, valid `http`/`https`, rejected schemes,
  malformed links, launch failure, absent/invalid `webViewLink`, and distinct
  semantics/accessibility labels.
- **Verification / visuals:** Unit/adapter/widget/integration/device, quality,
  P10 probe, and actual desktop/phone link states.
- **Docs / acceptance / gates:** Accept only after current `webViewLink`
  presence/navigation evidence; absence remains explained. Gates: S23A, S29B,
  and API P10.
- **Commit / push:** `Add safe task link actions`; push.

### S32B — Add onboarding, theme, and accessibility polish

- **Capability:** First-run users understand connection, sync truth, offline
  continuity, capture, and recovery in an accessible adaptive presentation.
- **Scope / non-goals:** Implement onboarding over S22A preference, final theme/
  density presentation, semantics, contrast, focus, text scale, and motion
  review. Do not add analytics or new task behavior.
- **Expected modules/files:** onboarding ViewModel/views, shared visual tokens,
  accessibility/golden/device tests, and synthetic screenshot scenarios.
- **Tests first:** `PAR-UX-001/002`, dismissal/default/error, every health state,
  keyboard/touch navigation, semantics, contrast, text scaling, reduced motion,
  and narrow/wide layout.
- **Verification / visuals:** Widget/integration/device, quality, light/dark
  desktop/phone goldens, and actual onboarding/accessibility screenshots.
- **Docs / acceptance / gates:** Accept when onboarding makes no false sync claim
  and all primary workflows remain accessible at supported scales. Gates: S22A,
  S26B, S27B, S31, and S32A.
- **Commit / push:** `Complete onboarding and accessibility polish`; push.

### S33 — Add state-machine and multi-host synchronization evidence

- **Capability:** Generated, replayable multi-host sequences protect convergence,
  safety, liveness, API efficiency, and all twelve reliability invariants through
  production ports and real temporary SQLite.
- **Scope / non-goals:** Implement the accepted model/property layer and deep
  local command over the already completed example matrix. Do not patch missing
  example coverage here; a missing earlier ID must return to its owning slice.
  Do not use sleeps, source strings, expectation-free tests, or network.
- **Expected modules/files:** deep sync suites, reference model, replay corpus,
  state generators/shrinkers, and `scripts/deep_sync.sh`.
- **Tests first:** `MOD-001`–`MOD-004`, generated edits/creates/deletes/moves/
  triggers/auth/crashes, multi-host permutations, fixed regression seeds,
  shrinking, no-progress detection, and exact call bounds.
- **Verification / visuals:** Run all focused sync/persistence/fake suites,
  repeated fixed and generated seeds, killed-process matrix, API-efficiency
  ledgers, `deep_sync.sh`, and quality. No visual review unless a failure surface
  changes.
- **Docs / acceptance / gates:** Link model IDs and record seed replay/duration.
  Accept only if the earlier example-ID audit is already complete; otherwise
  split a correction into the owning slice rather than expanding S33. Gates:
  S09C and S12A–S21B.
- **Commit / push:** `Complete deterministic sync evidence`; push.

### S34A — Close opt-in Google Tasks contract gates

- **Capability:** A dedicated-account suite validates every remaining shipped
  Google Tasks HTTP/fake assumption and cleans all disposable resources.
- **Scope / non-goals:** Complete subject guard, unique prefixes, disposable
  lists, cleanup/failure reporting, and current `API-*`/P10 probes. Do not test
  platform auth here, load normal credentials, or join `quality.sh`.
- **Expected modules/files:** `test/google_contract/`, ignored configuration
  template, `scripts/test_google.sh`, and safe cleanup command.
- **Tests first:** `API-001`–`API-009`, P10 recurrence evidence, subject
  missing/mismatch before first Tasks call, cleanup after every failure point,
  stale-resource cleanup, and credential/task-data artifact scans.
- **Verification / visuals:** Explicit dedicated-account suite, adapter/fake
  contract, normal quality, and repository privacy scan; only sanitized evidence.
- **Docs / acceptance / gates:** Update the API contract by evidence status and
  keep genuine unknowns explicit. Any mismatch stops the affected behavior for
  specification review. Gates: S06–S09C, S20B, S32A, and dedicated account.
- **Commit / push:** `Validate live Google Tasks contracts`; push.

### S34B — Close the physical Android authorization gate

- **Capability:** The final Android composition passes connect, Tasks scope,
  API call, restore, refresh/reauthorization, cancellation, and Stop/Resume on a
  physical device.
- **Scope / non-goals:** Turn the S03 probe into the final isolated regression
  suite against the shipped adapter/composition. Do not add a private plugin,
  background sync, or non-Play-Services support.
- **Expected modules/files:** Android platform/auth integration tests, probe
  script updates, ignored evidence output, and setup docs.
- **Tests first:** Subject mismatch, cancel, restart, expired/terminal auth,
  Stop/Resume preservation, foreground lifecycle, and cleanup/secret scans.
- **Verification / visuals:** Physical-device suite, Android application
  integration, quality, privacy scan, and inspection of native/app states.
- **Docs / acceptance / gates:** Record device/plugin versions and sanitized
  outcomes. Any mismatch stops Android release readiness. Gates: S03, S19B,
  S27B, and dedicated account/device.
- **Commit / push:** `Validate Android Google authorization`; push.

### S34C — Close the Linux authorization and secure-storage gate

- **Capability:** The final Linux composition passes browser PKCE/DPoP exchange,
  secure restart restore, refresh/nonce/key rejection, cancellation, Tasks call,
  and Stop/Resume in a real GNOME session.
- **Scope / non-goals:** Turn S04/S05 probes into the shipped-adapter regression
  suite. Do not add embedded webviews, plaintext fallback, or bypass DPoP.
- **Expected modules/files:** Linux platform/auth integration tests, probe script
  updates, ignored evidence output, and Fedora setup docs.
- **Tests first:** Locked/missing secure store, state/callback mismatch, browser
  cancel, restart, nonce rotation, wrong/missing key, terminal refresh, subject
  mismatch, Stop/Resume, cleanup, and secret scans.
- **Verification / visuals:** Real GNOME browser/Secret Service suite, Linux app
  integration, quality, privacy scan, and inspection of browser/app states.
- **Docs / acceptance / gates:** Record package/platform versions and sanitized
  outcomes. Any mismatch stops Linux release readiness. Gates: S04–S05, S19B,
  S26B, and dedicated account/GNOME session.
- **Commit / push:** `Validate Linux Google authorization`; push.

### S35 — Pass the supported-product release-readiness gate

- **Capability:** A clean Fedora and Android checkout can build, run, and prove
  every retained/redesigned parity capability with truthful health and verified
  release/development privacy separation.
- **Scope / non-goals:** Close cross-feature regressions, curated goldens, actual
  screenshots, supported-device integration, documentation, and parity status.
  Do not add features, CI, packaging, stores, unsupported platforms, or migration.
- **Expected modules/files:** full application integration suites, curated
  goldens, ignored screenshot runner/output, final local verification scripts,
  README/development/setup docs, and parity evidence links.
- **Tests first:** End-to-end cold/warm start, all four health states, offline
  edits/reconnect, auth expiry, Stop/Resume, task/list/subtask/bulk/search/import/
  reset/links, restart with pending/uncertain state, adaptive navigation, and
  release privacy composition.
- **Verification / visuals:** Quality, deep sync, Linux/Android integration,
  goldens, explicit live/platform suites, clean source-only rebuild, and manual
  inspection of every named desktop/phone screenshot with synthetic data.
- **Docs / acceptance / gates:** Mark parity rows verified only from linked
  evidence; document exact build/run/test commands and residual known API limits.
  Accept when all supported gates pass, no blocking TODO remains, and the branch
  is clean. Gates: every prior slice through S34C.
- **Commit / push:** `Complete supported product verification`; push.

## Stage 6 acceptance

This document was approved and converted into the local Stage 7 `ktask` queue.
Approval does not authorize combining slices or bypassing a failed capability
proof. Any dependency discovery that makes a slice too broad must split that
slice in this document before implementation continues.
