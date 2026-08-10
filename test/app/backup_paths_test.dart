// The two enumerated latest_backup tests (state.rs) plus the default-path shape.
// The selection rule — newest by lexicographic filename, json + name-prefixed,
// none when empty/missing — is what "Restore latest…" depends on to pick the
// right file, so these guard against a stray file being restored or a missing
// dir throwing.

import 'dart:io';

import 'package:axiotask/src/app/backup_paths.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('axiotask_backup_paths'),
  );
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('latestBackupIn', () {
    test('picks the newest by timestamped name, ignoring non-backups', () {
      for (final name in [
        'axiotask-backup-20260101-000000.json',
        'axiotask-backup-20260608-014500.json', // the expected winner
        'axiotask-backup-20260301-120000.json',
        'notes.txt', // ignored: wrong name and extension
        'axiotask-backup-old.bak', // ignored: wrong extension
      ]) {
        File(p.join(tmp.path, name)).writeAsStringSync('{}');
      }

      final latest = latestBackupIn(tmp);
      expect(latest, isNotNull);
      expect(p.basename(latest!.path), 'axiotask-backup-20260608-014500.json');
    });

    test('returns null for an empty or missing directory', () {
      expect(latestBackupIn(tmp), isNull, reason: 'empty dir');
      expect(
        latestBackupIn(Directory(p.join(tmp.path, 'does-not-exist'))),
        isNull,
        reason: 'missing dir',
      );
    });
  });

  group('defaultBackupPath', () {
    test('builds a timestamped file under <base>/axiotask/backups', () {
      final when = DateTime(2026, 6, 8, 1, 45, 0);
      final path = withClock(Clock.fixed(when), () => defaultBackupPath(tmp));
      expect(p.dirname(path.path), p.join(tmp.path, 'axiotask', 'backups'));
      expect(
        p.basename(path.path),
        'axiotask-backup-20260608-014500.json',
        reason: 'stamp is local YYYYMMDD-HHMMSS so names sort chronologically',
      );
    });

    test('a fresh default path is the latest once written', () {
      final when = DateTime(2026, 6, 8, 1, 45, 0);
      final path = withClock(Clock.fixed(when), () => defaultBackupPath(tmp));
      path.parent.createSync(recursive: true);
      path.writeAsStringSync('{}');
      final latest = latestBackupPath(tmp);
      expect(latest, isNotNull);
      expect(p.basename(latest!.path), p.basename(path.path));
    });
  });
}
