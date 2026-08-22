// The Sync activity screen's query layer (#218): `Store.recentSyncRuns`.
//
// What these protect: the screen shows a bounded, newest-first history whose
// failures are CLASSIFICATIONS, never provider text. Each test names the
// specific regression it catches — an oldest-first ORDER BY (the screen would
// open on ancient runs), a missing LIMIT (an unbounded list on a long-lived
// install), a raw error string persisted where a classification belongs, and
// the two ways a stored row can be malformed and must still render.

import 'package:axiotask/src/model/sync_run.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:clock/clock.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

/// Insert a row straight into `sync_log`, bypassing [Store.writeSyncLog] — the
/// only way to simulate a row this build did not write (a value from a future
/// or foreign build, a corrupted timestamp).
Future<void> rawRow(Store s, {required String ranAt, String? error}) =>
    s.db.customInsert(
      'INSERT INTO sync_log (ran_at, duration_ms, pulled, pushed, conflicts, '
      'error) VALUES (?, 1, 0, 0, 0, ?)',
      variables: [Variable<String>(ranAt), Variable<String>(error)],
      updates: {s.db.syncLog},
    );

void main() {
  group('recentSyncRuns', () {
    test(
      'no runs yet → an empty history (the screen\'s empty state)',
      () async {
        final s = await freshStore();
        expect(await s.recentSyncRuns(), isEmpty);
      },
    );

    test('returns runs NEWEST-FIRST, capped at the limit', () async {
      // Catches an oldest-first ORDER BY (the screen would open on the oldest
      // runs) and a missing LIMIT (unbounded growth in the rendered list).
      final s = await freshStore();
      for (var i = 0; i < 60; i++) {
        await s.writeSyncLog(pulled: i, pushed: 0, conflicts: 0, durationMs: 1);
      }

      final runs = await s.recentSyncRuns(limit: 50);
      expect(runs, hasLength(50), reason: 'the cap is enforced by the query');
      expect(
        runs.map((r) => r.pulled).toList(),
        [for (var i = 59; i >= 10; i--) i],
        reason: 'newest run first, oldest 10 dropped by the cap',
      );
    });

    test('the default cap is 50 runs', () async {
      final s = await freshStore();
      for (var i = 0; i < 51; i++) {
        await s.writeSyncLog(pulled: i, pushed: 0, conflicts: 0, durationMs: 1);
      }
      expect(await s.recentSyncRuns(), hasLength(50));
    });

    test('carries the per-run counters and a UTC timestamp', () async {
      final s = await freshStore();
      await withClock(Clock.fixed(DateTime.utc(2026, 8, 22, 21, 5)), () async {
        await s.writeSyncLog(
          pulled: 7,
          pushed: 3,
          conflicts: 2,
          durationMs: 412,
        );
      });

      final run = (await s.recentSyncRuns()).single;
      expect(run.pulled, 7);
      expect(run.pushed, 3);
      expect(run.conflicts, 2);
      expect(run.durationMs, 412);
      expect(run.ranAt, DateTime.utc(2026, 8, 22, 21, 5));
      expect(run.failure, isNull);
      expect(run.failed, isFalse);
    });

    test(
      'a failed run carries its classification, a clean one carries none',
      () async {
        final s = await freshStore();
        await s.writeSyncLog(pulled: 0, pushed: 0, conflicts: 0, durationMs: 1);
        await s.writeSyncLog(
          pulled: 0,
          pushed: 0,
          conflicts: 0,
          durationMs: 1,
          failure: SyncFailureKind.network,
        );

        final runs = await s.recentSyncRuns();
        expect(runs.first.failure, SyncFailureKind.network);
        expect(runs.last.failure, isNull);
      },
    );

    test(
      'an unrecognized stored code degrades to `unknown`, never leaks',
      () async {
        // Non-happy path: a row this build did not write (a future build's code,
        // or provider text left by an older one). It must classify as `unknown`
        // — never surface the stored string as if it were a classification.
        final s = await freshStore();
        await rawRow(
          s,
          ranAt: '2026-08-22T21:05:00.000000Z',
          error: 'SyncError.api(OtherApiError(<html>token=SECRET</html>))',
        );

        final run = (await s.recentSyncRuns()).single;
        expect(run.failure, SyncFailureKind.unknown);
        expect(syncFailureLabel(run.failure!), isNot(contains('SECRET')));
        expect(syncFailureLabel(run.failure!), isNot(contains('<html')));
      },
    );

    test('a run with an unparseable timestamp still comes back', () async {
      // Non-happy path: the run happened, so it belongs in the history even if
      // its stamp is garbage. Dropping the row would hide a failure.
      final s = await freshStore();
      await rawRow(s, ranAt: 'not-a-timestamp', error: 'store');

      final run = (await s.recentSyncRuns()).single;
      expect(run.ranAt, isNull);
      expect(run.failure, SyncFailureKind.store);
    });
  });

  group('SyncFailureKind.parse', () {
    test('null and empty mean "the run succeeded"', () {
      expect(SyncFailureKind.parse(null), isNull);
      expect(SyncFailureKind.parse(''), isNull);
    });

    test('every kind round-trips through its stored name', () {
      for (final k in SyncFailureKind.values) {
        expect(SyncFailureKind.parse(k.name), k);
      }
    });
  });
}
