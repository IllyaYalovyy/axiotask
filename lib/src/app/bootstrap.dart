// Startup orchestration — the Dart port of `lib.rs::run` + `AppState::new`,
// narrowed to what exists at T2.1 (auth/sync land in Steps 3/5/6).
//
// Ordered exactly as the reference (MIGRATION-PLAN §2), and for the same
// reasons:
//
//   logging → instance/dev-mode → flock (desktop) → paths → config/prefs load
//   → DB open (WipeAborted → startup-error SCREEN) → ensure default list
//   → providers → [FIRST FRAME] → then a detached task: auth restore →
//     auto-sync → scheduler start.
//
// The last step is DETACHED on purpose: the first frame NEVER waits on restore
// or any network/plugin call (#175 and the geometry-freeze lesson, made
// structural). At T2.1 that detached task is empty — the seam is [onReady].
//
// Everything the entry point needs to vary by platform or test is injected:
// the data/config base directories, the process environment, and whether to
// take the desktop single-instance lock. That keeps this function runnable in a
// unit test against temp dirs with no window, no plugins, and no real XDG dirs.

import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;

import '../auth/token_store.dart';
import '../store/database.dart';
import '../store/store.dart';
import '../store/store_error.dart';
import 'backup_paths.dart';
import 'config.dart';
import 'config_controller.dart';
import 'default_list.dart';
import 'instance.dart';
import 'instance_lock.dart';
import 'logging.dart';
import 'prefs.dart';
import 'providers.dart';

/// Outcome of [bootstrap]: either the app is ready to mount, or a fatal error
/// must be shown on the startup-error screen.
sealed class BootstrapResult {
  const BootstrapResult();
}

/// The app opened successfully. Mount a `ProviderScope(overrides: overrides)`.
class BootstrapReady extends BootstrapResult {
  const BootstrapReady({
    required this.overrides,
    required this.database,
    required this.configController,
    required this.prefsStore,
    required this.tokensFile,
    required this.instancePrefix,
    this.lock,
  });

  /// Overrides for the root `ProviderScope` (opened DB, config, prefs, prefix).
  final List<Override> overrides;

  /// The opened database — kept so the entry point can close it on shutdown,
  /// and to build the [Store] the composition root hands the scheduler.
  final AppDatabase database;

  /// The loaded config controller — the composition root reads the desktop
  /// OAuth credentials + the push/auto-sync toggles from it.
  final ConfigController configController;

  /// The UI-prefs store — the entry point feeds it to the window service for
  /// the post-first-frame size restore (outside the widget tree).
  final PrefsStore prefsStore;

  /// The desktop token file beside the DB — the composition root builds a
  /// [FileTokenStore] over it for the desktop auth path (absent on Android).
  final File tokensFile;

  /// The active instance prefix, or `null` for production.
  final String? instancePrefix;

  /// The held single-instance lock (desktop), or `null` when not taken.
  final InstanceLock? lock;
}

/// Startup failed fatally; [message] is shown verbatim on the error screen.
class BootstrapFailed extends BootstrapResult {
  const BootstrapFailed(this.message);

  final String message;
}

/// The desktop token file (`tokens.json`) beside the DB — the composition root
/// (F5) also builds a [FileTokenStore] over this path. Android never writes it.
File tokensFileBeside(File dbFile) =>
    File('${dbFile.parent.path}${Platform.pathSeparator}tokens.json');

/// Whether a persisted session exists — the "real auth state" at seed time. A
/// malformed token file is treated as no session (seed anyway; the restore path
/// surfaces the error later, and a seed converges by title regardless).
bool _storedSessionExists(File tokensFile) {
  try {
    return FileTokenStore(tokensFile).load() != null;
  } catch (_) {
    return false;
  }
}

