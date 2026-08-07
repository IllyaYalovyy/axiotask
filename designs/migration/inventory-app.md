# Migration inventory — app layer (crates/axiotask-app)

Totals: 29 tauri commands; 177 tests (125 commands_test + 23 state.rs + 14 property + 2 lib.rs + 8 android_build_scaffolding + 2 timestamp_audit + 3 version_consistency).

## src/state.rs (2268)
PURPOSE: AppState — store + auth + sync engine + background scheduler + settings persistence.

### Constants (sync loop tuning)
- SYNC_DEBOUNCE = 2s (coalesce rapid mutations into one sync)
- SYNC_PERIOD = 60s (idle periodic pull cadence)
- EXIT_SYNC_TIMEOUT = 10s (cap on the exit flush)
- SYNC_MAX_BACKOFF = 1h (cap on permanent-failure exponential backoff)

### AppState fields worth knowing
- store (SQLite Store), client: Mutex<Arc<dyn GoogleTasksClient>> (swapped between InMemoryClient offline and HttpClient signed-in), token_store (FileTokenStore over tokens.json beside the DB), oauth_config, sync_notify (tokio Notify), sync_guard (Mutex serializing sync runs, RFC-004), push_enabled (AtomicBool), held_create_id (the ONE task whose CREATE push is held while the UI edits it), auto_sync_on_start, needs_reauth, attention_streak (permanent-failure backoff counter), config_path, db_path, sync_status (Mutex<SyncStatus>), sync_notifier (RwLock<Arc<dyn SyncNotifier>>), signed_in (android-only AtomicBool — Play Services owns the grant, no token material persisted).

