// Per-platform data/config base directories — the Flutter analog of the
// reference's platform path resolution (`dirs` on desktop, the Tauri path
// resolver on Android; #170).
//
// The instance layout (instance.dart) is rooted at these bases:
//   <dataBase>/<app-dir>/axiotask.sqlite   (+ tokens.json, prefs.json, backups)
//   <configBase>/<app-dir>/config.json
//
// Desktop (Linux) reads the XDG roots straight from the environment, so
// `XDG_DATA_HOME` overrides are honored — that is exactly how a dev/test
// instance isolates itself from the production data on this machine. Android
// has no app-writable XDG root, so its base comes from the platform via
// path_provider (the only per-app writable location on device); without it the
// store could never open on device (#170).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Desktop-Linux data root: `$XDG_DATA_HOME`, else `$HOME/.local/share`.
/// Pure over [env]/[home] so the isolation behavior is unit-testable.
Directory desktopDataBase({required Map<String, String> env, String? home}) {
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
  final h = home ?? env['HOME'] ?? '.';
  return Directory(p.join(h, '.local', 'share'));
}

/// Desktop-Linux config root: `$XDG_CONFIG_HOME`, else `$HOME/.config`.
Directory desktopConfigBase({required Map<String, String> env, String? home}) {
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return Directory(xdg);
  final h = home ?? env['HOME'] ?? '.';
  return Directory(p.join(h, '.config'));
}

/// Resolve the data base for the running platform.
Future<Directory> resolveDataBase({Map<String, String>? env}) async {
  final e = env ?? Platform.environment;
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return desktopDataBase(env: e);
  }
  // Android/iOS: the platform's per-app support directory is the only writable
  // root; the instance dir is created beneath it.
  return getApplicationSupportDirectory();
}

/// Resolve the config base for the running platform. Android has no distinct
/// config root, so it shares the app support directory with the data base.
Future<Directory> resolveConfigBase({Map<String, String>? env}) async {
  final e = env ?? Platform.environment;
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return desktopConfigBase(env: e);
  }
  return getApplicationSupportDirectory();
}