/// Run the ordered startup sequence.
///
/// - [dataBase] / [configBase] are the platform data/config roots the instance
///   layout is rooted at (desktop: XDG dirs; injected in tests).
/// - [env] is the process environment (for `AXIOTASK_PREFIX`).
/// - [takeInstanceLock] guards the desktop single-instance lock; the entry
///   point passes `true` only on desktop.
Future<BootstrapResult> bootstrap({
  required Directory dataBase,
  required Directory configBase,
  Map<String, String>? env,
  bool takeInstanceLock = false,
}) async {
  Log.initLogging();

  // Instance / dev-mode isolation. An invalid AXIOTASK_PREFIX is a hard
  // misconfiguration: surface it on the error screen rather than silently
  // resolving to production data.
  final String? prefix;
  try {
    prefix = instancePrefix(env: env);
  } on ArgumentError catch (e) {
    return BootstrapFailed('invalid $instanceEnv: ${e.message}');
  }
  Log.info(
    prefix == null
        ? 'starting default instance'
        : "starting isolated instance '$prefix' (${appDirNameFor(prefix)})",
  );

  final dbFile = dbPathIn(dataBase, env: env);
  final configFile = configPathIn(configBase, env: env);
  final prefsFile = prefsPathIn(dataBase, env: env);

  // Single-instance guard (#48), desktop only, before anything opens the DB.
  InstanceLock? lock;
  if (takeInstanceLock) {
    try {
      lock = acquireInstanceLock(dbFile);
    } on InstanceLockBusy catch (e) {
      Log.error(e.message);
      return BootstrapFailed(e.message);
    } on InstanceLockError catch (e) {
      Log.error(e.message);
      return BootstrapFailed(e.message);
    }
  }

  try {
    // config.json: write defaults if missing, then load.
    AppConfig.writeDefaultIfMissingAt(configFile);
    final configController = ConfigController.load(configFile);

    // prefs.json store (loaded lazily by readers; survives schema wipes).
    final prefsStore = PrefsStore(prefsFile);

    // Open the DB. A WipeAborted (or any store/IO error) is fatal → error
    // screen; the reference shows a window here rather than vanishing.
    final AppDatabase database;
    try {
      dbFile.parent.createSync(recursive: true);
      database = await AppDatabase.open(dbFile);
    } on StoreError catch (e) {
      Log.error('store failed to open: ${e.message}');
      lock?.release();
      return BootstrapFailed(e.message);
    }

    final store = Store(database);

    // Seed "My Tasks" only when there is no session and the store is empty. The
    // real auth state at startup is "does a persisted session exist": desktop
    // keeps a refresh token in tokens.json beside the DB (its presence IS a live
    // session — the detached restore just re-hydrates it after the first frame),
    // and Android persists nothing, so the file is absent and a fresh device
    // seeds then converges by title on the first pull (default_list.dart). A
    // signed-in desktop user therefore gets their real lists from sync, never a
    // duplicate local seed.
    final hasSession = _storedSessionExists(tokensFileBeside(dbFile));
    await ensureDefaultList(store, isAuthenticated: hasSession);

    return BootstrapReady(
      database: database,
      configController: configController,
      prefsStore: prefsStore,
      tokensFile: tokensFileBeside(dbFile),
      instancePrefix: prefix,
      lock: lock,
      overrides: [
        instancePrefixProvider.overrideWithValue(prefix),
        appDatabaseProvider.overrideWithValue(database),
        configControllerProvider.overrideWithValue(configController),
        prefsStoreProvider.overrideWithValue(prefsStore),
        // Snapshot the loaded prefs for the widget tree (theme + initial view).
        prefsProvider.overrideWithValue(prefsStore.load()),
        // Backup target + About-tab paths (display-only for the latter).
        backupsDirProvider.overrideWithValue(backupsDirIn(dataBase, env: env)),
        dbPathProvider.overrideWithValue(dbFile.path),
        configPathProvider.overrideWithValue(configFile.path),
      ],
    );
  } catch (e) {
    // Any unexpected fatal → error screen, never a blank/hung window.
    Log.error('startup failed: $e');
    lock?.release();
    return BootstrapFailed('$e');
  }
}