### Public API on AppState (production)
- new(db_path, config_path) — open store, write default config, restore session from tokens.json, ensure default list
- set_sync_notifier(notifier) — install post-sync callback (Tauri emitter in prod)
- new_memory(client) — in-memory state for tests (push disabled)
- is_authenticated() — desktop: tokens.json exists; ANDROID VARIANT: in-memory signed_in flag
- needs_reauth() — stored session dead (refresh permanently denied)
- build_backup() — collect all lists+tasks into lossless Backup snapshot
- restore_backup(backup) — non-destructive merge; missing rows restored as fresh dirty CREATES (etag stripped); pre-syncs if authed
- start_login() — DESKTOP-ONLY: browser OAuth loopback flow, swap in HTTP client
- start_login_mobile(app) — ANDROID-ONLY: Play Services interactive sign-in, sets signed_in
- start_login_with_provider(provider) — platform-agnostic interactive MobileTokenProvider sign-in (testable w/ fake)
- restore_login_with_provider(provider) — silent startup restore; false + no banner on InteractionRequired/Unavailable
- restore_session_mobile(app) — ANDROID-ONLY: silent restore + flip signed_in
- sign_out_mobile(app) — ANDROID-ONLY: drop Play Services association then local logout
- logout() — clear tokens, swap to offline InMemoryClient, clear needs_reauth/signed_in
- schedule_sync() — notify_one the background loop (debounced trigger)
- run_sync_loop() — forever loop: wait trigger, skip if needs_reauth, run if authed
- next_sync_period() — base 60s, doubled per permanent-failure streak, capped 1h
- run_sync() — serialized full sync run; records SyncStatus, classifies errors (auth-expired / transient / permanent), notifies UI
- sync_status() — snapshot of SyncStatus
- set_editing_task(id) — record/clear the held-create id (inline editor / detail panel)
- flush_on_exit() — push pending changes before quit; releases held create; skips if signed-out/read-only/dead-session/nothing-dirty; 10s timeout
- run_sync_if_authed() — err "not authenticated" otherwise
- create_list(title, local_only) — local_only=Clean/never-synced; else pending create
- rename_list(id, title) — fold into pending create, else pending update
- delete_list(id) — hard-delete local task rows; tombstone list if etag, else hard-delete
- move_task_to_list(id, target) — Google has no cross-list move: recreate whole SUBTREE under fresh ids in target, tombstone/hard-delete originals (P8 anti-resurrection), returns new root id
- is_push_enabled(), auto_sync_on_start(), db_path(), config_path(), scopes() — display/read accessors
- pending_push_count() — dirty rows awaiting push
- set_push_enabled(b), set_auto_sync_on_start(b) — TRANSACTIONAL: persist config to disk FIRST, flip atomic only on success (#171)

Test-only: new_memory_with_push, token_store_for_test, force_needs_reauth_for_test, simulate_restart (rebuild over same store; drops held-create/needs_reauth/streak/stats).

### Notifier/event seams
- trait SyncNotifier { notify_sync(&SyncStatus) } — called after EVERY sync run (success or failure); prod = TauriSyncNotifier emitting `sync-updated` event; tests inject a recording spy; NoopSyncNotifier default.
- SyncStatus struct: last_synced, last_pulled/pushed/conflicts/deleted, changed_list_ids (incremental UI refresh), lists_changed, total_syncs, last_error (SANITIZED user text, #128/#135), last_raw_error (raw dedup key, never surfaced, #131), needs_attention (permanent failure, backoff engaged), needs_reauth.

### Sync loop / debounce / backoff logic
- wait_for_sync_trigger(notify, debounce, period): tokio::select! — on mutation notify, sleep 2s debounce; else fire at period.
- backoff_period(base, streak, cap): streak==0 → base; else base·2^streak capped (mutations still trigger promptly; only idle polling backs off).
- run_sync error classification: is_auth_expired → needs_reauth=true, background loop gated (manual Sync-now still allowed); is_transient → silent retry, no attention; else permanent → attention, streak++, ERROR-log only for a NEW raw detail (repeat drops to DEBUG).
- sync_user_message: Store/Internal/Network errors replaced with calm sentences; other API errors kept verbatim.

### Support items
- FileTokenStore — tokens.json load/save/clear (desktop persistence)
- RestoreSummary { lists, tasks }
- build_http_client — AuthedClient with reqwest refresh-token RefreshFn (invalid_grant → Denied)
- build_provider_client — AuthedClient whose 401-refresh silently asks MobileTokenProvider; throwaway in-memory token store
- db_path_in(base) — `base/<app-dir>/axiotask.sqlite` (instance-aware dir); default_db_path() = dirs::data_dir (desktop only)
- acquire_instance_lock(db_path) — flock on `instance.lock` per DATA DIRECTORY (#48); kernel-released; error names holder pid
- default_backup_path() / latest_backup_path() / latest_backup_in(dir) — timestamped `axiotask-backup-*.json` under `<app-dir>/backups/`

### state.rs in-module tests (23)
- mobile_sign_in_gesture_clears_needs_reauth — interactive provider sign-in clears re-auth banner
- cancelled_mobile_sign_in_errors_and_preserves_state — cancel fails, state untouched
- silent_restore_recovers_previously_granted_session — silent authorize(false), banner clears
- fresh_install_restore_stays_quietly_signed_out — no grant, no false "expired" banner
- restore_during_gms_outage_stays_offline_without_banner — Unavailable is transient, no loop
- db_path_in_roots_the_shared_db_layout_under_the_given_base — same subtree either base
- new_writes_and_persists_config_at_the_resolved_path — #170 config path threading
- set_push_enabled_does_not_flip_when_the_config_write_fails — #171 transactional
- set_auto_sync_does_not_flip_when_the_config_write_fails — #171 mirrored
- file_token_store_round_trips / clear_removes_file / creates_parent_dirs
- latest_backup_in_picks_newest_by_timestamped_name / returns_none_when_empty_or_missing
- permanent_store_failure_message_hides_sql_from_the_user / internal_sync_failure_message_is_calm / api_sync_failures_keep_their_human_text / network_sync_failure_hides_the_reqwest_url
- backoff_period_stays_at_base_while_healthy / doubles_per_failure_then_pins_to_cap
- permanent_failure_logs_at_error_only_when_new_or_changed / distinct_root_causes_relog_at_error_even_when_display_text_is_identical
- permanent_failure_logs_error_once_then_debug_across_run_sync (tracing-subscriber spy)
- trigger_fires_after_debounce_on_mutation / trigger_fires_after_period_when_idle / rapid_mutations_coalesce_into_one_trigger

## src/commands.rs (1506)
PURPOSE: The 29 Tauri IPC commands (the whole frontend↔backend API) + DTOs + error sanitization; maps 1:1 to a future Dart command layer.

DTOs: TaskListView {id,title,local_only}; TaskView {id,parent_id,title,notes,status,due,position,sync_state,web_view_link}; SubtreeEntry; DeleteToken {id,list_id,parent_id,title,notes,status,due,position,had_etag,subtree[]}; DueUndoEntry {id,due}; SetDueResult {undo[],cascaded,cascaded_parent}; SyncRunView {summary,changed_list_ids,lists_changed}; SyncStatusView (mirror of SyncStatus minus last_raw_error); AppSettings {version,instance,push_enabled,auto_sync_on_start,authenticated,needs_reauth,scopes,db_path,config_path,pending_pushes,sync}; ExportResult {path,lists,tasks,bytes}; ImportResult {path,lists,tasks}.

Every #[tauri::command] (params → purpose):
1. list_tasklists() → Vec<TaskListView> — all lists incl. local_only badge
2. create_list(title, local_only?) → TaskListView — new list; local_only never syncs
3. rename_list(id, title) — rename, fold into pending create or mark update
4. delete_list(id) — tombstone synced list / hard-delete local-only; removes task rows
5. list_tasks(list_id) → Vec<TaskView> — tasks of one list
6. create_task(list_id, parent_id?, title) → TaskView — dirty create; emits logcat marker (#161)
7. rename_task(id, title) — retitle, dirty, dirty_op preserves create
8. toggle_complete(id) — flip status; completing a parent CASCADES completion to open descendants (matching Google server behavior); un-complete never cascades
9. delete_task(id) → DeleteToken — snapshot subtree for undo; tombstone whole subtree if server_may_hold else hard delete (FK cascade)
10. undo_delete(token) — revive tombstone in place (dirty UPDATE preserving etag) if delete unpushed, else recreate as fresh create; dead parent falls back to top level; restores subtree
11. set_due(id, mv) → SetDueResult — mv is "raw:<date>" (normalized; garbage rejected) or Today/Tomorrow/NextWeek/NextMonth/Clear; enforces #164 invariant (child due never before parent due): editing a child earlier pulls PARENT down; editing a parent later pulls earlier CHILDREN up; returns one-unit undo list
12. undo_set_due(entries) — restore captured prior dates, bypasses cascade rule, best-effort
13. set_notes(id, notes) — "" clears; dirty edit
14. move_task(id, parent_id?, previous_id?) — reparent/reorder; refuses >1-level nesting and demoting a task that has subtasks; records move intent (record_move → move API, not patch)
15. move_to_list(id, target_list_id) → new root id — delegates to AppState::move_task_to_list (subtree clone + tombstone)
16. reorder_task(id, direction "up"/"down") — swap local positions with sibling, record_move for push; boundary = no-op
17. clear_completed(list_id) → u32 — delete completed tasks; SKIPS completed parents sheltering open subtasks; tombstone vs hard-delete per server_may_hold
18. sync_now() → SyncRunView — manual sync (requires auth)
19. fresh_sync() → String — clear_synced (local-only lists preserved) + full repull
20. auth_status() → bool — is_authenticated
21. auth_login(app) → bool — android: start_login_mobile(Play Services); desktop: start_login (browser); returns true not unit (#45)
22. auth_logout(app) — android: sign_out_mobile; desktop: logout
23. open_url(url) — open::that (system browser)
24. export_backup(path?) → ExportResult — lossless JSON backup to path or timestamped default
25. import_backup(path?) → ImportResult — restore from path or newest default backup; refuses newer-version backups
26. get_settings() → AppSettings — full Properties-dialog snapshot in one round trip
27. set_push_enabled(enabled) → AppSettings — toggle read-write sync, persisted
28. set_editing(editing_task_id?) — set/clear the held-create id
29. set_auto_sync(enabled) → AppSettings — toggle startup auto-sync, persisted

Internal helpers (behavior a port must keep):
- *_inner twins for create/rename/toggle/delete/undo_delete/set_due/undo_set_due/move/reorder/clear_completed — logic callable without Tauri runtime (tests use these)
- user_error(command, raw) — error sanitization (#128/#135): auth signals ("not authenticated", "session expired") pass verbatim (frontend keys on them); allowlisted user-authored validation messages pass; EVERYTHING else logged and replaced by "Couldn't <action> right now…" per command family (command_action groups)
- is_user_authored — 7 markers + version-guard + "task {id} not found" exact shape
- find_task — search all lists by id
- next_local_position() — monotonic "!"-prefixed placeholder so unsynced rows sort/reorder (#80)
- dirty_op(etag) — no etag stays "create" (flipping to update would 404-delete), else "update"
- due_date_before — lexical compare of leading 10 chars; equal dates NOT before

## src/commands_test.rs (5165) — 125 tests
PURPOSE: Example-based behavior suite over the real *_inner commands + real store + fake Google (InMemoryClient).

Lists (CRUD + local-only):
- list_tasklists_returns_seeded_lists — returns seeded lists
- rename_list_marks_update_for_synced_and_keeps_create_for_new
- rename_list_syncs_to_remote
- delete_list_tombstones_synced_list
- delete_list_hard_deletes_local_only_list
- create_list_synced_is_dirty_create
- create_list_local_only_is_clean_and_never_pushed
- create_list_local_only_excluded_from_ghost_detection
- auto_creates_default_list_on_first_launch
- does_not_create_default_list_when_lists_exist

Task CRUD basics:
- create_task_inserts_dirty_row — pending create written
- rename_task_updates_title_and_marks_dirty
- set_notes_updates_notes_field
- toggle_complete_flips_status
- crud_works_without_authentication — offline CRUD works
- dirty_op_preserves_create_for_unsynced
- offline_created_then_edited_task_pushes_as_create_not_deleted

Delete + undo:
- delete_task_with_etag_marks_deleted — tombstone
- delete_task_without_etag_hard_deletes
- undo_delete_restores_tombstoned_task — revive in place, delete never fires
- undo_delete_restores_hard_deleted_local_task
- undo_after_delete_pushed_restores_the_whole_subtree
- delete_parent_tombstones_the_whole_subtree_locally (#138)
- undo_recreate_with_dead_parent_falls_back_to_top_level
- undo_delete_after_unpushed_edit_keeps_the_edit_queued
- clear_completed_spares_open_subtasks_under_a_completed_parent

Due dates + #164 cascade:
- set_due_applies_date_move
- set_due_from_picker_normalizes_bare_date_and_pushes
- set_due_rejects_garbage_instead_of_poisoning_the_row
- parent_edit_pulls_earlier_children_up_only
- child_set_earlier_pulls_parent_down
- parent_without_date_is_inert
- child_set_later_than_parent_does_not_cascade
- equal_dates_do_not_cascade
- clearing_a_date_never_cascades
- date_move_path_also_cascades
- completed_subtask_is_included_in_cascade
- cascade_reverts_as_one_undo_unit

Completion cascade (RFC-009 §C):
- completing_a_parent_completes_open_descendants
- uncompleting_a_parent_does_not_reopen_descendants
- completing_a_parent_keeps_the_cascade_etag_coherent_and_converges
- uncompleting_a_subtask_under_a_completed_parent_converges_back
- completing_a_parent_takes_a_subtask_we_never_pulled

Move / reorder / nesting rules:
- move_task_changes_parent
- demoting_a_task_that_has_subtasks_is_refused (one-level invariant)
- nesting_a_task_under_a_subtask_is_refused
- reorder_swaps_positions
- reorder_moves_freshly_created_task (#80)
- reorder_moves_subtask_across_completed_sibling
- reorder_command_pushes_via_move_endpoint_end_to_end
- move_command_reparents_via_move_endpoint_end_to_end
- move_recorded_mid_sync_keeps_the_latest_intent

Move-to-list (§H):
- move_to_list_creates_in_target_and_tombstones_old
- move_to_list_local_only_task_hard_deletes_old
- move_to_list_syncs_without_data_loss
- move_to_list_takes_subtasks_along
- cross_list_move_lands_the_whole_subtree_under_fresh_ids
- cross_list_move_subtree_no_duplicate_when_root_delete_is_delayed (P8)
- a_remote_edit_during_a_cross_list_move_loses_to_the_moved_snapshot
- a_moved_task_survives_in_the_target_when_the_original_dies_remotely
- a_subtask_added_remotely_after_a_cross_list_move_dies_with_the_original
- a_move_into_a_list_deleted_remotely_rehomes_the_clone_to_the_default_list
- a_crash_between_the_clone_and_the_delete_leaves_no_permanent_duplicate
- a_clone_insert_that_commits_then_times_out_does_not_duplicate_the_move

Sync engine surface / status:
- sync_pulls_remote_tasks_into_store
- sync_pushes_local_creates_to_remote
- sync_status_reports_changed_task_lists_for_incremental_refresh
- sync_refuses_when_not_authenticated
- schedule_sync_is_noop_when_not_authenticated
- fresh_sync_clears_local_and_repulls
- test_state_defaults_to_read_only
- concurrent_syncs_do_not_double_push (sync_guard)
- sync_status_starts_empty_then_records_a_run
- pending_push_count_reflects_dirty_changes
- pull_populates_web_view_link_through_to_task_view
- sync_notifies_observer_on_success / _on_failure (SyncNotifier spy)

Auth / session states:
- expired_session_sets_needs_reauth_with_an_actionable_error
- permanent_sync_failure_flags_attention_backs_off_and_logs_the_real_error
- transient_sync_failure_does_not_flag_attention_or_back_off
- logout_works_inside_the_async_runtime (block_on panic regression)
- auth_exposes_three_distinct_states_not_two (signed-out / signed-in / needs-reauth)
- token_store_clear_removes_auth

Held create (editing hold, #85):
- editing_holds_creates_until_finished
- editing_still_pushes_updates
- subtask_created_in_open_detail_panel_syncs

Flush on exit:
- flush_on_exit_pushes_a_change_made_just_before_quitting
- flush_on_exit_releases_the_held_create_the_open_panel_was_holding
- flush_on_exit_does_nothing_when_signed_out / _in_read_only_mode / _with_a_dead_session

Instance lock:
- instance_lock_excludes_a_second_holder_and_frees_on_drop
- instance_lock_is_scoped_per_data_directory

Remote-conflict matrix (RFC-009 §D/§I):
- deleting_a_task_the_remote_just_edited_removes_it_from_the_view
- removing_a_subtask_the_remote_completed_keeps_the_parent_visible
- a_subtask_whose_parent_is_deleted_elsewhere_dies_with_it
- a_task_added_to_a_list_deleted_elsewhere_shows_up_in_the_default_list
- renaming_a_list_the_other_device_renamed_too_leaves_one_list
- deleting_a_list_takes_its_unpushed_tasks_with_it
- a_list_renamed_here_and_deleted_elsewhere_disappears_with_its_tasks
- a_task_completed_on_another_device_stays_visible_as_done

§J crash/in-flight rows (#113):
- a_cross_list_move_of_a_crashed_create_leaves_nothing_behind
- deleting_a_crashed_create_does_not_resurrect_it_on_the_next_pull
- a_renamed_list_deleted_remotely_keeps_the_rows_the_server_never_saw
- clearing_completed_after_a_crashed_create_does_not_resurrect_it
- remote_reorder_plus_local_rename_no_false_copy_rename_lands
- status_only_divergence_over_a_remote_reorder_never_forks_a_copy
- edit_during_inflight_create_adopts_orphan_no_duplicate_edit_survives
- undoing_the_delete_of_a_crashed_create_leaves_exactly_one_task
- a_tombstone_waits_while_its_own_create_is_still_unresolved_in_flight
- deleting_a_create_whose_insert_never_landed_leaves_no_unpushable_tombstone

Error sanitization (#128/#135, mod user_facing_errors):
- raw_sql_error_is_replaced_and_never_shown_verbatim
- message_is_grouped_by_command_family
- auth_signals_pass_through_so_the_ui_can_react
- deliberate_validation_messages_pass_through
- unknown_error_with_no_known_marker_is_never_shown_verbatim
- raw_network_url_is_never_shown_verbatim

## src/sync_property_test.rs (2406) — 14 tests
PURPOSE: Property/invariant suite (#104): random sequences of REAL command ops against real store + real sync engine + fake Google; asserts invariants on state, never "a call happened".

Op vocabulary (enum Op — RFC-009 §A–§J coverage):
- Local task ops: CreateTop(i), CreateSub(i), Rename(i), SetDue(i,d) (5 date moves), Toggle(i), Delete(i), Reorder(i,up), MoveAfter(i,j), Demote(i), Promote(i), MoveToList(i,j) (§H, subtree re-created under fresh ids)
- List ops (§I): CreateList, RenameList(i), DeleteList(i)
- Remote/phantom-device ops: RemoteEdit(i) (no If-Match → 412 path §B), RemoteComplete(i) (§C), RemoteDelete(i) (§D, server cascade), RemoteCreate(i) (§A pull), RemoteCreateDup(i) (#145 same-content top-level look-alike), RemoteDemote(i) (server 3-level nesting → D7 pull repair), RemoteRenameList(i), RemoteDeleteList(i) (P2/D2 re-homing)
- Panel hold: OpenPanel(i) (holds the create), ClosePanel
- Sync variants: Sync (healthy); FlakySync(k) (one transient fault from a 9-entry TRANSIENT table: 5xx/network/rate-limit per method); InterleaveSync(k) (another device mutates MID-RUN via on_call hook on the pull's first list_tasks — remote delete or create); CrashSync(k) (commit_then_fail_next: server commits, response lost — at-least-once hazard for insert/patch/delete/move); AbortSync(k) (fatal Unauthorized mid-push, run returns Err partly applied — P7/P8 crash window)
- Restart — simulate_restart over the same store; held create + undo token die, persisted state alone must converge

Dual-device layer: DualOp::Step(Side,Op) interleaved on two full app instances over ONE shared fake server; DualOp::Offline(Side, Vec<Op>) — one device edits offline while the other stays online syncing. n:1 fixpoint oracle: A == server && B == server.

The six named invariants (one property test each):
1. eventual push — prop_eventual_push_drains_all_pending_work
2. convergence — prop_local_converges_with_server (local == server field-for-field via Row {list_id,id,parent,title,notes,due,completed}; position excluded)
3. idempotency — prop_sync_after_fixpoint_is_a_no_op (byte-for-byte dump compare)
4. deferral safety — prop_held_work_completes_once_the_hold_clears
5. crash safety — prop_crashed_creates_never_duplicate (crash_ops strategy: creates + edits + lost-insert CrashSync)
6. parent integrity — prop_parent_integrity_under_paged_and_partial_pulls (no dangling parent, max one level)

Plus example/dual tests:
- orphan_adoption_never_claims_a_foreign_parent (#145)
- restart_drops_the_held_create_which_then_pushes
- restart_kills_the_undo_token_and_pushes_the_delete_exactly_once
- dual_racing_demotes_never_form_a_parent_cycle
- prop_dual_two_devices_converge_on_the_server (dual_ops, 1..24 steps)
- dual_two_devices_edit_the_same_task_offline_then_converge
- dual_two_sided_conflicted_copy_terminates_and_agrees
- dual_racing_d7_repairs_have_a_bounded_move_count

Shared assertions: assert_parent_integrity, assert_no_stranded_children, assert_base_null_when_clean (#134/#139 schema invariant), assert_converged, assert_dual_converged.

Determinism/RNG: TestRunner::new_with_rng(TestRng::deterministic_rng(RngAlgorithm::ChaCha)), failure_persistence=None, max_shrink_iters=256 — every run explores the SAME sequences; ops address tasks by UNIQUE TITLE in creation order (survives id remap and cross-list re-creation), lists sorted by title. Env knob: AXIOTASK_PROPTEST_CASES overrides DEFAULT_CASES=256 for soaks (fixed seed ⇒ deeper run explores a strict superset; 1024/4096 each found bugs 256 misses). Fixpoint bounds: MAX_HEAL_RUNS=16, MAX_DUAL_ROUNDS=16. Each case gets its own current-thread runtime + in-memory DB (run_case).

## src/lib.rs (388)
PURPOSE: Shared entry point (`run`) for desktop binary and Android `mobile_entry_point`; all Tauri wiring.

Startup sequence (ordered):
1. init_tracing() — desktop: fmt→stdout; android: fmt→logcat via paranoid_android AndroidLogMakeWriter, tag "axiotask", no ANSI (#157). RUST_LOG default "info".
2. Resolve instance prefix (AXIOTASK_PREFIX) — validates, logs, sets window title "axiotask (<p>)".
3. DESKTOP ONLY: acquire_instance_lock on default_db_path's dir (#48); on failure eprintln + exit(1); fd forgotten (held for process lifetime).
4. Build init script `window.__AXIOTASK_PREFIX__ = <json>` (frontend localStorage namespacing).
5. ANDROID ONLY: builder.plugin(tauri_plugin_google_auth::init()).
6. setup closure:
   a. resolve_db_path — desktop: dirs::data_dir; mobile: app.path().app_data_dir() → db_path_in. Failure → show_startup_error window (injects window.__STARTUP_ERROR__ JSON script) and continue (that window IS the app).
   b. create_dir_all(db parent).
   c. resolve_config_path — desktop: AppConfig::default_path; mobile: app_config_dir (#170). Failure → startup-error window.
   d. block_on(AppState::new(db, config)); failure (e.g. WipeAborted) → startup-error window.
   e. app.manage(Arc<AppState>).
   f. set_sync_notifier(TauriSyncNotifier) — emits `sync-updated` event with SyncStatusView after every sync run.
   g. Build "main" WebviewWindow in code (1000x700, instance title, prefix init script).
   h. Spawn startup task: ANDROID first restore_session_mobile (silent Play Services authorize), then if is_authenticated && auto_sync_on_start → run_sync_if_authed (warn on failure).
   i. Spawn run_sync_loop (debounced mutation trigger + 60s periodic + backoff).
7. invoke_handler = the 29 commands (see commands.rs list).
8. .run event handler: RunEvent::ExitRequested → try_state<Arc<AppState>> → block_on(flush_on_exit()) — bounded final push on every quit path; no-op when startup-error path managed no state.

Tests (2): startup_error_script_carries_the_message_verbatim; startup_error_script_escapes_js_string_breakers.

## src/main.rs (11)
PURPOSE: Desktop shim: `fn main() { axiotask_app::run() }` + windows_subsystem attr.

## src/play_services_auth.rs (57) — android-only
PURPOSE: Adapter from MobileTokenProvider trait to the in-repo tauri-plugin-google-auth (Play Services AuthorizationClient, RFC-010).
- PlayServicesTokenProvider::new(AppHandle)
- authorize(interactive) — spawn_blocking → app.google_auth().authorize(AuthorizeRequest); needs_interaction → InteractionRequired; missing token/plugin error → Unavailable
- sign_out() — spawn_blocking → plugin sign_out (drops account association)
No tests here (compiled only for Android; covered by fakes in state.rs tests + G5 device gate).

## tests/android_build_scaffolding.rs (431) — 8 tests
PURPOSE: Source-string/file guards for Android wiring not compiled on the desktop host.
- android_project_scaffolding_is_checked_in — gen/android gradle/manifest/icons/strings files exist
- android_build_uses_tauri_mobile_entry_points — tauri.conf before-commands, ui npm scripts android:init/dev/build, INTERNET permission, vite TAURI_DEV_HOST
- mobile_entry_point_and_data_dir_wiring_are_in_place — cdylib axiotask_app, mobile_entry_point attr, app_data_dir/app_config_dir resolution, cfg(desktop) gating
- android_logs_are_routed_to_logcat — AndroidLogMakeWriter + android-only paranoid-android dep (#157)
- create_task_emits_a_logcat_marker — the "create_task: created task" info line (#161 smoke signal)
- android_release_signing_reads_gitignored_keystore_properties — release signingConfig from gitignored keystore.properties, .exists() fallback, .gitignore excludes, .example template (#162)
- android_play_services_auth_is_wired_and_158_is_erased — no oauth2redirect/BROWSABLE/custom scheme; android-only plugin dep; plugin registered; no deep-link bridge; no compiled-in client id; plugin crate + Kotlin AuthorizationClient + tasks scope; capabilities/mobile.json android-scoped with google-auth:default (RFC-010 G3/G4)
- mobile_smoke_gate_is_wired_and_opt_in — mobile-smoke.sh exists, executable, contains adb/install/package/activity/logcat/markers; run-smoke.sh never chains into it; npm mobile:smoke + test:e2e scripts

## tests/timestamp_audit.rs (108) — 2 tests
PURPOSE: Source audit against the #47 local-time-labeled-Z bug.
- production_sources_do_not_label_local_time_as_utc — scans core/app/ui sources for forbidden patterns (Local::now, .toISOString(), strftime-with-Z, …)
- app_mutation_layers_use_shared_utc_timestamp_helper — commands.rs and state.rs must use now_utc_string, never format directly

## tests/version_consistency.rs (56) — 3 tests
PURPOSE: One version across Cargo.toml (workspace), tauri.conf.json, ui/package.json.
- version_starts_at_0_1; tauri_conf_version_matches_crate; ui_package_version_matches_crate

## e2e/run-smoke.sh (72)
PURPOSE: Desktop e2e harness: launches the REAL release binary (must be `cargo tauri build --no-bundle`) under tauri-driver + WebKitWebDriver inside a nested Xephyr X server (:97, software rendering, CI-friendly); isolates the run with a temp XDG_DATA_HOME (clean DB + localStorage, offline/no tokens); runs smoke.mjs; after the run greps the tauri-driver log for Rust panics (clean-exit assertion #169) and fails even if the smoke passed; cleanup kills driver/app/Xephyr and removes the temp home. Exit 2 = binary missing.

## e2e/smoke.mjs (369)
PURPOSE: The one test proving the packaged app actually works — WebDriver protocol by hand (fetch), DOM-dispatched clicks/inputs (sendKeys/element-click unsupported in this WebKit config).
Numbered assertions:
- ok 1 — app rendered, not stuck on "Loading..." (catches IPC/startup wedges; special-cases the dev-mode-build "Could not connect to localhost" mistake)
- ok 2 — real click on "+ New task" focuses the quick-add input (dead-clicks check)
- ok 3 — typing + submit creates a task that round-trips create_task IPC and renders (SMOKE-<ts> marker)
- ok 4 — row "Tomorrow" date action persists and renders a due chip
- ok 5 — subtask added ONLY via detail panel (#82/#91: no row affordance, child never a list row, parent shows 0/1 progress)
- ok 6 — detail panel edits title + notes and keeps the saved title
- ok 7 — completion persists; completed row visible with "Show completed" toggle
- ok 8 — "/" opens search overlay; result found and opens the detail panel
- ok 9 — graceful exit (#169): close window via __TAURI__ API, watch /proc pid; must exit < 8s (offline flush is a no-op) with 15s hard ceiling

## e2e/mobile-smoke.sh (138)
PURPOSE: OPT-IN Android emulator smoke gate (#161) — the mobile sibling of run-smoke.sh, never in the automatic quality gate. Via adb: (1) build (or use AXIOTASK_APK) + install the DEBUG apk for com.axiotask.app; (2) clear logcat, launch .MainActivity, assert "starting default instance" under tag axiotask → Rust init ran; (3) drive a quick-add with `adb shell input` (tap FAB at ~90%/90% of screen size, type unique title, KEYCODE_ENTER) and assert "create_task: created task" in logcat → IPC round-tripped; (4) optional AXIOTASK_SMOKE_SIGNIN=1 on a Google-APIs image: tap sign-in and assert "starting Play Services sign-in" (RFC-010 Step 4; full consent stays on the G5 device gate). Exit codes: 0 pass, 1 real failure, 2 SKIPPED (no adb/device/apk) — distinguishable from a pass.
