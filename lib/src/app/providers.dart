// The providers root — the seam between the imperative bootstrap (which opens
// the database and loads config/prefs with real IO) and the widget tree (which
// reads those singletons through Riverpod).
//
// Each provider here is a placeholder that throws unless overridden. The
// bootstrap opens the real resources once and hands them to the root
// `ProviderScope` as overrides (see [bootstrapOverrides]); nothing in the tree
// ever constructs a database or touches the filesystem directly. This keeps the
// missing_provider_scope lint satisfied and makes every dependency swappable in
// widget tests.

import 'dart:io' show Directory;

import 'package:flutter/material.dart'
    show FocusNode, GlobalKey, ScaffoldState, ThemeMode, VoidCallback, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart' show AuthSnapshot;
import '../model/sync_run.dart';
import '../model/task_view.dart';
import '../store/database.dart';
import '../store/store.dart';
import '../store/stored.dart';
import '../ui/detail_motion.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'app_settings.dart';
import 'app_version.dart';
import 'backup_service.dart';
import 'commands.dart';
import 'config_controller.dart';
import 'local_data_reset.dart';
import 'prefs.dart';
import 'prefs_controller.dart';
import 'sync_status.dart';
import 'window_title_controller.dart';

Never _mustOverride(String name) => throw StateError(
  '$name was read without a bootstrap override — the app must be launched '
  'through bootstrap(), which supplies the opened resources.',
);

/// The active instance prefix (`null` for the production instance), for the
/// window title and settings display.
final instancePrefixProvider = Provider<String?>((ref) => null);

/// The opened local database. Overridden by the bootstrap.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => _mustOverride('appDatabaseProvider'),
);

/// The high-level store over [appDatabaseProvider].
final storeProvider = Provider<Store>(
  (ref) => Store(ref.watch(appDatabaseProvider)),
);

/// The command service (create/rename/toggle today) over [storeProvider] — the
/// mutation surface the widgets drive.
final commandsProvider = Provider<Commands>(
  (ref) => Commands(ref.watch(storeProvider)),
);

/// Live stream of every visible task across all lists — the read behind the
/// "All Tasks" view. Re-emits on any task write in any list.
final allTasksProvider = StreamProvider<List<StoredTask>>(
  (ref) => ref.watch(storeProvider).watchAllTasks(),
);

/// Live stream of all known lists — quick-add resolves its target list from it
/// (the first list when the active view imposes none, e.g. a smart view).
final listsProvider = StreamProvider<List<StoredTaskList>>(
  (ref) => ref.watch(storeProvider).watchLists(),
);

/// The config controller (sync toggles, persist-first). Overridden by bootstrap.
final configControllerProvider = Provider<ConfigController>(
  (ref) => _mustOverride('configControllerProvider'),
);

/// The UI-preferences store over `prefs.json`. Overridden by the bootstrap.
final prefsStoreProvider = Provider<PrefsStore>(
  (ref) => _mustOverride('prefsStoreProvider'),
);

/// A snapshot of the UI preferences read at launch. Defaults to [Prefs] so the
/// widget tree (theme, initial view) renders even when only the app root is
/// pumped without bootstrap overrides (widget/integration tests); the bootstrap
/// overrides it with the real loaded prefs. Unlike [prefsStoreProvider] this
/// never throws — reading it must be safe at construction time.
final prefsProvider = Provider<Prefs>((ref) => const Prefs());

/// The resolved [ThemeMode] from the LIVE `theme` pref ('system' | 'light' |
/// 'dark'). Watches [prefsControllerProvider] (not the static launch snapshot)
/// so a theme change from the Appearance tab or the sidebar toggle re-themes the
/// running app immediately; the launch value flows in through the controller's
/// seed so the boot theme is still the persisted one.
final themeModeProvider = Provider<ThemeMode>(
  (ref) => themeModeFromString(ref.watch(prefsControllerProvider).theme),
);

/// The window-title seam. Defaults to a no-op (mobile / tests); main.dart
/// overrides it with the real `window_manager`-backed controller on desktop.
final windowTitleControllerProvider = Provider<WindowTitleController>(
  (ref) => const NoopWindowTitleController(),
);

/// The known lists in user-defined display order (`prefs.listOrder`). A list
/// absent from the saved order sorts after the ordered ones, keeping its backend
/// position (stable). Feeds the sidebar's list section and the reorder round-trip.
final orderedListsProvider = Provider<List<StoredTaskList>>((ref) {
  final lists =
      ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
  final order = ref.watch(prefsControllerProvider).listOrder;
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final indexed = [for (var i = 0; i < lists.length; i++) (i, lists[i])];
  indexed.sort((a, b) {
    const unranked = 1 << 30;
    final ra = rank[a.$2.list.id] ?? unranked;
    final rb = rank[b.$2.list.id] ?? unranked;
    if (ra != rb) return ra.compareTo(rb);
    return a.$1.compareTo(b.$1); // preserve backend order among unranked
  });
  return [for (final e in indexed) e.$2];
});

