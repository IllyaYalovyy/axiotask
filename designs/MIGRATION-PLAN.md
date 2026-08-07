# Migration Plan — Tauri/Rust → Flutter/Dart

The detailed, file-by-file / function-by-function / test-by-test plan required
by RFC-011 (Accepted 2026-08-06) and issue #173. This document is the map and
the work order; the complete per-file inventories (every public function,
every test name with the behavior it protects) are committed alongside it:

- `designs/migration/inventory-core.md` — axiotask-core: 25 files, 251 public
  functions, 419 tests
- `designs/migration/inventory-app.md` — app layer: 29 commands, 177 tests,
  property-suite op vocabulary, e2e assertions, startup wiring
- `designs/migration/inventory-ui.md` — 18 components' behavior contracts,
  8 JS modules, 69 test suites / 557 cases each marked [PORT] or [DIES]

`<reference-repo>` in the inventories = the Tauri repo (branch `main`),
checked out beside this one. Ruling context: fresh UI design (Q3) — UI maps
at BEHAVIOR-CONTRACT level, never visual; capability and efficiency carry,
pixels do not.

---

## 1. Global mapping rules

Language and shape:

- Rust `struct`/`enum` → Dart class / sealed class; `Option<T>` → `T?`;
  `Result<T, E>` → throw typed exceptions (sealed error unions per module,
  mirroring error.rs / api/error.rs / store/error.rs / sync/error.rs) — the
  is_transient / is_auth_expired classification methods carry verbatim.
- Traits → abstract classes: `GoogleTasksClient`→`TasksApi`,
  `TokenStore`→`TokenStore`, `MobileTokenProvider`+RefreshFn→`TokenProvider`
  (RFC-011 two-method seam), `SyncNotifier`→callback/stream.
- Every in-file `#[cfg(test)]` module → a mirror file under `test/` (same
  relative path, `_test.dart`). Test NAMES and the behavior each protects
  port 1:1 from the inventories; every ported test is red-checked.
- Timestamps: `now_utc_string` semantics via an injected `clock`;
  `DateTime.now()`/raw `Timer` banned below `app/` (gate grep — this IS the
  port of tests/timestamp_audit.rs).
- All SQL ports near-verbatim from `schema.sql` into `.drift` files; sqlx
  runtime queries become drift SQL-first named queries.

The big structural simplification — no IPC boundary:

- The 29 Tauri commands (commands.rs) become plain methods on app-layer
  services called directly by widgets through Riverpod. The `*_inner` twins
  disappear (the methods ARE the testable layer).
- The read-side DTOs (TaskView, TaskListView, SyncStatusView, AppSettings…)
  DIE: widgets watch store streams and domain types directly. The DTOs that
  survive are real domain values: DeleteToken, DueUndoEntry/SetDueResult,
  ExportResult/ImportResult, RestoreSummary, SyncStatus.
