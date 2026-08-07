// Instance-aware paths and dev-mode data isolation — the Dart port of the
// instance-prefix machinery in `config.rs` (`APP_NAME`, `INSTANCE_ENV`,
// `sanitize_prefix`, `instance_prefix`, `app_dir_name`, `config_path_in`) and
// the `db_path_in` helper from `state.rs`.
//
// Every per-user location — the SQLite database, config.json, prefs.json, auth
// tokens, and backups — is namespaced under `axiotask` or, when
// `AXIOTASK_PREFIX` selects an isolated instance, under `axiotask-<prefix>`.
// This is the mechanism that lets a dev or test instance run fully isolated
// from the production instance on the same machine (the "isolate from
// production data" rule): a throwaway prefix points every path at its own
// subtree.
//
// Pure Dart over `dart:io` paths only — no Flutter, no plugins.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Base application name used for the per-user config/data directories.
const String appName = 'axiotask';

/// Environment variable that selects an isolated instance. When set to a
/// non-empty value (e.g. `AXIOTASK_PREFIX=dev`), every per-user location is
/// namespaced under `axiotask-<prefix>` instead of `axiotask`.
const String instanceEnv = 'AXIOTASK_PREFIX';

/// Validate an instance prefix. Returns `null` when [raw] is a legal prefix,
/// or a human-readable reason when it is not.
///
/// Allowed: ASCII letters, digits, `-` and `_`, up to 64 chars. This both
/// keeps directory names tidy and prevents path traversal (no `/`, `\`, `.`),
/// so the prefix can be trusted in a path. Ported from `sanitize_prefix`.
String? prefixError(String raw) {
  if (raw.isEmpty) return 'must not be empty';
  if (raw.length > 64) return 'must be at most 64 characters';
  final ok = RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw);
  if (!ok) {
    return '"$raw" contains invalid characters '
        "(allowed: letters, digits, '-', '_')";
  }
  return null;
}

/// Validate and return [raw], or throw [ArgumentError] with the reason.
/// The throwing twin of [prefixError], mirroring `sanitize_prefix`'s `Result`.
String sanitizePrefix(String raw) {
  final err = prefixError(raw);
  if (err != null) throw ArgumentError.value(raw, instanceEnv, err);
  return raw;
}

/// The active instance prefix from [instanceEnv], or `null` for the default
/// (production) instance.
///
/// If the variable is set but invalid this **throws** rather than returning
/// `null`: silently falling back to the default would point an instance the
/// user intended to isolate at the production config and data, which is
/// exactly the accident this feature exists to prevent. Mirrors the deliberate
/// panic in `instance_prefix()`.
///
/// [env] defaults to the process environment; tests pass an explicit map.
String? instancePrefix({Map<String, String>? env}) {
  final raw = (env ?? Platform.environment)[instanceEnv];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return sanitizePrefix(trimmed);
}

/// Directory name for a given prefix — `axiotask`, or `axiotask-<prefix>`.
/// Pure helper, testable without the environment (port of `app_dir_name_for`).
String appDirNameFor(String? prefix) =>
    prefix == null ? appName : '$appName-$prefix';

/// Directory name for the active instance (reads [instanceEnv]).
String appDirName({Map<String, String>? env}) =>
    appDirNameFor(instancePrefix(env: env));

/// The instance's config file path rooted at [base] —
/// `base/<app-dir>/config.json`, where `<app-dir>` is instance-aware.
///
/// Split out so the layout is testable without the environment and shared by
/// both roots: desktop derives [base] from the XDG/OS config dir, mobile from
/// the platform's per-app config location — the only writable per-app config
/// location on Android, without which preferences can never save on device
/// (#170). Mirrors `config_path_in` (was TOML; JSON here).
File configPathIn(Directory base, {Map<String, String>? env}) =>
    File(p.join(base.path, appDirName(env: env), 'config.json'));

/// The instance's database path rooted at [base] —
/// `base/<app-dir>/axiotask.sqlite`. The auth `tokens.json` and `prefs.json`
/// live beside it, so isolating this directory isolates the whole instance.
/// Port of `db_path_in`.
File dbPathIn(Directory base, {Map<String, String>? env}) =>
    File(p.join(base.path, appDirName(env: env), 'axiotask.sqlite'));

/// The instance's prefs file path rooted at [base] —
/// `base/<app-dir>/prefs.json`. Lives beside the DB (a schema wipe destroys
/// the cache but never touches this file).
File prefsPathIn(Directory base, {Map<String, String>? env}) =>
    File(p.join(base.path, appDirName(env: env), 'prefs.json'));