/// The sidebar badge counts keyed by view id (smart views + list ids). Open-only,
/// top-level, exclusion-aware for smart views — see [computeViewCounts].
final viewCountsProvider = Provider<Map<String, int>>((ref) {
  final all = ref.watch(allTasksProvider).asData?.value ?? const <StoredTask>[];
  final lists =
      ref.watch(listsProvider).asData?.value ?? const <StoredTaskList>[];
  final excluded = ref.watch(prefsControllerProvider).excludedLists.toSet();
  return computeViewCounts(
    allTasks: all,
    listIds: [for (final l in lists) l.list.id],
    excludedLists: excluded,
    window: dateWindowNow(),
  );
});

/// The auth/sync footer widget pinned at the bottom of the sidebar, or `null`
/// when the live auth controller is not wired into the app (its current state —
/// sign-in/out/sync route through providers a later auth-integration task
/// supplies). Overridable so tests and that future task drop in a live footer.
final sidebarFooterProvider = Provider<Widget?>((ref) => null);

/// The single [FocusNode] the always-visible quick-add input attaches to. Held
/// app-wide (only one quick-add field is ever mounted) so the mobile FAB — which
/// lives outside the list pane — can focus the input without an empty-task
/// create (#166: "+ New task"/FAB/n all just FOCUS the input). Disposed with the
/// container.
final quickAddFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'quickAdd');
  ref.onDispose(node.dispose);
  return node;
});

/// A monotonically-increasing "new task" request (#216): the touch FAB bumps it
/// and the mounted [TaskListView] listens, opening its bottom-sheet composer.
/// A counter (not a bool/event bus) so consecutive taps re-trigger even when a
/// listener missed one; nothing resets it. Desktop never bumps it — the
/// always-visible quick-add bar is the fine-pointer creation affordance.
class NewTaskRequests extends Notifier<int> {
  @override
  int build() => 0;

  /// One FAB tap → one request.
  void bump() => state++;
}

final newTaskRequestProvider = NotifierProvider<NewTaskRequests, int>(
  NewTaskRequests.new,
);

/// Whether the touch composer — the sheet the FAB morphs into (#234) — is on
/// screen. The list owns the sheet; the shell owns the FAB; and the two are one
/// affordance, so the shell must know not to draw a FAB over the composer it
/// just became. (It used to: the sheet went on the shell's NESTED navigator and
/// the FAB, one Scaffold above it, covered the composer's own submit button.)
class ComposerOpen extends Notifier<bool> {
  @override
  bool build() => false;

  /// Publish that the composer is opening (`true`) or folding away (`false`).
  void set(bool open) => state = open;
}

final composerOpenProvider = NotifierProvider<ComposerOpen, bool>(
  ComposerOpen.new,
);

/// A stable [GlobalKey] for the compact (phone) [Scaffold], so the shell can
/// drive its slide-in drawer (open via the hamburger, close after a navigation)
/// across the rebuilds a route change triggers. Held for the app lifetime — a
/// key rebuilt each frame would detach the Scaffold's state.
final mobileScaffoldKeyProvider = Provider<GlobalKey<ScaffoldState>>(
  (ref) => GlobalKey<ScaffoldState>(),
);

/// The one [DetailOriginController] (#253) — where the compact detail's
/// container transform grows from. A [Provider] so it outlives the shell's own
/// rebuilds: the rect is written by the row's tap and read one navigation
/// later, and a controller recreated in between would lose it.
final detailOriginProvider = Provider<DetailOriginController>(
  (ref) => DetailOriginController(),
);

/// The list's active multi-select, surfaced up to the shell's back-precedence
/// ladder (T8.3). The list keeps ownership of the selection LOGIC; this only
/// lets the app-level back handler (which lives in the root route, above the
/// list's nested shell navigator) SEE that a selection is active and clear it in
/// precedence order — a plain [PopScope] inside the list would sit under
/// go_router's shell navigator and never receive the Android system back. The
/// value is `true` while a selection is active; [clear] runs the list's own
/// clear-selection when the ladder reaches that rung.
class SelectionBackHandle extends Notifier<bool> {
  VoidCallback? _clear;

  @override
  bool build() => false;

  /// Publish (or, with `null`, retract) the active selection's clear action.
  /// Called by the list whenever its selection becomes (non-)empty.
  void set(VoidCallback? clear) {
    _clear = clear;
    state = clear != null;
  }

  /// Clear the active selection, if any — invoked by the back ladder.
  void clear() => _clear?.call();
}

