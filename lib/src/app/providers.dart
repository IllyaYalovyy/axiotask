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

import 'package:flutter/material.dart' show ThemeMode, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../model/task_view.dart';
import '../store/database.dart';
import '../store/store.dart';
import '../store/stored.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'commands.dart';
import 'config_controller.dart';
import 'prefs.dart';
import 'prefs_controller.dart';
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

/// The resolved [ThemeMode] from the `theme` pref ('system' | 'light' | 'dark').
final themeModeProvider = Provider<ThemeMode>(
  (ref) => themeModeFromString(ref.watch(prefsProvider).theme),
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

/// The app's [GoRouter], built once with the view restored from prefs. Held for
/// the process lifetime (it owns navigation state), so it is a plain Provider.
final routerProvider = Provider<GoRouter>(
  (ref) => buildAppRouter(initialViewId: ref.watch(prefsProvider).view),
);
