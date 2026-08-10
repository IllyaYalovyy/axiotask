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

import '../model/task_view.dart';
import '../store/database.dart';
import '../store/store.dart';
import '../store/stored.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'app_settings.dart';
import 'app_version.dart';
import 'backup_service.dart';
import 'commands.dart';
import 'config_controller.dart';
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

/// A stable [GlobalKey] for the compact (phone) [Scaffold], so the shell can
/// drive its slide-in drawer (open via the hamburger, close after a navigation)
/// across the rebuilds a route change triggers. Held for the app lifetime — a
/// key rebuilt each frame would detach the Scaffold's state.
final mobileScaffoldKeyProvider = Provider<GlobalKey<ScaffoldState>>(
  (ref) => GlobalKey<ScaffoldState>(),
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

/// The live count of local changes awaiting a push (Properties Sync stats).
final pendingPushCountProvider = FutureProvider<int>(
  (ref) => ref.watch(storeProvider).pendingPushCount(),
);

/// The sanitized sync-status view the Sync tab renders. Defaults to "never
/// synced"; the scheduler-integration task overrides it with the live stream.
final syncStatusViewProvider = Provider<SyncStatusView>(
  (ref) => const SyncStatusView.initial(),
);

/// Whether a live Google session exists. Auth-integration overrides this;
/// signed-out is the safe default (the sync actions gate on it).
final authenticatedProvider = Provider<bool>((ref) => false);

/// Whether the stored session is dead (needs re-auth). Overridden by auth.
final needsReauthProvider = Provider<bool>((ref) => false);

/// Run the OAuth sign-in from the Account tab. No-op until auth is wired.
final signInActionProvider = Provider<VoidCallback>((ref) => () {});

/// Drop the session from the Account tab. No-op until auth is wired.
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
    scopes: config.scopes,
    dbPath: ref.watch(dbPathProvider),
    configPath: ref.watch(configPathProvider),
    pendingPushes: ref.watch(pendingPushCountProvider).asData?.value ?? 0,
    sync: ref.watch(syncStatusViewProvider),
  );
});
