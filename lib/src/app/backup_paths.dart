// Backup file-path helpers — the Dart port of `state.rs`'s `default_backup_path`
// / `latest_backup_path` / `latest_backup_in`.
//
// Backups live in a timestamped file under `<data-base>/<app-dir>/backups/`,
// named `axiotask-backup-<YYYYMMDD-HHMMSS>.json` (local wall-clock time). The
// timestamp format is chosen so a plain lexicographic sort of the filenames is
// also a chronological one — which is exactly how "the newest backup" is picked
// (no timestamp parsing, just the max filename). The directory is instance-aware
// (the `AXIOTASK_PREFIX` isolation applies here too), so a dev/test instance
// keeps its own backups.
//
// Pure path/enumeration helpers: they touch the filesystem only to LIST a
// directory (`latestBackupIn`); writing and reading backups is the
// BackupService's job.

import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import 'instance.dart';

/// The instance's backups directory rooted at [base] —
/// `base/<app-dir>/backups`, where `<app-dir>` is instance-aware. Lives beside
/// the DB and prefs (a schema wipe never touches it). Port of the directory
/// `default_backup_path`/`latest_backup_path` build.
Directory backupsDirIn(Directory base, {Map<String, String>? env}) =>
    Directory(p.join(base.path, appDirName(env: env), 'backups'));

/// The timestamped backup filename for [now] (LOCAL wall-clock) —
/// `axiotask-backup-<YYYYMMDD-HHMMSS>.json`.
String backupFileName(DateTime now) => 'axiotask-backup-${_stamp(now)}.json';

/// The default target for a new export — a fresh timestamped file directly
/// inside an already-resolved backups directory [backupsDir]. [now] defaults to
/// the ambient [clock] (never `DateTime.now()` directly, per the wall-clock ban).
File defaultBackupIn(Directory backupsDir, {DateTime? now}) => File(
  p.join(backupsDir.path, backupFileName(now ?? clock.now())),
);

/// The default target for a new export rooted at the data [base] —
/// `<base>/<app-dir>/backups/axiotask-backup-<stamp>.json`. Instance-aware. It
/// is used as LOCAL wall-clock time so the stamp matches the user's timezone,
/// mirroring `jiff::Zoned::now()`.
File defaultBackupPath(Directory base, {Map<String, String>? env, DateTime? now}) =>
    defaultBackupIn(backupsDirIn(base, env: env), now: now);

/// The newest existing backup across the instance's backups dir, or `null` when
/// none exists. See [latestBackupIn] for the selection rule.
File? latestBackupPath(Directory base, {Map<String, String>? env}) =>
    latestBackupIn(backupsDirIn(base, env: env));

/// The newest backup file directly inside [dir], or `null` when [dir] is missing
/// or holds no backup. Port of `latest_backup_in`, 1:1:
///
/// * A missing/unreadable directory yields `null` (never throws).
/// * A candidate is a regular file whose name ends in `.json` (case-insensitive)
///   AND starts with the literal `axiotask-backup-`.
/// * "Newest" is the lexicographic maximum of the FILENAME — the timestamp
///   format sorts chronologically as text, so no parsing is needed.
File? latestBackupIn(Directory dir) {
  if (!dir.existsSync()) return null;
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync();
  } on FileSystemException {
    return null;
  }
  File? best;
  for (final e in entries) {
    if (e is! File) continue;
    final name = p.basename(e.path);
    final isJson = p.extension(name).toLowerCase() == '.json';
    final named = name.startsWith('axiotask-backup-');
    if (!isJson || !named) continue;
    if (best == null || name.compareTo(p.basename(best.path)) > 0) {
      best = e;
    }
  }
  return best;
}

/// Format [t] (interpreted as LOCAL time) as `YYYYMMDD-HHMMSS`.
String _stamp(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year.toString().padLeft(4, '0')}${two(l.month)}${two(l.day)}'
      '-${two(l.hour)}${two(l.minute)}${two(l.second)}';
}
