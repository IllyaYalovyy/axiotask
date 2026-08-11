// In-memory config state with the #171 persist-first contract — the Dart port
// of AppState's `set_push_enabled` / `set_auto_sync_on_start` accessors.
//
// The toggles are held in memory for fast reads (accessors mirror
// `is_push_enabled` / `auto_sync_on_start` / `scopes`). A setter persists the
// change to `config.json` FIRST and flips the in-memory value ONLY when the
// write succeeds (#171): if the disk write throws, the app must not go on
// claiming a setting the file does not hold — the next restart would silently
// revert it.

import 'dart:io';

import 'config.dart';

/// Holds the mutable sync toggles backed by a `config.json` file.
class ConfigController {
  ConfigController({required this.path, required AppConfig initial})
    : _google = initial.google,
      _pushEnabled = initial.sync.pushEnabled,
      _autoSyncOnStart = initial.sync.autoSyncOnStart;

  /// Build from whatever is on disk at [path] (defaults if missing/malformed).
  factory ConfigController.load(File path) => ConfigController(
    path: path,
    initial: AppConfig.loadFrom(path) ?? const AppConfig(),
  );

  /// Path to the config file (display-only).
  final File path;
  final GoogleConfig _google;
  bool _pushEnabled;
  bool _autoSyncOnStart;

  /// Whether local changes are pushed to Google.
  bool get pushEnabled => _pushEnabled;

  /// Whether the app auto-syncs once on startup.
  bool get autoSyncOnStart => _autoSyncOnStart;

  /// OAuth scopes currently configured (display-only).
  List<String> get scopes => _google.scopes;

  /// The desktop OAuth client credentials + scopes. The composition root (F5)
  /// reads these to build the desktop [OAuthConfig]; Android ignores them (Play
  /// Services identifies the app by package + SHA-1, RFC-010).
  GoogleConfig get google => _google;

  /// Persist `push_enabled = [value]` durably, THEN flip the in-memory value.
  /// If the write fails the in-memory state is left untouched (#171).
  Future<void> setPushEnabled(bool value) async {
    AppConfig.saveSyncTo(
      path,
      SyncConfig(pushEnabled: value, autoSyncOnStart: _autoSyncOnStart),
    );
    _pushEnabled = value;
  }

  /// Persist `auto_sync_on_start = [value]` durably, THEN flip in memory (#171).
  Future<void> setAutoSyncOnStart(bool value) async {
    AppConfig.saveSyncTo(
      path,
      SyncConfig(pushEnabled: _pushEnabled, autoSyncOnStart: value),
    );
    _autoSyncOnStart = value;
  }
}
