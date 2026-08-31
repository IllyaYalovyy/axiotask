# Migration Plan — Tauri/Rust → Flutter/Dart

The detailed, file-by-file / function-by-function / test-by-test plan required
by RFC-011 (Accepted 2026-08-06) and issue #173. Revision 2 — refined after a
4-lens adversarial review (27 findings, all folded in; see git history for
revision 1). This document is the map and the work order; the complete
per-file inventories (every public function, every test name with the
behavior it protects) are committed alongside it:

- `designs/migration/inventory-core.md` — axiotask-core: 25 files, 251 public
  functions, enumerated tests
- `designs/migration/inventory-app.md` — app layer: 29 commands, enumerated
  tests, property-suite op vocabulary, e2e assertions, startup wiring
- `designs/migration/inventory-ui.md` — 18 components' behavior contracts,
  8 JS modules, 69 test suites / 557 cases each marked [PORT] or [DIES]

Counting rule: task done-criteria refer to "the enumerated tests of <file>
per the inventory" — the inventory listing is authoritative, not any numeric
shorthand in this document. `<reference-repo>` = the Tauri repo (branch
`main`) beside this one. Ruling context: fresh UI design (Q3) — UI maps at
BEHAVIOR-CONTRACT level; capability and efficiency carry, pixels do not.

---

## 1. Global mapping rules

Language and shape:

- Rust `struct`/`enum` → Dart class / sealed class; `Option<T>` → `T?`;
  `Result<T, E>` → typed exceptions (sealed unions per module mirroring
  error.rs / api / store / sync errors) — is_transient / is_auth_expired
  classification carries verbatim.
- Traits → abstract classes: `GoogleTasksClient`→`TasksApi`,
  `TokenStore`→`TokenStore`, `MobileTokenProvider`+RefreshFn→`TokenProvider`,
  `SyncNotifier`→stream.
- Every `#[cfg(test)]` module → a mirror `_test.dart` file; test NAMES and
  protected behaviors port 1:1 from the inventories; every ported test is
  red-checked.
- Timestamps via injected `clock`; `DateTime.now()`/raw `Timer` banned below
  `app/` (gate grep — the port of tests/timestamp_audit.rs).
- All SQL ports near-verbatim from `schema.sql` into `.drift` files.

The big structural simplification — no IPC boundary:

- The 29 commands become methods on app-layer services; `*_inner` twins
  disappear. Read-side DTOs (TaskView, TaskListView, AppSettings mirrors…)
  DIE — widgets watch store streams and domain types. Surviving value types:
  DeleteToken, DueUndoEntry/SetDueResult, ExportResult/ImportResult,
  RestoreSummary, SyncStatus.
- SyncStatus drops BOTH `last_raw_error` (stays PRIVATE to the scheduler as
  a dedup key — #131's guarantee becomes a test: the exposed status carries
  no raw text) AND `changed_list_ids` (drift watch streams make per-query
  refresh automatic; the incremental-refresh DTO plumbing is obsolete —
  scoped-refresh becomes per-widget `select`/`distinct` filtering plus an
  explicit editing guard, see §4).
