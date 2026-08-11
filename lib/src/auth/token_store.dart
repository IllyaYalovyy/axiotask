// Token persistence — the Dart port of `auth/store.rs` plus the app-layer
// `FileTokenStore` from `state.rs`. Desktop is the only platform that persists
// token material: Android holds no tokens (Play Services owns the grant,
// RFC-010 G4), so nothing here runs on device.
//
// The reference stored tokens in the OS keychain; that impl dies (MIGRATION-PLAN
// §2 auth: "keyring impl dies"). Q4 ruled the replacement is a plain
// `tokens.json` file beside the DB, written 0600 so other local users can't read
// the refresh token. The enumerated file tests port 1:1.

import 'dart:convert';
import 'dart:io';

import 'auth_error.dart';

/// Tokens persisted between sessions. The access token is short-lived; the
/// refresh token is the long-term credential. Mirrors `StoredTokens` including
/// its serde shape (snake_case keys; `access_expires_at` omitted when null).
class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    required this.refreshToken,
    this.accessExpiresAt,
    this.scope = '',
  });

  /// Bearer access token.
  final String accessToken;

  /// Refresh token issued by Google.
  final String refreshToken;

  /// Unix-epoch seconds at which [accessToken] expires, or null if unknown.
  final int? accessExpiresAt;

  /// Granted scopes, space-separated as Google returns them.
  final String scope;

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    // Matches serde `skip_serializing_if = "Option::is_none"`.
    if (accessExpiresAt != null) 'access_expires_at': accessExpiresAt,
    'scope': scope,
  };

  factory StoredTokens.fromJson(Map<String, Object?> json) => StoredTokens(
    accessToken: json['access_token'] as String? ?? '',
    refreshToken: json['refresh_token'] as String? ?? '',
    accessExpiresAt: (json['access_expires_at'] as num?)?.toInt(),
    scope: json['scope'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is StoredTokens &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.accessExpiresAt == accessExpiresAt &&
      other.scope == scope;

  @override
  int get hashCode =>
      Object.hash(accessToken, refreshToken, accessExpiresAt, scope);
}

/// Persistence boundary for the auth subsystem. Sync, mirroring the reference
/// trait (the token file is tiny and only touched at sign-in/restore/logout).
abstract interface class TokenStore {
  /// Read the persisted tokens, or null if not signed in.
  StoredTokens? load();

  /// Persist a token bundle, replacing whatever was stored before.
  void save(StoredTokens tokens);

  /// Remove any persisted tokens.
  void clear();
}

/// Volatile, in-process token store. Round-trips exactly like [FileTokenStore]
/// — used by the desktop provider's tests and any offline/in-memory wiring.
class InMemoryTokenStore implements TokenStore {
  StoredTokens? _tokens;

  @override
  StoredTokens? load() => _tokens;

  @override
  void save(StoredTokens tokens) => _tokens = tokens;

  @override
  void clear() => _tokens = null;
}

/// Runs `chmod 600` on [path] and returns the process exit code. Injectable so
/// the failure path (a non-zero exit) is testable without arranging a real
/// permission error on the host filesystem.
typedef ChmodRunner = int Function(String path);

/// File-backed token store: JSON at [file], created 0600 (owner-only) on POSIX.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.file, {ChmodRunner? chmod}) : _chmod = chmod ?? _run600;

  /// The `tokens.json` file (beside the DB in production).
  final File file;

  /// How to apply owner-only permissions; defaults to the real `chmod`.
  final ChmodRunner _chmod;

  static int _run600(String path) =>
      Process.runSync('chmod', ['600', path]).exitCode;

  @override
  StoredTokens? load() {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        throw const TokenStoreException('tokens.json is not a JSON object');
      }
      return StoredTokens.fromJson(decoded.cast<String, Object?>());
    } on FormatException catch (e) {
      throw TokenStoreException('tokens.json is malformed: ${e.message}');
    }
  }

  @override
  void save(StoredTokens tokens) {
    file.parent.createSync(recursive: true);
    // Create the file empty and lock it to 0600 BEFORE any token bytes land, so
    // the refresh token is never — not even momentarily — in a world/group
    // readable file. If the lockdown fails there is no secret on disk to leak,
    // and the empty placeholder is removed so it cannot wedge a later load().
    file.writeAsStringSync('', flush: true);
    try {
      _restrictPermissions();
    } on TokenStoreException {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Nothing more to do — surface the original restriction failure.
      }
      rethrow;
    }
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(tokens.toJson()),
      flush: true,
    );
  }

  @override
  void clear() {
    // Best effort, like the reference: a missing file is already "cleared".
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Ignore — nothing to clear if it cannot be removed (e.g. already gone).
    }
  }

  /// Set the tokens file to 0600 so the refresh token is not world/group
  /// readable. POSIX only; dart:io has no chmod, so we shell out to `chmod`
  /// (desktop is Linux, and Android never reaches this code).
  ///
  /// A failure to restrict is a save failure, not a swallowed best effort: a
  /// non-zero `chmod` exit — or a missing `chmod` binary — means the refresh
  /// token cannot be secured, so we refuse to write it in the clear.
  void _restrictPermissions() {
    if (Platform.isWindows) return;
    final int exitCode;
    try {
      exitCode = _chmod(file.path);
    } on ProcessException catch (e) {
      throw TokenStoreException(
        'could not restrict tokens.json permissions: ${e.message}',
      );
    }
    if (exitCode != 0) {
      throw TokenStoreException(
        'chmod 600 on tokens.json failed (exit $exitCode)',
      );
    }
  }
}