/// See [SelectionBackHandle]. Held app-wide (only one list is ever mounted).
final selectionBackHandleProvider = NotifierProvider<SelectionBackHandle, bool>(
  SelectionBackHandle.new,
);

/// A row's open inline-rename editor, surfaced up to the shell's back-precedence
/// ladder (G4 #183) — the same pattern as [SelectionBackHandle], and for the
/// same reason: a plain [PopScope] on the row sits under go_router's shell
/// navigator and never receives the Android system back, so the row instead
/// publishes its commit action here for the root-route back handler. Registering
/// the rename in [PendingEdits] alone covers backgrounding/process-death
/// (`flushAll`), but a system back at the root bubbles straight to the OS
/// without firing any [PopScope], so the shell must actively intercept it to
/// commit a mid-typing rename. The value is `true` while an editor is open;
/// [commit] runs the row's own flush-and-close when the ladder reaches that rung.
class RenameBackHandle extends Notifier<bool> {
  VoidCallback? _commit;

  @override
  bool build() => false;

  /// Publish (or, with `null`, retract) the open editor's commit action. Called
  /// by the row when its inline-rename editor mounts / unmounts.
  void set(VoidCallback? commit) {
    _commit = commit;
    state = commit != null;
  }

  /// Commit the open inline rename (persist the text and close the editor), if
  /// any — invoked by the back ladder.
  void commit() => _commit?.call();
}

/// See [RenameBackHandle]. Held app-wide (only one inline editor at a time).
final renameBackHandleProvider = NotifierProvider<RenameBackHandle, bool>(
  RenameBackHandle.new,
);

/// Runs a manual refresh — the mobile pull-to-refresh gesture (and, later, a
/// Sync-now button). The reactive store keeps every view live, so a plain
/// "reload" is already continuous; the default is a completed future and the
/// sync subsystem overrides this to run a real sync when a session is live
/// (mirrors the reference's "sync when authed, else reload"). Overridable so a
/// test can drive the pull affordance deterministically.
final refreshActionProvider = Provider<Future<void> Function()>(
  (ref) => () async {},
);

/// The app's [GoRouter], built once with the view restored from prefs. Held for
/// the process lifetime (it owns navigation state), so it is a plain Provider.
final routerProvider = Provider<GoRouter>(
  (ref) => buildAppRouter(initialViewId: ref.watch(prefsProvider).view),
);

// ── Properties dialog data + backup seam ──────────────────────────────────────

/// The app version string (About tab). Overridable so a test can pin it.
final appVersionProvider = Provider<String>((ref) => appVersion);

/// The database file path shown on the About tab. Empty until the bootstrap
/// overrides it with the real path (display-only).
final dbPathProvider = Provider<String>((ref) => '');

/// The config file path shown on the About tab. Overridden by the bootstrap.
final configPathProvider = Provider<String>((ref) => '');

/// The instance's backups directory. Overridden by the bootstrap; a test that
/// exercises real export/import overrides it with a temp dir.
final backupsDirProvider = Provider<Directory>(
  (ref) => _mustOverride('backupsDirProvider'),
);

/// The backup export/import service over the store and the backups dir.
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    store: ref.watch(storeProvider),
    backupsDir: ref.watch(backupsDirProvider),
  ),
);

/// The account-switch reset (#215): the durable pre-reset dump + the store
/// nuke, over the opened database and its real file path. Reading it needs the
/// bootstrap overrides, so the Account tab only touches it inside the confirmed
/// gesture — never at build time.
final localDataResetProvider = Provider<LocalDataReset>(
  (ref) => LocalDataReset(
    database: ref.watch(appDatabaseProvider),
    store: ref.watch(storeProvider),
    dbPath: ref.watch(dbPathProvider),
  ),
);

/// The live count of local changes awaiting a push, shown by Properties, the
/// Sync activity screen and the reset confirm.
///
/// A drift stream, not a one-shot read: this number stays on screen for the
/// whole session, and a snapshot taken at first watch kept reporting changes
/// pending long after the push that drained them (#232).
final pendingPushCountProvider = StreamProvider<int>(
  (ref) => ref.watch(storeProvider).watchPendingPushCount(),
);

/// The recent sync runs the Sync activity screen renders (#218), newest first
/// and capped by [Store.recentSyncRuns].
///
/// `autoDispose` so each visit to the screen re-reads the log: nothing watches
/// it while the screen is closed, so the provider is disposed and the next open
/// starts from a fresh query rather than a snapshot taken sessions ago.
final syncRunsProvider = FutureProvider.autoDispose<List<SyncRun>>(
  (ref) => ref.watch(storeProvider).recentSyncRuns(),
);