- ipc.js dies as mechanism; two contracts carry with a NAMED home: (a) the
  command WATCHDOG — a timeout wrapper in the commands service with the
  per-family budgets (sync/backup long, auth user-paced, default fast-fail)
  and the ported hung-command test; (b) the error-redaction allowlist —
  `user_error` + `friendlyError` merge into one `userMessageFor` in the
  commands service (#128/#135 tests port against it).

Settings and preferences (RULED here, closing review finding):

- `config.json` beside the DB (OUTSIDE the schema fingerprint): GoogleConfig
  (desktop client id/secret) + SyncConfig (push_enabled default OFF,
  auto_sync default ON). The #171 persist-first contract translates
  directly: write file durably FIRST, flip in-memory state only on success —
  both write-failure tests port against the file store.
- `prefs.json` beside the DB: all UI prefs (theme, view, sort-per-view,
  showCompleted, excludedLists, listOrder, onboardingSeen, hideCompleted-
  Subtasks, window size). Replaces localStorage; SURVIVES schema wipes,
  `clear_all`, and fresh sync (localStorage parity). Instance isolation
  falls out of the per-instance data dir. There is NO ui_prefs DB table.

Dies globally, by decision (no trace):

- Keyboard layer: RFC-007/008, shortcuts.js, Cheatsheet (its first-launch
  ONBOARDING intro survives), KeyboardNav suite, [DIES]-marked key cases.
  shortcuts.js's action list is the checklist: every action it names must
  have a pointer/touch affordance (§4 assigns them; ux-review enforces).
- Tauri: IPC, plugins, tauri-plugin-google-auth (google_sign_in v7),
  `Ok(())`-null lore, init-script prefix injection, WebviewWindow wiring,
  android_build_scaffolding.rs (gate's `flutter build apk` replaces it),
  tauri-driver e2e (integration_test replaces it), mobile-smoke.sh.
- Web/webview workarounds: custom DatePicker.svelte (Material picker + the
  LOCAL-date/Today/Clear/opens-on-value-month contract), HTML5 drag
  mechanics (reorderables; step-count semantics carry), localStorage +
  storage.js (→ prefs.json), Svelte error boundary (ErrorWidget/zone +
  startup-error screen), Icon.svelte (Material icons; no emoji glyphs),
  theme.css. Desktop window TITLE contract ("<View> — axiotask") is NOT
  dead — re-honored via window_manager (T2.2).
- tests/version_consistency.rs (pubspec is the single version source).

---

## 2. Core mapping (file → file)

`model/` — Step 1:

- model.rs → `lib/src/model/` (task, task_list, base_snapshot, page). All 10
  types 1:1; TaskStatus wire strings; TaskPatch.isEmpty. Enumerated tests.
- dates.rs → `model/dates.dart`: normalize_due, nowUtcString (clock),
  DateMove + month-clamp. Enumerated tests (leap years, Feb-30 rejection,
  prefix parsing, no-panic).
- **Quick-add natural-language date parser** (today/tomorrow/next week/next
  month/"on YYYY-MM-DD", strip-leaves-title rule) → `model/quick_add_parse.
  dart` — per RFC-011 this is model-layer; built in Step 1, not Step 2.
- taskTree.js → `model/task_tree.dart`; effective-date propagation →
  `model/effective_due.dart` (min of own due + unfinished-subtask dates,
  recursive, completed cuts subtree). Enumerated tests from taskTree.test.js
  + SubtaskDatePropagation as pure units.

`store/` — Step 1:

- schema.sql → `store/schema.drift` — the 5 tables + 3 indexes verbatim.
  (No ui_prefs table — see §1.)
- store/mod.rs → `store/database.dart`: open/openMemory, WAL+FK, fingerprint
  wipe-and-recreate (user_version stamp, fail-open WipeAborted, durable
  timestamped pre-wipe JSON dump, wipe drops views/triggers). Enumerated
  tests 1:1 — the pre-1.0 safety net, never simplified. NOTE: a schema wipe
  destroys cache only; config.json/prefs.json live outside it by design.
- store/repo.rs → `store/store.dart` + `store/store_sync.dart`. All 38
  public methods by name; upsert CASE base-snapshot logic, local_updated
  race guards, tombstones, deferred-FK remap transactions, rehome,
  server_may_hold. The enumerated repo tests port 1:1, partitioned between
  T1.3/T1.4a/T1.4b as listed in §5. Plus new `watch*` stream variants.
- export.rs → `store/backup.dart` (enumerated tests 1:1).
- config.rs → `app/config.dart` over config.json (ruling in §1): instance
  prefix sanitize + PANIC-on-invalid, SyncConfig defaults, #170 path
  threading, #171 persist-first. TOML/comment-preservation dies with the
  format; enumerated tests port minus the TOML-comment ones.

`api/` — Step 3:

- api/traits.rs → `api/tasks_api.dart` (10 methods, exact If-Match shape).
- api/error.rs → `api/api_error.dart` (8 variants + isTransient).
- api/http.rs → `api/http_tasks_api.dart`: every wire rule ports as a named
  test — pagination-to-completion, showCompleted+showHidden, maxResults=100,
  URL-encoding, If-Match on task PATCH only, NO If-Match on task DELETE (P4)
  or tasklist PATCH (D6), move's `Content-Length: 0`, 401→refresh-once
  (Denied→AuthExpired, no replay), 403 body-split, Retry-After + backoff,
  409|412→PreconditionFailed. Enumerated tests against a scripted fake
  http.Client.
- api/in_memory.rs → `api/fake_tasks_api.dart` — THE strict fake, ported
  test-first: every server behavior in the inventory NOTES plus the full
  fault-injection surface (fail_next / per-id / per-page / commit_then_fail
  lost-response / on_call interleave / call counts). Enumerated tests 1:1,
  partitioned T3.2/T3.3 per §5. Never loosened.

`auth/` — Step 6 (desktop) + Step 9 (Android):

- flow.rs/pkce.rs/client.rs → REPLACED by googleapis_auth. Ports: OAuthConfig
  values; parse_redirect's UserDenied/StateMismatch contract as tests on our
  wrapper; refresh classification (invalid_grant/invalid_client/
  unauthorized_client → Denied, else Transient). ADDED per review: wrapper
  tests with a scripted http.Client pinning that the exchange SENDS
  client_secret (Desktop-app clients require it even under PKCE) and that a
  missing refresh_token in the response is a sign-in FAILURE — if
  googleapis_auth diverges on either, a test catches it, not the user.
- store.rs → `auth/token_store.dart`: StoredTokens + TokenStore +
  FileTokenStore (0600 tokens.json, Q4); keyring impl dies. 3 file tests.
- token_provider.rs + play_services_auth.rs + state.rs auth methods →
  `auth/token_provider.dart` (+Fake), `auth/desktop_token_provider.dart`,
  `auth/google_sign_in_token_provider.dart` (Step 9),
  `auth/auth_controller.dart` — THREE states; silent restore (fresh install
  ≠ expired; GMS outage quiet); gesture clears needsReauth; logout → offline.
  The 5 token-provider tests + the 5 state.rs auth tests port here. NEW
  tests: (#174) every auth transition emits on the auth stream and the
  affordance follows; (#175) a successful silent restore triggers startup
  auto-sync with NO user gesture, and a hung restore NEVER delays first
  frame.

`sync/` — Step 5:

- sync/error.rs → `sync/sync_error.dart`.
- sync/reconcile.rs → `sync/reconcile.dart` — pure decision core, ports
  FIRST: all 14 public decision enums + 30 functions by name, RFC-009 §-map
  in doc comments. Its enumerated tests are the spec.
- sync/engine.rs → `sync/engine.dart` (split files as size demands). The
  8-phase run() structure ports intact; engine stays policy-free.
  **Kill-safety, corrected per review**: the reference guarantees atomic
  individual store mutations + durable markers + convergent retry — NOT
  one-transaction-per-phase-step. The Dart port (a) wraps the known
  multi-store-write windows in ONE drift transaction each — the
  conflicted-copy pair (apply_pushed_task + upsert_task of the copy; the
  reference has a real kill window here that loses the local edit, P3), the
  move-landing pair (refresh_task_meta + clear_move), the cross-list
  clone+tombstone — writes only, NEVER an API call inside a DB transaction;
  (b) adds kill-here-and-resume tests at every phase boundary and at each
  enumerated multi-write window. Enumerated engine tests (~147) port 1:1 in
  the groups listed per task in §5.
- state.rs sync half → `sync/scheduler.dart`: debounce 2s / period 60s /
  backoff ×2^streak cap 1h, fake_async-testable trigger loop, single-flight
  guard, SyncStatus + sanitized text + raw-dedup privacy (#131 test),
  attention gating. Gates on an ABSTRACT AuthState seam (defined here with a
  fake; the real AuthController arrives in Step 6). The 26 state.rs tests
  are partitioned explicitly: scheduler/backoff/sanitization/logging/trigger
  (18) → T5.9; auth restore/sign-in (5) → T6.1; FileTokenStore (3) → T6.1;
  #170/#171/db_path_in (4) → T2.1; latest_backup (2) → T7.7. (Counts:
  inventory listing is authoritative.)
- flush-on-exit → desktop close hook (window_manager), 10s cap, 5 tests.
  Android has no exit hook by design — kill-safety covers it.

`app/` — Steps 2/5/7:

- commands.rs 29 commands → `app/commands.dart` (+`app/undo.dart`). Behavior
  per inventory: completion cascade + reopenIds undo; delete/undo (tombstone
  vs hard via server_may_hold, revive vs recreate, dead-parent fallback);
  set_due #164 cascade as ONE undo unit; move two-level refusals;
  move_to_list subtree clone (P8); reorder sibling swap + "!"-positions;
  clear_completed sparing sheltering parents; fresh_sync; backup; settings
  persist-first; set_editing held-create. The 125 commands_test cases port
  1:1 — every group is NAMED in a §5 task (T2.3/T2.4/T5.1/T5.2/T7.x); the
  sums must cover the full inventory list.
- lib.rs startup → `main.dart` + `app/bootstrap.dart`, ordered: logging →
  instance/dev-mode → flock (desktop) → paths → config/prefs load → DB open
  (WipeAborted → startup-error SCREEN) → **ensure default list ("My Tasks" —
  the title reconcile's rehome_target depends on; 2 tests)** → providers →
  FIRST FRAME → then ONE detached task: silent auth restore → auto-sync
  decision → scheduler start. First frame NEVER waits on restore or any
  network/plugin call (#175 and the geometry-freeze lesson, structurally).

---

## 3. Property suite + equivalence oracle — Steps 4–5

- sync_property_test.rs → `test/sync/property_suite.dart`: full Op
  vocabulary (11 local task ops, 3 list ops, 8 remote/phantom ops, panel
  hold, Sync/FlakySync/InterleaveSync/CrashSync/AbortSync, Restart) via a
  hand-rolled seeded generator. Six invariants as named properties; dual-
  device layer (two app instances, ONE shared fake server, offline
  interleaving, n:1 fixpoint). Determinism: fixed seed, tasks addressed by
  unique title, env-knob case count, MAX_HEAL_RUNS=16. Ops drive the REAL
  command layer — which is why commands port in Step 5 BEFORE the suite.
- Oracle (Q2), corrected per review:
  - The Rust bin drives the COMMAND layer, not the bare engine — ops are
    command-semantic (SetDue cascade, MoveToList clone, held create,
    Restart). This requires a small public oracle-support surface in the
    reference crate (expose the `*_inner` fns + simulate_restart or a pub
    module wrapping them). Re-implementing command logic inside the bin is
    FORBIDDEN (it would be a second spec). Larger than the RFC's ~150-line
    sketch; still additive and test-only under Q2.
  - Dual-device sequences: the bin hosts TWO app instances over one shared
    InMemoryClient; the JSON protocol carries a `side` field.
  - Dump comparison is CANONICAL, not byte-wise: title-keyed tree, parent
    expressed by parent-title, typed content + status + sync markers;
    ids/etags/positions EXCLUDED (they are call-order-dependent and can
    never match across independently-running engines — mirrors the Rust
    suite's Row comparator). Call-count divergence is expected and is not
    part of the equivalence claim.
  - In T4.2/T5.11 the oracle-comparison tests FAIL (not skip) when the
    binary is absent, and the DoD requires a NON-ZERO count of compared
    sequences. The skip-when-absent mode exists only for unrelated tasks'
    gate runs.
  - Corpus: failing sequences persist as JSON-lines files replayable from
    either side. Oracle + corpus + support surface deleted at cutover.

---

## 4. UI mapping (behavior contracts → fresh widgets) — Steps 2/7/8

Every [PORT] case in inventory-ui.md is a Flutter test to write; homes
below, visuals fresh (Q3).

- App.svelte decomposes: smart-view filters + **show-completed toggle +
  clear-completed flow (visibility rules, confirm, list-views-only)** →
  `app/views.dart` + view-options UI; selection/bulk → `app/selection.dart`;
  undo/toast queue (undo+error+info coexist) → `app/toasts.dart`; quick-add
  (NL preview via model parser, smart-view auto-date #8, **pin-to-top
  newestTaskId cleared on view switch, open-detail-follows-new-task**) →
  `app/quick_add.dart`; sync-status consumption → scheduler stream +
  per-widget `select`/`distinct` filtering with an EXPLICIT editing guard
  (drift invalidation is table-granular — a pull storm re-fires every open
  watch; widget tests: inline rename survives a concurrent store write;
  T10.1 adds a pull-storm rebuild-count check); back/dismiss PRECEDENCE
  ladder → `ui/back_dispatcher.dart` over PopScope; paste-create dies,
  bulk-split lives in BulkAdd.
- Sidebar/SortDropdown/drawer → `ui/sidebar/`: smart views + counts, list
  rows (local-only badge, excluded dimming, inline create/rename, drag
  order → prefs.json), footer priority (needsReauth > needsAttention >
  Sync-now), status line. Desktop window title follows the active view.
- TaskRow → `ui/task_row.dart`: checkbox-toggles-not-selects (48dp hit area,
  small glyph #167), inline rename (empty ⇒ delete), quick date actions —
  desktop reveal-WITHOUT-REFLOW (#168, geometry test) / touch swipe-left
  strip; swipe-right completes; long-press selects (motion cancels);
  metadata row (notes icon, URL badge/count/open, relative due + overdue/
  today styling + ↳ inherited, progress a/b, pending-sync dot, list tag);
  completion animation. **Touch action surface (RULED 2026-08-30, #245):
  every context-menu action — Duplicate, Make-subtask-of, Detach, dates,
  Move, Details, Open-in-Google, Delete — is reachable on coarse pointers
  WITHOUT a per-row overflow button: the row tap (Details), the date
  segment and swipe-left (dates), a long-press or the toolbar's "Select
  tasks" (Select), the DETAIL screen and the BULK bar (everything else).
  Desktop keeps the right-click menu (click-not-hover submenus).** No
  add-subtask affordance (#91).
- TaskDetail → `ui/task_detail.dart`: full inventory contract — auto-save-
  on-blur/close diff-only, live-tracking without clobbering typing,
  prev/next siblings, subtask checklist (add-with-kept-focus, per-subtask
  due, hide-completed persisted, un-complete-all #89, hidden-aware reorder
  steps + touch up/down), detach, list dropdown hidden for subtasks (#93) /
  move keeps panel on remapped id, links, empty-subtask discard EXCEPT with
  children, delete.
- Due-date surface (own task, per review): Material date-picker wrapper
  honoring the contract (opens on value's month, LOCAL dates never UTC,
  Today/Clear), due-badge and "no date" tap paths, #164 cascade toast whose
  Undo reverts the WHOLE cascade.
- SearchOverlay → `ui/search.dart`: title+notes live search, open-first
  ranking, subtask-through-parent (#92), local dates (#76), selection-reset
  on narrowing, no-full-reload select.
- Properties → `ui/properties.dart`: Sync (push toggle + enable
  confirmation, auto-sync, attention wording, stats, backup, fresh-sync
  confirm), Appearance (theme, default dark), Account (three states +
  scopes), About (version/instance/paths). Shortcuts tab dies.
- BulkAdd, MoveToListPicker, ParentPicker, confirm dialog, onboarding
  (first-launch intro survives Cheatsheet), ListView/TodayView (empty
  states, Focus Overdue section, reorder-step semantics), pull-to-refresh,
  FAB → sibling widgets per inventory.
- dateFormat/theme/errorBoundary → `ui/date_format.dart`, ThemeMode pref
  (default dark), startup-error screen + ErrorWidget.

---

## 5. Fleet task breakdown (queue order for `.ktask/tasks.md`)

Rules: every task ends gate-green, committed and pushed to `origin/flutter`;
ported tests red-checked; ux-review/android-review on rendering diffs; every
task's DoD names its inventory test groups — the union of all DoDs equals
the [PORT] inventory. "(op)" = operator, never queued.

Step 0 — harness:
- T0.0 (op) provision Linux toolchain (sudo dnf clang cmake), prove
  `flutter build linux` and an xvfb-run integration_test run on this box.
- T0.1 deps + conventions: riverpod, drift(+dev), alchemist, kiri_check
  (facade), mocktail, clock/fake_async, custom_lint+riverpod_lint,
  go_router, window_manager; strict analysis green; retry-disabled shared
  test container; flutter_test_config fonts.
- T0.2 gate + skeleton: coverage plumbing, DateTime.now/Timer grep bans,
  `dart run custom_lint` stage, one red-checked example per layer
  (unit/store/widget/golden/integration), integration smoke wired into the
  gate (after T0.0), and a committed testing-conventions doc incl. the
  golden-regeneration rule (goldens regenerate ONLY in dedicated
  toolchain-bump commits, never inline in a feature task).

Step 1 — model + store:
- T1.1 model/: types + dates + task_tree + effective_due + quick-add NL
  parser (inventory tests of model.rs/dates.rs + taskTree.test.js +
  SubtaskDatePropagation + QuickAdd parse cases).
- T1.2 store/: schema.drift + database.dart (fingerprint/WipeAborted/
  pre-wipe dump tests) + backup.dart (export.rs tests).
- T1.3 store/: CRUD + read queries + watch streams (repo tests: upserts,
  ordering, round-trips, list/task reads, web_view_link, sync_state).
- T1.4a store/: drains + mark_task_clean/apply_pushed_task race guards +
  base-snapshot CASE capture/clear (repo tests for those paths).
- T1.4b store/: finish_create + inflight markers + remap_list_id +
  tombstone_subtree + rehome + server_may_hold + counts + clear_* (the
  remaining repo tests). DoD additionally: measure Step-1 coverage and
  commit the ratchet floor into verify.sh (Q5).

Step 2 — walking skeleton:
- T2.1 bootstrap: config.json/prefs.json services (#170 path threading,
  #171 persist-first ×2, db_path_in tests), dev-mode isolation, instance
  flock (2 tests), logging, startup-error screen (2 tests), DEFAULT LIST
  creation (2 tests), providers root, windowing (GTK-runner min/default
  size, size-only persistence to prefs.json, NO restore work before first
  frame, header-bar decision recorded).
- T2.2 shell: adaptive 600dp ListDetailScaffold + go_router/ShellRoute +
  back_dispatcher skeleton + desktop window title + theme wiring.
- T2.3 first vertical slice: All-Tasks view on real store, basic task_row
  (tap/checkbox/inline-rename), quick-add with NL preview + pin-to-top +
  detail-follow (commands: create/rename/toggle + their commands_test
  groups; NewTaskPrepend/NewTaskDetailFollow/QuickAdd cases).
- T2.4 delete/undo command + DeleteToken (the 9 delete/undo commands_test
  cases) + detail panel SKELETON (fields, auto-save-diff, subtask
  add/toggle, two-level guards; TwoLevelTree cases).
- T2.5 goldens at phone+desktop sizes + integration smoke (launch, DB,
  render, CRUD, clean exit) in the gate + RELEASE-build cold-start measured
  and recorded against the 2s budget (early, per research — not deferred).

Step 3 — API:
- T3.1 tasks_api + api_error + http_tasks_api with the enumerated http.rs
  wire tests (scripted fake http.Client).
- T3.2 fake part 1 — CRUD semantics: lists+tasks insert/get/patch/delete,
  validation (due format, char limits), soft-delete tombstones + 200-echo +
  never-412, delete/complete cascades, etag counter + 412; fault-seam
  INTERFACES in place as no-ops. Named inventory tests for these areas.
- T3.3 fake part 2 — positioning/move/pagination + full fault injection
  (fail_next/per-id/per-page/commit_then_fail/on_call/call counts) + the
  remaining named tests. DoD: the FULL in_memory.rs inventory list is
  covered across T3.2+T3.3.

Step 4 — oracle:
- T4.1 (op) oracle support in the Rust repo per §3: pub oracle-support
  surface + `axiotask-oracle` bin (command-level ops, two-instance dual
  mode, canonical dump). Replays a reference sequence before hand-off.
- T4.2 Dart driver + seeded generator + corpus format; oracle-REQUIRED test
  mode (fails without binary; DoD: >0 sequences compared green). Queued
  only after operator confirms T4.1 shipped.

Step 5 — command layer, then sync:
- T5.1 commands: set_due + #164 cascade + one-unit undo + clear_completed
  (their commands_test groups: due dates/cascade ×12, clear_completed).
- T5.2 commands: move/reorder + move_to_list subtree clone + set_editing
  held-create + fresh_sync (groups: move/reorder ×9, move-to-list ×12,
  held-create ×3, §J crash-row cases that are command-level).
- T5.3 reconcile I — push-side decisions: §B/§C/§D/§G + push/create/delete/
  update failure classification (their enumerated tests).
- T5.4 reconcile II — moves/lists/pull decisions: §E/§F/§I/§A, D1/D6/D7,
  rehome_target, pull_batch/plan_pull_row/third_level_ids (remaining
  enumerated reconcile tests).
- T5.5 engine I — create pass + inflight recovery + §G create races
  (inventory groups: Push creates, §G, crash-adoption).
- T5.6 engine II — update/delete + 412 conflict path + §B/§C/§D matrices +
  real-API-semantics group; conflicted-copy store-write pair in ONE
  transaction + kill-window tests.
- T5.7 engine III — move drain + list sync (groups: Move, §E/§F, List sync,
  §I) + move-landing transaction pair.
- T5.8 engine IV — pull + ghosts + rehome/revive + D7 flatten (groups:
  Pull, Ghost, D7, §A, mid-run interleave) + phase-boundary kill tests.
- T5.9 scheduler: the 18 scheduler-family state.rs tests, AuthState seam +
  fake, SyncStatus privacy test (#131), sanitized messages, notifier
  stream, desktop flush-on-exit (5 tests).
- T5.10 property suite: generator + the six single-device invariants +
  Restart ops, seeded/deterministic, env-knob depth.
- T5.11 dual-device layer + oracle corpus replay (oracle-required mode;
  DoD: full ported corpus + >0 generated dual sequences compared green).

Step 6 — desktop auth:
- T6.1 token_store (3 tests) + desktop provider over googleapis_auth
  (client_secret-at-exchange + missing-refresh-token-fails wrapper tests;
  parse_redirect contract tests) + auth_controller (5 state.rs auth tests,
  three states, #174 auth-stream test, #175 restore→auto-sync +
  never-blocks-first-frame tests).
- T6.2 auth/status widget cluster as STANDALONE widgets (footer priority
  states, Account-tab states, sign-in/out flows) + goldens. Integration
  into the real sidebar is T7.1's DoD.

Step 7 — desktop UX parity (fresh design):
- T7.1 sidebar + smart views + counts/exclusion + list management + sort
  modes + show-completed toggle + auth footer integrated (suites: Sidebar,
  SmartViews, SmartViewCounts, TodayView, ListExclusion, ListManagement,
  ListReorder, Sort, SortDropdown, ListView, WindowTitle contract).
- T7.2 task row complete: metadata row, URL detection/badges, pending dot,
  progress, completion animation, desktop quick-date reveal-without-reflow
  geometry test (suites: TaskWidget [non-touch], Reschedule, UrlDetection,
  OpenInGoogle row half, FlatList).
- T7.3 due-date surface: picker wrapper contract, due-badge/"no date" tap,
  #164 cascade toast + whole-cascade undo (suites: DatePicker,
  DueConsistency, TaskWidget picker cases).
- T7.4 task detail complete: everything beyond T2.4's skeleton (suites:
  TaskDetail, DetailWorkflow, SubtaskReorder, remaining TwoLevelTree).
- T7.5 search + open-in-google (suites: SearchOverlay, OpenInGoogle).
- T7.6 selection + bulk bar + BulkAdd + duplicate + demote/move pickers +
  the row ACTION SURFACE per §4 (desktop context menu; touch reaches every
  action through the detail screen and the bulk bar, #245) (suites:
  BulkOps, BulkAdd, DemoteToSubtask,
  MoveToList, MoveToListPicker, ContextMenu [PORT cases], PasteCreate's
  bulk-split case, DragAndDrop semantics).
- T7.7 properties + backup export/import (+2 latest_backup tests) +
  fresh-sync confirm + theme + onboarding + ClearCompleted confirm flow
  (suites: Properties, Export, Import, Cheatsheet onboarding case,
  ClearCompleted, theme, UiStatePersistence [PORT half]).
- T7.8 toasts/undo stack + redaction surface + command WATCHDOG (budgets +
  hung-command test) + attention indicator + needs-reauth banner (suites:
  ErrorToast, ToastStack, ToastZIndex contract, AttentionIndicator,
  AuthRecovery, BackgroundSync, Sync, AutoSync, OfflineFirst,
  IncrementalRefresh, AppBoundary/StartupError contracts).
- T7.9 packaging: RPM build script, gate-checked by a dry-run build.
  Then (op): build, install, user starts daily-driving.

Step 8 — mobile UX:
- T8.1 swipe actions (right-complete, left-strip follows finger), long-
  press select (motion cancels), 48dp audit, gesture-vs-scroll slop
  (TaskWidget touch sub-suite, CheckboxTapTarget contract).
- T8.2 drawer + FAB + pull-to-refresh + safe areas (#166 contract) + IME +
  full-screen detail (suites: MobileDrawer, TouchInteractions, SafeArea
  contracts).
- T8.3 back precedence ladder + phone goldens + text-scale 1.3/2.0 pass
  (AndroidBackButton contract cases).

Step 9 — Android auth:
- T9.1 google_sign_in_token_provider (silent-first; gesture authorize; no
  serverClientId until Google refuses; Play-Services-absent → local-only,
  no crash/loop).
- T9.2 (op+user) PHYSICAL-PHONE gate: sign-in, tasklists round-trip,
  process-kill + session restore, swipe UX, preference persistence.

Step 10 — cutover:
- (op) deep property/oracle soak runs as an operator-scheduled background
  job (env-knob depth) — NEVER inline in a worker gate (RFC-011 rule).
- T10.1 cutover audit: verify recorded soak results, coverage ratchet,
  golden coverage at both form factors + themes + text scales, pull-storm
  rebuild-count check, cold-start re-measure. Single-session task.
- T10.2 (op+user) parity checklist sign-off (§6) → delete tool/oracle/ +
  the Rust-side oracle support → `flutter` replaces `main` per RFC-011.

~38 queued tasks + 4 operator steps. The union of task DoDs covers every
[PORT] inventory item; any inventory line not named in a DoD is a plan bug.

---

## 6. Parity checklist (cutover gate, per VISION + ux_decisions)

Data & sync: all RFC-009 semantics oracle-proven; offline-first CRUD;
local-only lists never push; backup export/import; fresh sync; wipe safety
net; instance isolation; prefs survive schema wipes; no data loss across
kill/restart on either platform.

Views & tasks: five smart views + list views, top-level-only rows, counts =
visible cards, effective-date inheritance incl. Focus Overdue section; quick
add with NL dates + smart-view auto-date + pin-to-top; search incl.
subtask-through-parent; sort modes persisted per view; manual reorder both
pointers; show-completed + clear-completed rules; undo for complete/delete/
date-cascade/bulk; #164 cascade with whole-cascade undo.

Subtasks: panel-only, one level enforced at every door, progress on parent,
detach/demote flows, hide-completed, un-complete-all, add-with-kept-focus,
empty-subtask discard except with children.

Auth & sync UX: three auth states with affordance priority; silent restore
that survives restart WITHOUT a tap (#175) and updates the UI (#174); quiet
sync (failures never hide data, new-error-only toasts, conflicts explained,
raw errors never surfaced); needs-attention indicator; command watchdog.

Mobile: swipe quick actions, long-press select, pull-to-refresh, FAB,
drawer, safe areas, IME, back precedence, 48dp targets, text-scale 1.3;
every context-menu action reachable via the detail screen and the bulk bar.

Quality bars: analyze/custom_lint clean; coverage at ratchet; goldens green
(both form factors, both themes); property suite + dual-device + oracle
corpus green with >0 compared sequences; operator deep soak recorded;
integration smoke green; APK builds; 2s cold start (measured since T2.5);
user's daily-driver sign-off on desktop AND phone.
