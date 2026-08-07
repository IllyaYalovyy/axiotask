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

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../store/database.dart';
import '../store/store.dart';
import '../ui/router.dart';
import '../ui/theme.dart';
import 'config_controller.dart';
import 'prefs.dart';
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

/// The app's [GoRouter], built once with the view restored from prefs. Held for
/// the process lifetime (it owns navigation state), so it is a plain Provider.
final routerProvider = Provider<GoRouter>(
  (ref) => buildAppRouter(initialViewId: ref.watch(prefsProvider).view),
);