- ipc.js dies as mechanism; two of its contracts carry: long-operation
  budgets (sync/backup/auth get long or no timeouts) and the error-redaction
  allowlist (`user_error`/`friendlyError` merge into ONE Dart
  `userMessageFor(command-family, error)` — #128/#135 tests port against it).

Dies globally, by decision (no trace in the new tree):

- The keyboard layer: RFC-007/008 behavior, shortcuts.js, Cheatsheet (its
  first-launch ONBOARDING moment survives as a Flutter intro), KeyboardNav
  suite, every [DIES]-marked key-triggered case. Rule from shortcuts.js: every
  ACTION it names must have a pointer/touch affordance — that's the checklist
  for what replaces it, and the ux-review skill enforces it.
- Tauri: IPC, plugin system, tauri-plugin-google-auth (google_sign_in v7
  replaces it), `Ok(())`-null lore, deep-link remnants, init-script prefix
  injection, WebviewWindow wiring, tests/android_build_scaffolding.rs
  (replaced by the gate's `flutter build apk`), tauri-driver e2e harness
  (replaced by integration_test), mobile-smoke.sh (adb flow re-derived for
  Flutter later if ever needed).
- Web/webview workarounds: custom DatePicker.svelte (Material date picker +
  the LOCAL-date/Clear/Today contract), HTML5 drag mechanics (Flutter
  reorderables; step-count semantics carry), localStorage + storage.js (UI
  prefs move into a `ui_prefs` table in the app DB — instance isolation then
  falls out of the data dir), window-geometry lore (size-only restore via
  window_manager, never blocking first frame), Svelte error boundary
  (Flutter ErrorWidget/zone handler + startup-error screen contract),
  Icon.svelte (Material icons; "no emoji glyphs" rule stays), theme.css.
- tests/version_consistency.rs (pubspec is the single version source).

---

## 2. Core mapping (file → file)

`model/` — Step 1:

- model.rs → `lib/src/model/task.dart` (+`task_list.dart`, `base_snapshot.dart`,
  `page.dart`). All 10 types 1:1; TaskStatus wire strings; TaskPatch.isEmpty;
  serde-skip rules become toJson conventions of the API DTO layer. 4 tests.
- dates.rs → `lib/src/model/dates.dart`: normalize_due, nowUtcString (via
  clock), DateMove + applyDateMove with month-clamp. 18 tests — the
  clamping/normalization suite ports verbatim (leap years, Feb 30 rejection,
  prefix parsing, no-panic on multibyte).
- taskTree.js → `lib/src/model/task_tree.dart` (isSubtask, hasSubtasks,
  canAddSubtask, canNestUnder) + effective-date propagation out of App.svelte
  (min of own due and unfinished-subtask dates, recursive, completed cuts
  subtree) → `lib/src/model/effective_due.dart`. 10 + 8 tests
  (taskTree.test.js, SubtaskDatePropagation) become pure unit tests.
- error.rs → `lib/src/model/errors.dart` sealed root (grows per module).

`store/` — Step 1:

- schema.sql → `lib/src/store/schema.drift` — 5 tables + 3 indexes verbatim
  (tasks with base_* columns, pending_moves, inflight_creates, sync_log) plus
  a new `ui_prefs(key,value)` table (replaces localStorage).
- store/mod.rs → `lib/src/store/database.dart`: open/openMemory, WAL+FK
  pragmas, schema-FINGERPRINT wipe-and-recreate (user_version = SHA-256
  prefix of schema text; fail-open WipeAborted when backup can't be written
  and unsynced data exists; durable timestamped pre-wipe JSON dump; wipe
  drops views/triggers too). 11 tests port 1:1 — this logic is the pre-1.0
  data-safety net and must not be "simplified".
- store/repo.rs → `lib/src/store/store.dart` (+ `store_sync.dart` for the
  sync-metadata half). All 38 public methods port by name; the CASE logic of
  upsert_task (base capture/clear), the local_updated race guards
  (mark_task_clean / apply_pushed_task / finish_create), tombstone_subtree,
  remap transactions with deferred FKs, rehome_unpushed_tasks, and
  server_may_hold are the heart — 54 tests port 1:1. Plus `watch*` stream
  variants of the read queries (new — drift's reason for being).
- export.rs → `lib/src/store/backup.dart`: Backup/BackupList/BackupTask,
  build/toJson/fromJson/intoStored, version guard, unknown-enum degradation.
  12 tests 1:1.
- config.rs → `lib/src/app/config.dart`: SyncConfig (push OFF default,
  auto-sync ON), instance prefix (AXIOTASK_PREFIX sanitize + PANIC-on-invalid
  — the isolation guard), config file (TOML dies → JSON or the ui_prefs
  table; comment-preserving save dies with it; #171 transactional-persist
  contract stays). GoogleConfig carries desktop client id/secret. 17 tests
  port minus the TOML-comment ones.

`api/` — Step 3:

- api/traits.rs → `lib/src/api/tasks_api.dart` — the 10-method abstract class,
  exact If-Match parameter shape on patchTask.
- api/error.rs → `lib/src/api/api_error.dart` — 8-variant sealed class +
  isTransient. 1 test.
- api/http.rs → `lib/src/api/http_tasks_api.dart` over package:http — every
  wire rule from the inventory NOTES ports as a named test: pagination to
  completion, showCompleted+showHidden, maxResults=100, URL-encoding of
  ids/page tokens, If-Match on task PATCH only, NO If-Match on task DELETE
  (P4) or tasklist PATCH (D6), move's `Content-Length: 0` (411 otherwise!),
  401→refresh-once via TokenProvider (Denied→AuthExpired, no replay), 403
  body-split (quota→RateLimited vs permission→permanent), Retry-After +
  100ms→5s backoff, 409|412→PreconditionFailed. 27 tests port against a
  scripted fake http.Client (wiremock's role).
- api/in_memory.rs → `lib/src/api/fake_tasks_api.dart` — THE strict fake,
  ported test-first: every server behavior in its NOTES block (due
  normalization + bare-date 400, char-counted 1024/8192 limits, soft-delete
  tombstones with 200-echo-ignore + never-412, subtree cascades on
  delete/complete, position_after lexicographic ordering, 400-vs-404
  asymmetries, cycle refusal, pagination tokens) plus the whole
  fault-injection surface (fail_next / fail_next_for_id / fail per page /
  commit_then_fail lost-response / on_call interleave hook / call counts) —
  the property suite and oracle depend on all of it. 37 tests 1:1. Never
  loosened; divergence-from-live only by documented decision.

`auth/` — Step 6 (desktop) + Step 9 (Android):

- auth/pkce.rs, auth/flow.rs, auth/client.rs → REPLACED by googleapis_auth
  (source-verified PKCE S256 + loopback). What ports: OAuthConfig values,
  parse_redirect's UserDenied/StateMismatch contract AS TESTS against our
  thin wrapper, refresh classification (invalid_grant/invalid_client/
  unauthorized_client → Denied, else Transient — parse_refresh_response's 5
  tests), refresh-on-401-once semantics (lives in HttpTasksApi tests).
- auth/store.rs → `lib/src/auth/token_store.dart`: StoredTokens + TokenStore;
  FileTokenStore (0600 tokens.json, Q4) is the ONE impl; keyring impl dies.
- auth/token_provider.rs + play_services_auth.rs + state.rs auth methods →
  `lib/src/auth/token_provider.dart` (seam + FakeTokenProvider),
  `auth/desktop_token_provider.dart` (googleapis_auth + TokenStore),
  `auth/google_sign_in_token_provider.dart` (Step 9; authorizationForScopes
  silent / authorizeScopes on gesture; serverClientId only if Google refuses
  without it), `lib/src/auth/auth_controller.dart` — THREE states (signedOut /
  signedIn / needsReauth), silent startup restore (fresh install ≠ expired;
  GMS outage = quiet transient), sign-in gesture clears needsReauth, logout
  swaps to offline. The 5 token-provider tests + 5 state.rs auth tests port
  1:1 — plus the #174 lesson as a NEW test: every auth transition emits on
  the auth state stream and the UI affordance follows it.

`sync/` — Step 5:

- sync/error.rs → `lib/src/sync/sync_error.dart` (2 tests).
- sync/reconcile.rs → `lib/src/sync/reconcile.dart` — pure decision core,
  ports FIRST: all 15 decision enums + 30 functions by name, RFC-009 §-map
  preserved in doc comments. Its 70 tests port 1:1 and are the spec.
- sync/engine.rs → `lib/src/sync/engine.dart` (+`engine_push.dart`,
  `engine_pull.dart` if size demands). The 8-phase run() structure ports
  intact (inflight recovery → list creates → task creates dependency-ordered
  → updates/deletes → move drain → list mutations → pull+ghosts → D7 flatten
  over ALL lists ALWAYS). Engine stays policy-free (decisions in reconcile);
  kill-safety: every phase step already one store transaction — the Dart
  port adds the RFC-011 "kill here and resume" tests per phase. All ~200
  engine tests port 1:1, organized by the inventory's groups (push, §B–§J
  matrices, pull, ghosts, D7, lists, interleave).
- state.rs sync half → `lib/src/sync/scheduler.dart`: debounce 2s / period
  60s / backoff ×2^streak cap 1h (constants carry), trigger select loop via
  fake_async-testable clock, run serialization (single-flight guard),
  SyncStatus + sanitized user text (#128/#135) + raw-dedup logging (#131),
  attention/needsReauth gating, notifier stream. 23 state tests port.
- flush-on-exit → desktop window-close hook (window_manager) with the 10s
  cap and the 5 flush tests; Android equivalent = engine kill-safety (no
  exit hook exists there — by design).

`app/` (command layer) — Steps 2/7:

- commands.rs 29 commands → `lib/src/app/commands.dart` service (+
  `undo.dart` for DeleteToken/DueUndo). Port by name: create/rename/toggle
  (completion cascade + reopenIds for undo), delete/undo_delete (tombstone
  vs hard by server_may_hold; revive-in-place vs recreate; dead-parent
  fallback), set_due/undo_set_due (#164 cascade as ONE undo unit, garbage
  rejected), move_task (two-level refusals), move_to_list (subtree clone
  under fresh ids, P8), reorder (sibling swap + local "!"-position),
  clear_completed (spares parents sheltering open subtasks), fresh_sync,
  backup export/import, settings (persist-first #171), set_editing
  (held-create id), auth entries via AuthController. The 125 commands_test
  cases port 1:1 — they are the app-behavior spec.
- lib.rs startup sequence → `lib/main.dart` + `lib/src/app/bootstrap.dart`:
  ordered: logging → instance/dev-mode resolution → single-instance flock
  (desktop) → paths → AppState/DB open (WipeAborted → startup-error SCREEN,
  app does not silently die) → providers up → silent auth restore →
  auto-sync decision → scheduler start. 2 startup-error tests port as widget
  tests of the error screen.

---

## 3. Property suite + equivalence oracle — Steps 4–5

- sync_property_test.rs → `test/sync/property_suite.dart`: the full Op
  vocabulary (§A–§J: 11 local task ops, 3 list ops, 8 remote/phantom ops,
  panel hold, Sync/FlakySync/InterleaveSync/CrashSync/AbortSync, Restart)
  ports as a hand-rolled seeded generator (plain seeded Random — no PBT
  framework dependency, per research). The SIX invariants port as named
  properties: eventual push, convergence (field-for-field vs fake server,
  position excluded), idempotency (dump compare), deferral safety, crash
  safety (lost-response inserts never duplicate), parent integrity. Dual-
  device layer (two app instances, one fake server, offline interleaving,
  n:1 fixpoint oracle) ports too. Determinism: fixed seed, tasks addressed
  by unique title, AXIOTASK_PROPTEST_CASES-style env knob, MAX_HEAL_RUNS=16.
- kiri_check covers the small pure-function properties (dates, ordering,
  reconcile helpers) where generator ergonomics help.
- Oracle (Q2 approved): `axiotask-oracle` bin in the Rust workspace — reads
  JSON ops on stdin (the same vocabulary), applies them to SyncEngine +
  InMemoryClient, `{"cmd":"dump"}` → canonical state. Dart driver
  `tool/oracle/driver.dart` runs each generated sequence against BOTH
  engines and deep-compares dumps; failures persist as JSON-lines corpus
  files replayable from either side; skips cleanly when the binary is absent
  (env var points at it). Deleted at cutover.

---

## 4. UI mapping (behavior contracts → fresh widgets) — Steps 2/7/8

Every [PORT] case in inventory-ui.md is a Flutter test to write; the
component names below are homes, not designs (Q3: visuals are new).

- App.svelte (1848) decomposes — nothing inherits its god-object shape:
  view routing + smart-view filters → `app/views.dart` providers (Focus <7d
  incl. overdue section, Upcoming ≤14d, Missed oldest-first, Unscheduled
  excludes inherited-dated parents, per-list; ALL views top-level-only #82);
  selection/bulk-ops → `app/selection.dart` + a bulk action bar widget;
  undo/toast queue (stacking: undo+error+info coexist) → `app/toasts.dart` +
  toast overlay; quick-add NL parsing + smart-view auto-date (#8) →
  `app/quick_add.dart`; sync-status listening + scoped refresh (skip while
  editing) → falls out of watch streams + scheduler stream; back/dismiss
  PRECEDENCE ladder (onboarding > … > detail > selection) →
  `ui/back_dispatcher.dart` driving PopScope (AndroidBackButton tests port
  against it); paste-create dies as a global gesture, bulk-split lives in
  BulkAdd's entry.
- Sidebar + SortDropdown + drawer → `ui/sidebar/` (rail/drawer per form
  factor): smart views + per-view open-top-level counts, list rows with
  local-only badge / excluded dimming / inline create+rename / drag order
  (persisted), footer priority contract (needsReauth beats needsAttention
  beats Sync-now; never a sync button that can only fail), status line.
  ~40 Sidebar/counts/exclusion/reorder tests port.
- TaskRow → `ui/task_row.dart`: checkbox-toggles-not-selects (44dp hit area,
  small glyph #167), title + inline rename (empty ⇒ delete), quick date
  actions (reveal-without-reflow on desktop #168; swipe-left strip on touch),
  swipe-right completes, long-press selects (motion cancels), metadata row
  (notes icon, link badge + open, relative due with overdue/today styling +
  ↳ inherited, progress a/b, pending-sync dot, list tag), completion
  animation. ~45 TaskWidget/Reschedule/touch tests port; the CSS-source
  suites (CheckboxTapTarget, HoverActionsNoReflow, SafeAreaInsets,
  ToastZIndex, ThemeContrast) become golden/widget-geometry contract tests.
- TaskDetail → `ui/task_detail.dart` (pane ≥600dp, full-screen route below):
  auto-save-on-blur/close diff-only (#4), live-tracking without clobbering
  typing, prev/next siblings, subtask checklist (the ONLY subtask home:
  add-with-kept-focus, per-subtask due, hide-completed persisted,
  un-complete-all #89, reorder with hidden-row-aware steps + touch buttons),
  detach, list dropdown hidden for subtasks (#93) / move keeps panel on
  remapped id, links, empty-subtask auto-discard EXCEPT with children,
  delete. ~45 TaskDetail/DetailWorkflow/SubtaskReorder/TwoLevelTree tests.
- SearchOverlay → `ui/search.dart`: title+notes live search, open-before-
  completed ranking, subtask anchored through parent (#92), local-date
  rendering (#76), selection-reset-on-narrow, no-full-reload-on-select.
  ~20 tests.
- Properties → `ui/properties.dart`: Sync (push toggle w/ enable
  confirmation, auto-sync, status/stats/attention wording, backup buttons,
  fresh-sync confirm), Appearance (theme radio, default dark), Account
  (three states + scopes + explanation), About (version/instance/paths).
  Shortcuts tab dies. ~22 tests.
- ContextMenu actions → a per-row action surface (desktop right-click menu +
  a touch equivalent — the touch gap the inventory flags; ux-review owns
  it): full action list minus Add-subtask (#91). ~20 tests.
- BulkAdd, MoveToListPicker, ParentPicker, confirm dialog, onboarding,
  ListView/TodayView empty states + overdue section + reorder-step
  semantics, pull-to-refresh, FAB → sibling widgets, tests per inventory.
- dateFormat.js / theme.js / errorBoundary.js → `ui/date_format.dart`
  (3 tests), ThemeMode pref (3), startup-error screen + ErrorWidget (3).

---

## 5. Fleet task breakdown (queue order for `.ktask/tasks.md`)

Rules: every task ends gate-green, committed and pushed to `origin/flutter`;
tests ported with red-checks; ux-review/android-review run on rendering
diffs. "(op)" = operator (me), not queued — touches the frozen Rust repo or
needs judgment the queue can't carry.

Step 0 — harness:
- T0.1 deps + conventions: riverpod, drift(+dev/build_runner), alchemist,
  kiri_check(facade), mocktail, clock/fake_async, custom_lint+riverpod_lint,
  go_router, window_manager; strict analysis stays green; retry-disabled
  shared test container; flutter_test_config with fonts.
- T0.2 gate extensions + red-checked skeleton layers: coverage ratchet,
  DateTime.now/Timer grep bans, `dart run custom_lint`, one deliberately
  failing example per layer (unit/store/widget/golden/integration) proven
  red then green; xvfb-run integration smoke wiring (needs clang/cmake).

Step 1 — model + store:
- T1.1 model/: task/list/status/patch/page + dates + task_tree +
  effective_due (+ their ~40 tests).
- T1.2 store/: schema.drift + database.dart (fingerprint wipe, WipeAborted,
  pre-wipe dump) + backup.dart (+23 tests).
- T1.3 store/: Store CRUD + read queries + watch streams (+ ~20 repo tests).
- T1.4 store/: sync-metadata surface — drains, mark-clean guards, base
  snapshots, tombstones, inflight, remaps, rehome, counts (+ ~34 repo tests).

Step 2 — walking skeleton:
- T2.1 bootstrap + config + dev-mode isolation + instance lock + providers +
  adaptive shell (600dp) + go_router + back_dispatcher skeleton.
- T2.2 All-Tasks view on real store: task_row (tap/checkbox/inline-rename) +
  quick-add (NL dates + preview) + commands create/rename/toggle/delete+undo.
- T2.3 detail panel skeleton: fields, auto-save-diff, subtask checklist
  add/toggle, two-level guards.
- T2.4 first goldens (phone+desktop sizes) + integration smoke (launch, DB,
  render, CRUD round-trip, clean exit) in the gate.

Step 3 — API:
- T3.1 tasks_api + api_error + http_tasks_api with all 27 wire-contract
  tests (fake http.Client).
- T3.2 fake_tasks_api part 1: server semantics (validation, soft-delete,
  cascades, positioning, asymmetries) + its behavior tests.
- T3.3 fake_tasks_api part 2: pagination, fault injection, interleave hook,
  call counts + remaining tests.

Step 4 — oracle:
- T4.1 (op) `axiotask-oracle` bin in the Rust workspace (Q2): stdin JSON ops
  → engine+InMemoryClient, dump command; replays a reference sequence.
- T4.2 Dart driver + seeded op generator + corpus format + env-gated test
  hook (skips without binary).

Step 5 — sync:
- T5.1 reconcile.dart: push-side decisions (§B/§C/§D/§G + failures) + tests.
- T5.2 reconcile.dart: moves/lists/pull decisions (§E/§F/§I/§A, D6/D7) + tests.
- T5.3 engine: create pass + inflight recovery + update/delete + 412 conflict
  path (+ their test groups, kill-safety per step).
- T5.4 engine: move drain + list mutations (+ tests).
- T5.5 engine: pull + ghosts + rehome/revive + D7 flatten (+ tests).
- T5.6 scheduler + SyncStatus + sanitization + notifier stream + flush-on-
  exit (desktop) (+23 tests).
- T5.7 property suite port (six invariants + dual-device) + oracle green on
  the ported corpus; soak knob documented.

Step 6 — desktop auth:
- T6.1 token_store + desktop_token_provider (googleapis_auth wrapper) +
  auth_controller (three states, silent restore, auth-change stream #174).
- T6.2 auth UI states (sidebar footer priority, Account tab, sign-in/out
  flows, re-auth path) + goldens.

Step 7 — desktop UX parity (fresh design throughout):
- T7.1 smart views + sidebar counts/exclusion/list mgmt + sort modes.
- T7.2 search overlay + open-in-google + link handling.
- T7.3 selection + bulk bar + bulk add + duplicate + context/action surface.
- T7.4 move/reparent/detach pickers + reorder (list + subtask, DnD + touch).
- T7.5 properties + backup export/import + fresh sync + theme + onboarding.
- T7.6 toasts/undo stack + error redaction surface + attention indicator +
  needs-reauth banner; desktop golden pass; user starts daily-driving RPM
  (op: build + install).

Step 8 — mobile UX:
- T8.1 swipe actions (right-complete, left-strip), long-press select, 48dp
  audit, row gestures vs scroll slop.
- T8.2 drawer + FAB + pull-to-refresh + safe areas + IME behavior +
  full-screen detail.
- T8.3 back precedence ladder on device semantics + phone goldens + text
  scale 1.3/2.0 pass.

Step 9 — Android auth (+ device gate):
- T9.1 google_sign_in_token_provider (silent-first, gesture authorize, no
  serverClientId until refused) + Play-Services-absent degradation.
- T9.2 (op+user) PHYSICAL-PHONE gate: sign-in, tasklists round-trip, kill +
  restore session, swipe UX, preference persistence.

Step 10 — cutover:
- T10.1 parity soak: full corpus + deep property soak green; coverage/goldens
  audit; performance pass (2s cold start on this box, list jank).
- T10.2 (op+user) parity checklist sign-off (below) → delete tool/oracle/ →
  `flutter` replaces `main` per RFC-011.

Estimated fleet volume: ~30 queued tasks, ~1,000 ported tests plus new
golden/gesture/kill-safety coverage.

---

## 6. Parity checklist (cutover gate, per VISION + ux_decisions)

Data & sync: all RFC-009 semantics oracle-proven; offline-first CRUD; local-
only lists never push; backup export/import; fresh sync; wipe safety net;
instance isolation; no data loss across kill/restart on either platform.

Views & tasks: five smart views + list views, top-level-only rows, counts =
visible cards, effective-date inheritance incl. Focus overdue section; quick
add with NL dates + smart-view auto-date; search incl. subtask-through-
parent; sort modes persisted per view; manual reorder both pointers;
show-completed + clear-completed rules; undo for complete/delete/date-
cascade/bulk; #164 date-consistency cascade.

Subtasks: panel-only, one level enforced at every door, progress on parent,
detach/demote flows, hide-completed, un-complete-all, add-with-kept-focus,
empty-subtask discard except with children.

Auth & sync UX: three auth states with correct affordance priority; silent
restore; sign-in from drawer/sidebar; quiet sync (failures never hide data,
new-error-only toasts, conflicts explained); needs-attention indicator.

Mobile: swipe quick actions, long-press select, pull-to-refresh, FAB,
drawer, safe areas, IME, back precedence, 48dp targets, text-scale 1.3.

Quality bars: analyze/custom_lint clean; coverage at ratchet; goldens green
at both form factors + dark/light; property soak + oracle corpus green;
integration smoke green; APK builds; 2s cold start; user's daily-driver
sign-off on desktop AND phone.
