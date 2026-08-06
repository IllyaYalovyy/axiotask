# Flutter Stack & Test Harness Research

Input to RFC-011 (architecture). This document RECOMMENDS; the RFC decides.

Method: seven research areas investigated in parallel, every package claim
verified against pub.dev / official docs / package source on 2026-08-05
(training-cutoff knowledge was not trusted). The four highest-risk
recommendations (state management, persistence, mocking/property testing,
auth) were then independently attacked by skeptic reviewers with fresh web
evidence; all four verdicts came back **holds**, with sharpening notes folded
in below. Toolchain baseline: Flutter 3.44.8 stable / Dart 3.12 (pinned).

## The recommended stack at a glance

- State management: **Riverpod 3** (flutter_riverpod 3.4.x), **no codegen**
- Persistence: **drift 2.34.x in SQL-first mode** on package:sqlite3 (bundled SQLite)
- Tasks API client: **hand-rolled typed client** over package:http (~10 endpoints)
- Auth: **googleapis_auth** (desktop PKCE+loopback) + **google_sign_in v7** (Android
  authorizationClient), behind one `TokenProvider` seam
- Test harness: flutter_test volume layer + **alchemist goldens** + **kiri_check**
  properties + **subprocess JSON-lines Rust oracle** + thin `integration_test`
  smoke under xvfb-run + coverage ratchet
- Mocking: **strict hand-written FakeTasksApi** (port of in_memory.rs);
  **mocktail** for boundary seams only; no mockito
- Sync engine: **foreground-only, main isolate**, resumable step machine,
  clock-injected; no workmanager
- Adaptive UI: **hand-rolled list-detail shell**, single 600dp breakpoint,
  **go_router**; no adaptive-scaffold package
- Windowing: **window_manager** for size persistence (min-size set in the GTK
  runner, position-restore dropped on Wayland by design)
- Packaging: **fastforge → RPM** for this Fedora box; flatpak deferred

---

## 1. State management — Riverpod 3, without code generation

flutter_riverpod 3.4.2 (published days before the check; v3 stable since
2025-09-10; dash-overflow.net). Chosen because it is the only surveyed option
that satisfies all five criteria:

- `ProviderContainer.test()` runs the whole provider graph in plain tests with
  no widget tree — state-based assertions via `container.read`, dependencies
  swapped with `overrides`. Exactly our TDD requirement.
- `StreamNotifier` maps DB/sync watch-streams to `AsyncValue`
  (loading/data/error) declaratively; `ref.watch` recomputes dependents when
  sync writes rows under the UI.
- Codegen is officially optional in v3 — zero build_runner in the TDD loop.
- v3 unified Notifier/Ref API; low ceremony; identical on Linux and Android.

Rejected: flutter_bloc (highest ceremony — event+state+bloc classes per
feature contradicts deep-modules/low-ceremony; flutter_bloc 15 months and
bloc_test 19 months without a publish), plain ChangeNotifier (hand-rolled DI,
disposal, async-state machinery; provider pkg is de facto maintenance-mode),
signals (single-maintainer, small adoption).

