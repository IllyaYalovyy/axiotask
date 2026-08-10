// The Properties-dialog snapshot — the Dart port of `commands.rs::AppSettings`,
// the "full Properties-dialog state in one round trip" DTO. It bundles the
// config toggles, the account/auth state, the resolved paths, the pending-push
// count, and the sync status view. Assembled by `appSettingsProvider`.

import 'sync_status.dart';

/// Everything the Properties dialog renders, gathered into one immutable value.
class AppSettingsView {
  const AppSettingsView({
    required this.version,
    required this.instance,
    required this.pushEnabled,
    required this.autoSyncOnStart,
    required this.authenticated,
    required this.needsReauth,
    required this.scopes,
    required this.dbPath,
    required this.configPath,
    required this.pendingPushes,
    required this.sync,
  });

  /// App version string (About tab).
  final String version;

  /// The active instance prefix, or `null` for the default/production instance.
  final String? instance;

  /// Whether local edits are pushed to Google (read-write sync).
  final bool pushEnabled;

  /// Whether the app auto-syncs once on startup.
  final bool autoSyncOnStart;

  /// A live Google session exists.
  final bool authenticated;

  /// The stored session is dead; only a fresh sign-in recovers it.
  final bool needsReauth;

  /// The granted OAuth scopes.
  final List<String> scopes;

  /// Absolute path to the local database (About tab).
  final String dbPath;

  /// Absolute path to the config file (About tab).
  final String configPath;

  /// Number of local changes awaiting a push.
  final int pendingPushes;

  /// The sanitized sync status view (stats + attention).
  final SyncStatusView sync;
}
