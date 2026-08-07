# RFC-011: Flutter Migration Architecture

| Field         | Value         |
|---------------|---------------|
| Status        | Accepted (2026-08-06) |
| Author(s)     | Illya Yalovyy |
| Supersedes    | — (continues the RFC line of the Tauri repo, whose designs remain the behavioral reference) |
| Superseded by | —             |

---

## Summary

axiotask is rewritten from Tauri/Rust+Svelte into pure Flutter/Dart: one
codebase, one UI, for Linux desktop and Android (ratified 2026-08-05, GitHub
issue #173 in the reference repo). This RFC defines the architecture of the
rewrite: the module map (deep modules behind narrow interfaces), the test
harness that is built BEFORE the code it tests, the cross-language
equivalence oracle that proves the Dart sync engine against the working Rust
one, and the branch strategy under which the `flutter` branch eventually
replaces `main`. Stack choices are grounded in
[[RESEARCH-flutter-stack]] (web-verified 2026-08-05, skeptic-reviewed).
This is the chance to make it right: clarity, testability, and
maintainability outrank speed of porting.

---

## Goals

- **G1** — Capability and efficiency parity with the reference app (every
  workflow in its ux_decisions.md; useful options in 1–2 interactions;
  meaningful defaults; superior to the Google Tasks app) — delivered through
  a UI that is a clear upgrade, not a port: more beautiful, responsive,
  adaptive, and fluid than the Tauri UI it replaces (Q3, ruled).
- **G2** — The sync engine is provably equivalent to the Rust reference:
  identical op sequences produce identical states, demonstrated by a
  differential oracle, before the reference is deleted.
- **G3** — Deep modules, simple interfaces: each subsystem is replaceable
  behind one narrow abstract class; the UI is a thin shell over a pure-Dart,
  headlessly-testable core.
- **G4** — The test harness exists before the code: every layer of the
  pyramid (unit, property, widget, golden, integration smoke) is stood up and
  red-checked in Step 0, so TDD is mechanical from the first feature.
- **G5** — Every behavior contract learned in the reference project carries
  over: strict live-verified API fake, kill-safe sync, three auth states,
  safe areas, 48dp targets, reveal-without-reflow, undo-over-confirm,
  one icon set, quiet sync.
- **G6** — The dev/test environment can never touch the user's production
  data (isolated data dir behind a dev flag, from the first commit).

## Non-Goals

- **NG1** — iOS, web, Windows, macOS. Linux desktop + Android only.
- **NG2** — Background sync while the app is closed (foreground-only, like
  the reference — ratified acceptable). The engine's shape keeps the door
  open (pure function over the DB) but no workmanager integration ships.
- **NG3** — Feature additions during the port. Parity first; new ideas go to
  the backlog. (Exception: mobile swipe quick actions, which are the point.)
- **NG4** — Keyboard-shortcut parity. Keys were never the driving factor;
  the RFC-007/008 keyboard layer of the reference is NOT ported. Basic
  focus/enter/escape behavior comes free from Flutter; nothing more.
- **NG5** — Migration tooling for user data. Pre-1.0 rules apply: the Dart
  app builds its DB from a fresh Google sync (or fresh local state); it does
  not read the Rust app's SQLite file.

---

## Background & Motivation

The Tauri implementation works well on desktop — the user explicitly likes
its UX — but is structurally wrong on Android (webview selection/context-menu
conflicts, no native gesture feel), and nobody wants to maintain two UIs.
The decision (#173) is a full rewrite in one language with one UI. The
reference implementation is complete, live-probe-verified, and stays
available read-only at `../axiotask` as the behavioral spec and as the
equivalence oracle until parity.

What the reference project taught us, at cost:

- A green gate on one platform proves nothing about the other — cross-compile
  and on-device gates are non-negotiable (task-129/RFC-010).
- Auth flows are not done until they run against the real endpoint on the
  real platform (#158 vs #165).
- The API fake must mirror verified reality exactly, or tests lie
  (live-API probe: If-Match 412s, tasklists ignoring If-Match, cascades).
- Sync correctness came from a property suite + strict fake + a small,
  capped mechanism surface — and from refusing to grow it.
- UI defects cluster where no expert looked: safe areas, touch targets,
  hover reflow, toast stacking (#165–#168).

## Considered Options

### Option A — UI-first port (screens first, faked backend, core later)

**Pros**: visible progress immediately; UX decisions surface early.
**Cons**: the faked backend hardens into a second spec; sync — the highest-
risk subsystem — lands last, when everything already leans on assumptions
about it; the oracle arrives too late to steer the engine's design.

### Option B — Bottom-up core first (store → api → sync → then all UI)

**Pros**: hardest parts proven first; oracle drives the engine from day one.
**Cons**: weeks with nothing on screen; UX contracts (adaptive shell, swipe
actions) get no early feedback; morale/course-correction risk.

### Option C — Harness first, then a walking skeleton, then depth

Step 0 builds the full test harness (all five layers, red-checked). Step 1
ships a walking skeleton: a real, launchable, local-only app — adaptive
shell, one list view, quick-add — sitting on the real store. Then the core
deepens bottom-up (api+fake → sync engine against the oracle → auth) while
the UI grows view by view on top of already-proven layers.

**Pros**: TDD is mechanical from the start; something real runs within days;
sync is developed against the oracle, not before it; UI and core progress in
parallel without blocking each other.
**Cons**: requires discipline to keep the skeleton thin instead of
gold-plating the first view.

---

## Decision

**Chosen option: Option C** — harness first, walking skeleton, then depth.
Stack per [[RESEARCH-flutter-stack]]: Riverpod 3 (no codegen), drift
(SQL-first), hand-rolled Tasks API client, googleapis_auth (desktop) +
google_sign_in v7 (Android) behind one TokenProvider, alchemist goldens,
kiri_check properties, subprocess JSON-lines oracle, go_router + hand-rolled
600dp adaptive shell.

*(Ratified by the user 2026-08-06; all open questions resolved — see below.)*

---

## Design

### Package layout (one app package; deep modules as source folders)

```
lib/
  src/
    model/     pure value types + pure logic
    store/     drift database — the local truth
    api/       Google Tasks wire client + strict fake
    auth/      TokenProvider seam + platform adapters + auth state
    sync/      the engine: push/pull/reconcile step machine
    app/       composition root: providers, commands, config, dev-mode
    ui/        adaptive shell + views + widgets (thin)
  main.dart
test/          mirrors lib/src/ one-to-one
integration_test/  smoke suite (real app under xvfb-run)
tool/oracle/   op-sequence generator + Rust-testee driver + corpus
```

Dependency rule (enforced by review, checkable by import lint): `model` ←
`store` ← `sync` → `api`; `auth` is beside `api`; `app` wires everything;
`ui` imports only `app` (providers) and `model` (types). Nothing imports
`ui`. No Flutter imports below `app` — `model/store/api/auth/sync` are pure
Dart, testable without a widget binding.

### The modules and their narrow interfaces

- **model/** — `Task`, `TaskList`, `SyncState`, typed ids; effective-date
  function (`due ?? earliest unfinished subtask date`, parents only);
  ordering rules; natural-language date parsing for quick-add. Pure Dart,
  zero dependencies. The subtask invariant (strictly one level) is a type-
  level fact: a task carries `parentId?`, and no API in the codebase accepts
  a parent that itself has a parent.
- **store/** — one class `Store` over drift: typed queries, `watch*` streams
  (list rows, task detail, counts), transactions, and the schema-fingerprint
  wipe-and-recreate (PRAGMA user_version = hash of schema; on mismatch,
  JSON-export backup then recreate — ported from the reference). Schema is
  hand-written SQL in `.drift` files, ported from `schema.sql` (5 tables:
  task_lists, tasks with base_* conflict snapshots, pending_moves, sync_log,
  inflight_creates). All writers — commands AND sync — go through this one
  object, so reactive streams see everything.
- **api/** — `abstract class TasksApi` (~10 methods mirroring the reference's
  `api/traits.rs`), error taxonomy (`Unauthorized`, `NotFound`,
  `PreconditionFailed`, `Transient`). Implementations: `HttpTasksApi`
  (hand-rolled over package:http; per-endpoint If-Match exactly as
  live-probe-verified — task PATCH/DELETE send it, tasklists never) and
  `FakeTasksApi` — the strict fake, ported test-first from `in_memory.rs`
  (2,074 lines; the ONE test double for the Tasks API, never loosened).
- **auth/** — `abstract class TokenProvider { Future<String> accessToken({bool
  interactive = false}); void invalidate(); }` plus `AuthController` owning
  the three-state model (signedOut / signedIn / needsReauth — never two).
  Desktop impl: googleapis_auth PKCE+loopback, credentials in a 0600
  tokens.json under the app data dir behind a `TokenStore` interface.
  Android impl: google_sign_in v7 authorizationClient — silent
  `authorizationForScopes` at startup and on 401; `authorizeScopes` only from
  a user gesture; zero app-side token persistence. A `FakeTokenProvider`
  serves every headless test.
- **sync/** — `SyncEngine.run()`: a resumable step machine over Store +
  TasksApi. Push first (etag-guarded, per-row resolution: landed /
  conflicted-copy / left dirty), then pull as plain refresh skipping dirty
  rows. Every step is one small transaction — kill anywhere, resume clean
  (this is Android's real lifecycle requirement and is test-enforced).
  Conflict semantics are RFC-009 of the reference, unchanged. A
  `SyncScheduler` (clock-injected: periodic while resumed, on-demand,
  on-app-resume, attention backoff) owns all timers; the engine itself has
  none. The mechanism budget carries over: the Dart engine may not grow
  mechanisms beyond the reference's set; the LOC-ratchet returns to the gate
  once the engine lands.
- **app/** — composition root. Riverpod providers wire the modules (retry
  disabled in the shared test container — mandatory); a thin command layer
  holds the multi-step user operations exactly where the reference has them
  (parent/child date cascade as one shared primitive + one undo unit; delete
  with undo token; move-to-list clone-under-new-ids). Config, versioning
  (About), and dev-mode: `AXIOTASK_DATA_DIR` env / `--dart-define` switches
  the data root; dev instances NEVER touch production data (G6).
- **ui/** — one `ListDetailScaffold` branching at 600dp: NavigationBar +
  pushed detail route (compact) vs NavigationRail + side-by-side pane
  (expanded); same child widgets both ways, no forked screens. go_router
  with ShellRoute; any redirect policy is a pure function adapted into
  `GoRouter.redirect`, unit-tested without pumping an app. Views: smart views (Focus / Upcoming / Missed /
  Unscheduled / All), list views, detail panel (subtasks live ONLY here),
  quick-add with NL date preview, search overlay, properties, toasts.
  Mobile: swipe left/right quick actions on rows — designed as the primary
  interaction, not an add-on. The VISUAL design is fresh (Q3): Material 3
  foundation, deliberate motion and fluidity, adaptive by construction —
  the Tauri UI's look is explicitly not the target, its capabilities are.
  Carried contracts: 48dp hit areas around unchanged glyphs;
  reveal-without-reflow; toast/undo visible above every overlay; safe areas
  everywhere; one icon set (no emoji glyphs); undo instead of confirm for
  undoable destructive actions.

### The equivalence oracle (temporary scaffolding, then deleted)

A ~150-line `axiotask-oracle` bin target is added to the Rust workspace
(additive, test-only — Q2). Protocol: JSON op per line on stdin (the op
vocabulary of `sync_property_test.rs` §A–§J: create/edit/complete/delete/
move/reparent locally, remote mutations on the fake server, sync runs,
crash-restart points), ack per line on stdout; final `{"cmd":"dump"}` returns
canonical state (lists + tasks sorted by title, normalized dates, sync
markers). The Dart side runs the same ops against SyncEngine + FakeTasksApi
in-process and deep-compares dumps. Sequences come from a seeded hand-rolled
generator (no PBT framework dependency); failures persist as JSON-lines
corpus files, replayable from either side; soak depth via env knob. When the
Dart engine reaches sustained parity (full corpus + N-million-case soak
green), the oracle, the corpus, and the Rust repo's role end together — per
project principle, transition scaffolding leaves no trace in the shipping
tree (`tool/oracle/` is deleted in the cutover commit).

### Branch and cutover strategy

Work happens on `flutter` (orphan branch, this repo). The Rust `main` stays
frozen except for: the oracle bin target (Q2) and critical fixes the user
still needs day-to-day. Cutover criteria: G1 parity checklist green, oracle
parity sustained, on-device Android gate passed (sign-in + sync round-trip +
swipe UX on the physical phone), desktop RPM installed and in daily use by
the user. Then `flutter` replaces `main` (force-push after user sign-off);
the Rust tree survives only in git history. The Android applicationId is
already `com.axiotask.app` — installing the Flutter build replaces the Tauri
app on the phone (deliberate; do not install before the Tauri G5 gate is
retired or passed).

### What is deliberately NOT ported

The keyboard layer (RFC-007/008, `shortcuts.js`, Cheatsheet), the Tauri IPC
layer and its `Ok(())`-null lore, the deep-link/custom-scheme remnants'
history, tauri-plugin-google-auth (google_sign_in v7 replaces it), the
Svelte component tree (contracts carry, code doesn't), and desktop keyboard
cheatsheet UI. Their absence is by decision, not omission.

---

## Testing Strategy

The harness is Step 0 and every layer is red-checked (a deliberately broken
assertion must fail) before any feature code exists:

- **Unit (pure Dart)**: model, dates, reconcile rules, command primitives —
  plain `test()`, no binding. package:clock everywhere; `DateTime.now()` and
  raw `Timer` are banned in `lib/src/{model,store,api,auth,sync}` (grep-
  enforced in the gate).
- **Store tests**: real drift on `NativeDatabase.memory()`; transaction and
  watch-stream behavior asserted on state.
- **API contract tests**: HttpTasksApi against a scripted fake http.Client
  (wire-level: If-Match presence per endpoint, error mapping); hand-written
  DTO parsing with malformed-response tests (missing fields, nulls,
  unexpected types, truncated bodies); FakeTasksApi ported test-first — each
  behavior pinned by a test citing the live probe or Google docs, mirroring
  `in_memory.rs`.
- **Property layer**: kiri_check (pinned, behind a facade) for pure-function
  properties; the seeded op-sequence suite for engine invariants (eventual
  push, convergence, idempotency, deferral safety, crash safety, parent
  integrity — the reference's six), each sequence also runnable against the
  oracle.
- **Widget + golden**: flutter_test with size/density/text-scale matrices
  (phone 412×915@2.6, desktop 1280×800@1.0; text 1.0/1.3/2.0); alchemist
  goldens as the headless screenshot loop, real fonts via
  flutter_test_config.dart, single-host baseline, Flutter upgrades =
  planned golden-regen commits. Widget tests assert what renders
  (find.text/semantics), never which provider method was called.
- **Integration smoke**: 3–5 `integration_test` cases (launch, DB opens,
  list renders, CRUD round-trip, clean exit) under `xvfb-run flutter test
  integration_test -d linux` — the real-binary gate the mocked layers
  structurally cannot replace.
- **Gate** (`.ktask/verify.sh`, already live): TDD-evidence check, format,
  analyze --fatal-infos, tests, coverage ratchet (floor: Q5), debug-APK
  build on product changes, Linux build when toolchain present; oracle soak
  is a scheduled deep run, never inline in a worker's gate.
- **Cannot be tested in CI**: real Google server behavior (live probe stays
  the fake's ground truth, run manually); Android auth identity
  (package+SHA-1, consent sheet) and swipe feel — physical-phone gates, the
  human's step, never queued to the fleet.

---

## Development Plan

- [ ] **Step 0 — Harness**: all five test layers stood up on a hello-world
  core and red-checked; clock/DI conventions; coverage ratchet armed; gate
  extended (grep bans, coverage, `dart run custom_lint` for riverpod_lint)
  *(prerequisite: —)*
- [ ] **Step 1 — Model + Store**: value types, effective date, NL dates;
  schema port + fingerprint wipe; watch streams *(prerequisite: Step 0)*
- [ ] **Step 2 — Walking skeleton**: launchable local-only app — adaptive
  shell, All Tasks view on real store, quick-add, detail panel skeleton;
  first goldens; integration smoke goes live *(prerequisite: Step 1)*
- [ ] **Step 3 — API + strict fake**: TasksApi, HttpTasksApi, FakeTasksApi
  ported test-first; wire contract tests *(prerequisite: Step 1)*
- [ ] **Step 4 — Oracle testee + generator**: Rust bin (after Q2 approval),
  Dart driver, corpus plumbing; reference sequences replay green against the
  Rust engine *(prerequisite: Step 3)*
- [ ] **Step 5 — Sync engine**: step machine built invariant-by-invariant
  against the property suite AND the oracle; kill-safety tests; scheduler;
  mechanism budget + LOC ratchet re-armed *(prerequisite: Step 4)*
- [ ] **Step 6 — Auth**: TokenProvider seam, desktop PKCE flow + TokenStore,
  AuthController three states; sign-in UI states as goldens
  *(prerequisite: Step 3)*
- [ ] **Step 7 — UX parity, desktop**: smart views, search, move/reparent
  pickers, bulk add, properties, undo toasts, sort; goldens per view;
  the user starts daily-driving the RPM *(prerequisite: Steps 2, 5, 6)*
- [ ] **Step 8 — Mobile UX**: swipe quick actions, safe areas, IME behavior,
  long-press multi-select, FAB/pull-to-refresh decisions per ux_decisions;
  phone-size goldens *(prerequisite: Step 7)*
- [ ] **Step 9 — Android auth + on-device gate**: google_sign_in v7 adapter;
  GCP web client id config; PHYSICAL-PHONE gate: sign-in, sync round-trip,
  session restore, swipe UX *(prerequisite: Steps 6, 8)*
- [ ] **Step 10 — Parity soak + cutover**: oracle corpus + deep soak
  sustained green; parity checklist signed off by the user; oracle deleted;
  `flutter` replaces `main` *(prerequisite: Steps 7–9)*

Steps map to fleet-sized tasks in the detailed migration plan (next
document); each step's completion includes its gate additions.

---

## Open Questions

- [x] **Q1** — **Ratified 2026-08-06**: the stack as researched, including
  the external-review deltas: Riverpod 3 + riverpod_lint / drift /
  hand-rolled client / googleapis_auth + google_sign_in v7 / alchemist /
  kiri_check / go_router.
- [x] **Q2** — **Approved 2026-08-06**: the test-only `axiotask-oracle` bin
  target may be added to the Rust repo (additive, test-only; the one write
  this plan makes to the reference).
- [x] **Q3** — UI fidelity — **ruled 2026-08-05**: NOT pixel-identical and
  not a faithful visual port; "the reason we are replacing Tauri is that the
  Tauri UI sucks." The new UI is a fresh design: much better, more
  beautiful, responsive, adaptive, and fluid, with very ergonomic UX. What
  carries over is the UX capability contract (ux_decisions.md workflows, the
  1–2-interaction efficiency bar, meaningful defaults) — not the visuals.
  Golden baselines are authored fresh for the new design.
- [x] **Q4** — **Ruled 2026-08-06**: plain 0600 tokens.json under the app
  data dir behind the TokenStore interface (as recommended); libsecret can
  slot in behind the same interface later if ever wanted.
- [x] **Q5** — **Ruled 2026-08-06**: as recommended — the coverage ratchet
  arms at the coverage measured at Step 1 completion and only ratchets up.
- [x] **Q6** — **Ruled 2026-08-06**: the Rust `main` is frozen for the
  transition — critical fixes and the oracle bin target only. Disposition of
  the unmerged task-129 branch (Tauri Android auth awaiting its phone gate)
  is tracked separately with the user.
