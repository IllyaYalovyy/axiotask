// Application configuration over `config.json` — the Dart port of `config.rs`.
//
// Adaptation from the reference (documented, per MIGRATION-PLAN §2): the
// reference stores config as TOML with comment preservation via `toml_edit`.
// The format dies with the migration — Dart config is JSON — so the
// TOML-comment-preservation tests do NOT port; every other config test does.
//
// `config.json` holds the desktop OAuth client id/secret (GoogleConfig) and the
// sync toggles (SyncConfig: push_enabled default OFF, auto_sync_on_start default
// ON). It lives beside the DB but OUTSIDE the schema fingerprint, so a schema
// wipe never touches it (a wipe destroys the cache only).
//
// The #171 persist-first contract lives in [saveSyncTo]: the settings are
// written durably FIRST; the caller (`ConfigController`) flips its in-memory
// state only after the write succeeds, so a failed write never leaves the app
// claiming a setting the disk does not hold.

import 'dart:convert';
import 'dart:io';

/// The single OAuth scope the app requests: read/write access to Google Tasks.
const String tasksScope = 'https://www.googleapis.com/auth/tasks';

/// Google API credentials and settings. Ported from `GoogleConfig`.
class GoogleConfig {
  const GoogleConfig({
    this.clientId = '',
    this.clientSecret = '',
    this.scopes = const [tasksScope],
  });

  /// OAuth client ID (desktop "Desktop app" client). Empty until configured.
  final String clientId;

  /// OAuth client secret. Empty until configured.
  final String clientSecret;

  /// OAuth scopes.
  final List<String> scopes;

  Map<String, Object?> toJson() => {
    'client_id': clientId,
    'client_secret': clientSecret,
    'scopes': scopes,
  };

  factory GoogleConfig.fromJson(Map<String, Object?> json) => GoogleConfig(
    clientId: json['client_id'] as String? ?? '',
    clientSecret: json['client_secret'] as String? ?? '',
    scopes: (json['scopes'] as List?)?.cast<String>() ?? const [tasksScope],
  );
}

/// Sync settings. Ported from `SyncConfig` — push OFF, auto-sync ON by default.
class SyncConfig {
  const SyncConfig({this.pushEnabled = false, this.autoSyncOnStart = true});

  /// Whether to push local changes to Google.
  final bool pushEnabled;

  /// Auto-sync once on startup.
  final bool autoSyncOnStart;

  Map<String, Object?> toJson() => {
    'push_enabled': pushEnabled,
    'auto_sync_on_start': autoSyncOnStart,
  };

  factory SyncConfig.fromJson(Map<String, Object?> json) => SyncConfig(
    pushEnabled: json['push_enabled'] as bool? ?? false,
    autoSyncOnStart: json['auto_sync_on_start'] as bool? ?? true,
  );
}

/// Top-level application configuration. Ported from `AppConfig`.
class AppConfig {
  const AppConfig({
    this.google = const GoogleConfig(),
    this.sync = const SyncConfig(),
  });

  final GoogleConfig google;
  final SyncConfig sync;

  Map<String, Object?> toJson() => {
    'google': google.toJson(),
    'sync': sync.toJson(),
  };

  /// Parse an [AppConfig] from decoded JSON, applying field-level defaults to
  /// anything absent (a partial config keeps the defaults for the rest).
  factory AppConfig.fromJson(Map<String, Object?> json) => AppConfig(
    google: GoogleConfig.fromJson(
      (json['google'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    sync: SyncConfig.fromJson(
      (json['sync'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
  );

  /// Load config from [path], or `null` if it is missing or malformed.
  /// Mirrors `load_from` — a bad file falls back to defaults at the call site.
  static AppConfig? loadFrom(File path) {
    if (!path.existsSync()) return null;
    try {
      final decoded = jsonDecode(path.readAsStringSync());
      if (decoded is! Map) return null;
      return AppConfig.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// The embedded default config as pretty JSON text.
  static String defaultJson() =>
      const JsonEncoder.withIndent('  ').convert(const AppConfig().toJson());

  /// Write a default config file at [path] if it doesn't already exist.
  /// Ported from `write_default_if_missing_at`.
  static void writeDefaultIfMissingAt(File path) {
    if (path.existsSync()) return;
    path.parent.createSync(recursive: true);
    path.writeAsStringSync(defaultJson(), flush: true);
  }

  /// Persist the `[sync]` settings to [path], preserving the `[google]`
  /// credentials already on disk. Ported from `save_sync_to` minus the
  /// TOML-comment preservation (JSON has no comments).
  ///
  /// This is the durable half of the #171 persist-first contract: it throws
  /// [FileSystemException] on a write failure so the caller can decline to flip
  /// its in-memory state. Creates the file from defaults if it is missing.
  static void saveSyncTo(File path, SyncConfig sync) {
    final existing = loadFrom(path) ?? const AppConfig();
    final merged = AppConfig(google: existing.google, sync: sync);
    path.parent.createSync(recursive: true);
    path.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(merged.toJson()),
      flush: true,
    );
  }
}
