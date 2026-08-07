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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/database.dart';
import '../store/store.dart';
import 'config_controller.dart';
import 'prefs.dart';

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