**Hard rules (skeptic-confirmed):**
- Riverpod 3 auto-retries failing providers (200ms→6.4s backoff). This is a
  DOCUMENTED source of test hangs (riverpod discussion #4431), and
  `ProviderContainer.test()` does NOT disable it by default. The shared
  test-container helper must pass retry-disabled explicitly — a mandatory
  convention, not hygiene.
- Do not use v3 experimental features (offline persistence, mutations).
- Domain logic lives in plain Dart classes; providers are wiring only.

## 2. Persistence — drift 2.34.x, SQL-first, on bundled sqlite3

drift 2.34.3 (simonbinder.eu, active weekly; sponsored by Stream and
PowerSync). The only candidate meeting all six criteria at once:

- `NativeDatabase.memory()` gives true in-memory DBs in plain Dart tests, zero
  platform channels; companion sqlite3_test makes SQLite time functions obey
  package:clock fake clocks.
- Reactive `watch()` queries — table-granularity, timer-free invalidation —
  are the "UI updates when sync writes rows" requirement, and neither sqflite
  (no reactive queries at all, global write lock) nor raw sqlite3 (we'd
  hand-build the watch layer, drift's hardest part) has them.
- drift ≥2.32 sits on package:sqlite3 3.x which BUNDLES its own SQLite via
  Dart build hooks — Linux desktop and Android run the identical engine
  (sqflite cannot: platform-channel Android SQLite vs FFI desktop). Build
  hooks need Dart ≥3.10 / Flutter ≥3.38 — satisfied; record as CI floor.
- Transactions with automatic rollback + nesting cover the sync engine's
  atomicity (inflight-create finalize, pending-move drain).

Usage rules: hand-written SQL in `.drift` files, ported near-verbatim from the
Rust `schema.sql` (5 tables + 3 indexes); keep the reference's PRAGMA
user_version schema-fingerprint wipe-and-recreate — drift's migration tooling
goes unused (pre-1.0 rule). Commit generated code. Every writer, including
the sync engine, goes through the single drift database object (external
writes don't trigger streams). Widget tests must pass
`closeStreamsSynchronously: true` or stream teardown trips the pending-timer
check. Codegen (build_runner) is the accepted cost — SQL-first keeps clarity
in the SQL we write.

## 3. Google Tasks API client — hand-rolled; generated client REJECTED

Decisive verified fact: the generated googleapis tasks_v1 client (16.0.0)
**cannot send If-Match on any method** — only `$fields` is exposed. Etag-guarded
push with 412 conflict semantics is the core of our sync; the generated
client structurally cannot express it. So: a small hand-rolled typed client
over package:http for ~10 endpoints, porting the Rust reference's
probe-verified wire semantics exactly (task PATCH/DELETE honor If-Match →
412; tasklists endpoints IGNORE If-Match; stale If-Match PATCH on a deleted
row returns 200 not 412). DTOs mirror the reference, easing the equivalence
oracle; error taxonomy maps 1:1 (401/404/412). Skip
extension_google_sign_in_as_googleapis_auth — with our own client we need
only the access-token string.

## 4. Auth — one TokenProvider seam, two platform implementations

Seam: `abstract class TokenProvider { Future<String> accessToken({bool
interactive = false}); void invalidate(); }`. Engine and client are tested
headlessly against a FakeTokenProvider; only the platform adapters are
on-device-manual.

- **Desktop**: googleapis_auth 2.3.3 (google.dev, active).
  `obtainAccessCredentialsViaUserConsent` is source-verified to implement
  auth-code + PKCE S256 + localhost loopback — exactly RFC-001's flow.
  Tokens persist as a 0600 `tokens.json` in the XDG data dir behind a
  TokenStore interface (matches the proven reference; flutter_secure_storage's
  libsecret backend needs a keyring daemon — hostile to headless tests — and
  can slot in behind the same interface later). Note: googleapis_auth's README
  disclaims Flutter use, but that advice presumes google_sign_in exists on the
  platform — it has NO Linux support; fallback if ever needed is package:oauth2
  (has codeVerifier) or ~200 LOC hand-rolled.
- **Android**: google_sign_in 7.2.0 (flutter.dev). Source-verified: its Android
  implementation uses androidx CredentialManager for authentication and Play
  Services `Identity.getAuthorizationClient` for scope authorization — the
  exact stack RFC-010 converged on after two redesigns. v7's
  `authorizationClient` (`authorizationForScopes` silent → `authorizeScopes`
  on user gesture) yields Tasks-scope access tokens with ZERO app-side token
  persistence. Expiry = catch 401, re-call authorizationForScopes. v7 issues
  tokens only against requested scopes (flutter#171835) — fine, Tasks scope is
  always requested. Requires a WEB OAuth client id as `serverClientId` +
  package/SHA-1; misconfiguration surfaces as an ambiguous 'canceled'
  exception — **an on-device physical-phone gate (G5-equivalent) stays
  mandatory** for any auth change. Community desktop plugins
  (google_sign_in_all_platforms, google_sign_in_desktop) were checked and
  rejected (small adoption; token-persistence models conflict with ours).

## 5. Test harness — layered, all headless on this machine

- **Volume layer**: plain flutter_test widget tests. Drive form factors via
  `tester.view.physicalSize`/`devicePixelRatio` (phone ~412x915 @2.6, desktop
  ~1280x800 @1.0) and text scales via
  `tester.platformDispatcher.textScaleFactorTestValue` (1.0/1.3/2.0) — all
  first-party, no packages.
- **Goldens**: alchemist 0.14.0 (Betterment, active) over matchesGoldenFile;
  golden_toolkit is DISCONTINUED (do not adopt); flutter_test_goldens is 0.0.x
  (re-evaluate at 1.0). Real app fonts loaded once in flutter_test_config.dart.
  Single-host goldens (this Fedora box, pinned Flutter) are deterministic;
  Flutter upgrades are planned golden-regeneration events (flutter test still
  renders via Skia on Linux; an eventual Impeller switch shifts all goldens).
- **Properties**: kiri_check 1.3.1 — the only maintained Dart PBT library with
  stateful/model-based testing, sequence shrinking (verified in source), and
  documented seeding. Single-maintainer risk: pin the version, wrap behind a
  thin internal facade, use for pure-function and single-engine model tests
  only. glados is dormant (2023); mockito's codegen buys nothing — skip both.
- **Equivalence oracle** (the load-bearing piece): a custom seeded op-sequence
  generator (ported from sync_property_test.rs's op vocabulary — the Rust
  suite already uses proptest as a mere seeded runner, so no PBT framework is
  needed) drives the Dart engine in-process and the Rust engine via a
  subprocess speaking JSON-lines over stdin/stdout — the protobuf-conformance
  shape (~150-line testee). One `axiotask-oracle` bin target gets added to the
  Rust workspace (additive, test-only — needs user OK). Crash-isolated,
  replayable: failing sequences persist as language-neutral JSON-lines corpus
  files. Soak depth via env knob (the AXIOTASK_PROPTEST_CASES pattern) — that
  is our fuzzing story; no coverage-guided fuzzer exists for Dart app code.
- **Real-app smoke**: thin integration_test suite (3-5 tests: launch, DB open,
  list renders, one CRUD round-trip) run as `xvfb-run flutter test
  integration_test -d linux` — first-party, catches launch/plugin failures
  widget tests structurally cannot (the Tauri e2e lesson). patrol REJECTED:
  no Linux desktop support at all and needs a device.
- **Time discipline**: package:clock everywhere (`DateTime.now()` banned in
  product code), fake_async for engine timer logic, tester.pump over
  pumpAndSettle on repeating animations. clock + fake_async are Dart-team
  stable primitives.
- **Coverage**: `flutter test --coverage` + a ratcheting lcov threshold parsed
  in verify.sh (a 10-line parse; very_good_cli not required).
- **The strict fake**: FakeTasksApi hand-ported from in_memory.rs (2,074 lines
  — the realistic cost bar), the ONE test double for the Tasks API; mocktail
  1.0.5 only for boundary seams (token provider, platform channels). Port the
  fake test-first against the reference's semantics; the live-API probe
  remains its ground truth.

## 6. Sync engine shape — foreground-only, main isolate, kill-safe

Matches the ratified reference behavior (foreground-only was declared
acceptable). The engine is a pure-Dart, clock-injected, resumable step
machine over the drift DB: every step is one small SQLite transaction, so an
Android process death anywhere = clean resume on next launch. Kill-safety is
enforced by tests (stop after each persisted step, re-instantiate, assert
convergence) — which is also exactly the shape the oracle tests need.
Scheduling: Timer + package:clock in the main isolate; on-demand, periodic
while resumed, and on AppLifecycleListener.onResume. drift's
NativeDatabase.createInBackground already keeps SQLite I/O off the UI isolate.
REJECTED: worker isolate (drift docs: "probably not necessary"; kills
fake_async testability), workmanager/background_fetch (15-minute floor, no
timing guarantee, needs a second headless-untestable auth+DB bootstrap in a
background isolate; drift's isolate support keeps that door open if ever
demanded).

## 7. Adaptive UI — one hand-rolled shell, go_router

flutter_adaptive_scaffold is DISCONTINUED (team support ended 2025-04-30);
forks are micro-adoption. The durable answer is the framework: one
~100-line ListDetailScaffold branching on `MediaQuery.sizeOf().width` at
600dp — NavigationBar + pushed detail route on compact, NavigationRail +
side-by-side detail pane at 600dp+ — with the SAME TaskListView /
TaskDetailView widgets composed either way. One widget tree, no forked
screens; golden-tested headlessly at both form factors. Navigation:
go_router 17.4.0 (flutter.dev, published ~30h before check;
"feature-complete" bug-fix-only mode is a stability asset for routing) with
ShellRoute keeping the shell mounted; Android back semantics come free.

## 8. Linux desktop — production target, with named mitigations

The platform cleared its historical disqualifiers: Canonical is lead
maintainer of Flutter desktop (announced I/O 2026), Ubuntu ships Flutter
system apps in production, and the engine runs as a native Wayland client
(no forced X11 in engine or template). VisualDensity resolves to compact on
Linux automatically (desktop density for free). Known open issues, each with
a mitigation the design doc must carry:

- Fractional scaling: fonts scale, content doesn't (#127768, stale) — verify
  early on this box; mitigation is integer scaling.
- IME surrogate-pair abort (#190046, active) + a TextField freeze report
  (#153560) — low exposure (English typing), manual smoke per Flutter upgrade.
- Wayland gives no window-position API and window_manager's
  setMinimumSize silently no-ops on Wayland (#538) — set min/default size in
  the app-owned GTK runner C file; persist SIZE only, drop position-restore
  by design (the Rust app's geometry-restore hang is the cautionary tale —
  never block first frame on restore).
- window_manager (0.5.2) is mid-migration to nativeapi-flutter — pin and wrap
  all window calls behind one seam.
- GTK header bar is the template default on Wayland (#111453) — deliberate
  look decision needed in the runner.
- Startup: renderer is still Skia/OpenGL (Impeller-Vulkan not landed);
  measure release-build cold start against the 2s budget as an early gate.
- Packaging: fastforge 0.6.12 → local RPM for this box; flatpak deferred
  (AppFlowy shows it works, at 162 MiB scale); AppImage only with the
  documented graphics-lib exclusions. System tray SKIPPED — needs a GNOME
  shell extension (fails "meaningful defaults"); autostart optional/cheap.

## Decisions this doc leaves to RFC-011 (user ratifies)

- D1: Adopt the stack above (each line is individually reversible until code
  lands on it).
- D2: Add the `axiotask-oracle` bin target to the Rust repo (additive,
  test-only) — touches the reference implementation.
- D3: Pixel-faithful port of the current UI vs Material-native equivalents of
  the same UX contracts (changes the whole UI mapping and golden baseline).
- D4: Desktop token storage: plain 0600 tokens.json (recommended, matches
  reference) vs libsecret now.
- D5: Coverage floor to start the ratchet at.

Full per-area findings with sources: workflow run wf_a4ba44fb-72e
(11 agents, 2026-08-05); key sources inline above.