/// The live auth snapshot. The composition root (F5) overrides this with the
/// [AuthController]'s seeded-then-subscribed stream (seed the current snapshot
/// first — `changes` has no initial replay — then follow every transition).
/// Default: a single signed-out snapshot, so the derived seams below read
/// "signed out" whenever the runtime is not mounted (widget tests, error
/// screen).
final authSnapshotProvider = StreamProvider<AuthSnapshot>(
  (ref) => Stream.value(
    const AuthSnapshot(isAuthenticated: false, needsReauth: false),
  ),
);

/// The live sanitized sync-status stream. F5 overrides this with the
/// scheduler's status seeded-then-subscribed to its post-run emissions (the F4
/// sanitized surface). Default: a single "never synced" view.
final syncStatusStreamProvider = StreamProvider<SyncStatusView>(
  (ref) => Stream.value(const SyncStatusView.initial()),
);

/// The live per-run sync signal (#255) — one event when a run starts and one
/// when it ends. F5 overrides this with the scheduler's `runs` stream; the
/// default never emits, so an app without a mounted runtime (widget tests, the
/// error screen) simply never shows a sync line.
final syncRunEventsProvider = StreamProvider<SyncRunEvent>(
  (ref) => const Stream<SyncRunEvent>.empty(),
);

/// Whether a sync run is in flight RIGHT NOW — what the quiet sync line
/// renders from. False before the first event and false after every finish.
final syncRunningProvider = Provider<bool>(
  (ref) => ref.watch(syncRunEventsProvider).value?.running ?? false,
);

/// The sanitized sync-status view the Sync tab and footer render, derived from
/// the live [syncStatusStreamProvider] (its latest value, or "never synced"
/// before the first emission).
final syncStatusViewProvider = Provider<SyncStatusView>(
  (ref) =>
      ref.watch(syncStatusStreamProvider).value ??
      const SyncStatusView.initial(),
);

/// Whether a live Google session exists, derived from [authSnapshotProvider].
/// Signed-out is the safe default (the sync actions gate on it).
final authenticatedProvider = Provider<bool>(
  (ref) => ref.watch(authSnapshotProvider).value?.isAuthenticated ?? false,
);

/// Whether this install is meant to reach Google at all: auto-sync on start,
/// read-write sync, or a session already on disk. It is the difference between
/// a missing-credentials config being a LOUD startup fault and a deliberately
/// local-only app staying quiet (#228). The composition root (F5) overrides it
/// from the live config; the default is `true` because the shipped config
/// auto-syncs on start.
final syncIntendedProvider = Provider<bool>((ref) => true);

/// The config file whose Google credentials are missing, or null when the app
/// can authenticate (#228). Derived from [authSnapshotProvider], so it appears
/// as soon as the detached startup restore reports the fault.
final missingAuthConfigProvider = Provider<String?>(
  (ref) => ref.watch(authSnapshotProvider).value?.missingConfigPath,
);

/// Whether the stored session is dead (needs re-auth), derived from
/// [authSnapshotProvider].
final needsReauthProvider = Provider<bool>(
  (ref) => ref.watch(authSnapshotProvider).value?.needsReauth ?? false,
);

/// Run the OAuth sign-in from the Account tab / footer. A no-op default until
/// the composition root (F5) overrides it with the real gesture.
final signInActionProvider = Provider<VoidCallback>((ref) => () {});

/// Drop the session from the Account tab / footer. A no-op default until F5
/// overrides it with the real logout.
final signOutActionProvider = Provider<VoidCallback>((ref) => () {});

/// Execute a fresh sync (clear local synced data + full re-pull). Defaults to
/// the local half via [Commands.freshSync]; the scheduler task overrides it to
/// also drive the re-pull. Gated behind authentication in the UI.
final freshSyncActionProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => ref.read(commandsProvider).freshSync(),
);

/// The assembled Properties-dialog snapshot (`get_settings` DTO).
final appSettingsProvider = Provider<AppSettingsView>((ref) {
  final config = ref.watch(configControllerProvider);
  return AppSettingsView(
    version: ref.watch(appVersionProvider),
    instance: ref.watch(instancePrefixProvider),
    pushEnabled: config.pushEnabled,
    autoSyncOnStart: config.autoSyncOnStart,
    authenticated: ref.watch(authenticatedProvider),
    needsReauth: ref.watch(needsReauthProvider),
    // GRANTED scopes, not requested ones: with no live session Google has
    // granted nothing, and listing the scope anyway made a signed-out Account
    // tab read as signed in (#228). AccountSection already documents "empty
    // when signed out"; this is the wiring catching up.
    scopes: ref.watch(authenticatedProvider) ? config.scopes : const [],
    credentialsMissing: ref.watch(missingAuthConfigProvider) != null,
    dbPath: ref.watch(dbPathProvider),
    configPath: ref.watch(configPathProvider),
    pendingPushes: ref.watch(pendingPushCountProvider).asData?.value ?? 0,
    sync: ref.watch(syncStatusViewProvider),
  );
});
