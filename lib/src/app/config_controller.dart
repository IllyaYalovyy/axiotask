// In-memory config state with the #171 persist-first contract — the Dart port
// of AppState's `set_auto_sync_on_start` accessor.
//
// The toggle is held in memory for fast reads (accessors mirror
// `auto_sync_on_start` / `scopes`). A setter persists the
// change to `config.json` FIRST and flips the in-memory value ONLY when the
// write succeeds (#171): if the disk write throws, the app must not go on
// claiming a setting the file does not hold — the next restart would silently
// revert it.

import 'dart:io';

import 'config.dart';

/// Holds the mutable sync settings backed by a `config.json` file.
class ConfigController {
  ConfigController({required this.path, required AppConfig initial})
    : _google = initial.google,
      _autoSyncOnStart = initial.sync.autoSyncOnStart;

  /// Build from whatever is on disk at [path] (defaults if missing/malformed).
  factory ConfigController.load(File path) => ConfigController(
    path: path,
    initial: AppConfig.loadFrom(path) ?? const AppConfig(),
  );

  /// Path to the config file (display-only).
  final File path;
  final GoogleConfig _google;
  bool _autoSyncOnStart;

  /// Whether the app auto-syncs once on startup.
  bool get autoSyncOnStart => _autoSyncOnStart;

  /// OAuth scopes currently configured (display-only).
  List<String> get scopes => _google.scopes;

  /// The desktop OAuth client credentials + scopes. The composition root (F5)
  /// reads these to build the desktop [OAuthConfig]; Android ignores them (Play
  /// Services identifies the app by package + SHA-1, RFC-010).
  GoogleConfig get google => _google;

  /// Persist `auto_sync_on_start = [value]` durably, THEN flip in memory. If
  /// the write fails the in-memory state is left untouched (#171).
  Future<void> setAutoSyncOnStart(bool value) async {
    AppConfig.saveSyncTo(path, SyncConfig(autoSyncOnStart: value));
    _autoSyncOnStart = value;
  }
}
