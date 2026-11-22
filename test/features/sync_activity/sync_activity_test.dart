import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/sync_activity_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/sync_activity_repository.dart';
import 'package:axiotask/src/features/sync_activity/sync_activity_view.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The per-run sync activity history restored from v1.5.3.
void main() {
  test(
    'runs are projected newest first with trigger, result and timing',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final accountId = AccountId(await database.createAccount('activity'));
      final other = AccountId(await database.createAccount('other-account'));
      final first = DateTime.utc(2026, 11, 21, 10);
      Future<void> record(
        AccountId account,
        String runId,
        String triggersJson,
        String state,
        DateTime startedAt, {
        DateTime? finishedAt,
      }) => database
          .into(database.syncRunRows)
          .insert(
            SyncRunRowsCompanion.insert(
              accountId: account.value,
              runId: runId,
              triggersJson: triggersJson,
              state: state,
              startedAt: startedAt,
              finishedAt: Value<DateTime?>(finishedAt),
            ),
          );

      await record(
        accountId,
        'run-1',
        '["startup"]',
        'succeeded',
        first,
        finishedAt: first.add(const Duration(seconds: 4)),
      );
      await record(
        accountId,
        'run-2',
        '["local_edit","refresh"]',
        'in_progress',
        first.add(const Duration(minutes: 5)),
      );
      await record(other, 'foreign', '["startup"]', 'in_progress', first);

      final runs = await DatabaseSyncActivityRepository(database)
          .watchRecentRuns(accountId)
          .first;

      expect(runs, hasLength(2), reason: 'Another account is never shown');
      expect(runs[0].state, SyncRunRecordState.inProgress);
      expect(runs[0].triggers, <String>['local_edit', 'refresh']);
      expect(runs[0].duration, isNull);
      expect(runs[1].state, SyncRunRecordState.succeeded);
      expect(runs[1].triggers, <String>['startup']);
      expect(runs[1].duration, const Duration(seconds: 4));

      final limited = await DatabaseSyncActivityRepository(database)
          .watchRecentRuns(accountId, limit: 1)
          .first;
      expect(limited.single.triggers, <String>['local_edit', 'refresh']);
    },
  );

  test('trigger names read as what the user did', () {
    expect(syncRunTriggerLabel(<String>['startup']), 'App start');
    expect(
      syncRunTriggerLabel(<String>['local_edit', 'refresh']),
      'Local change, Refresh',
    );
    expect(syncRunTriggerLabel(<String>[]), 'Sync');
    expect(syncRunTriggerLabel(<String>['future_trigger']), 'Sync');
  });

  testWidgets('each run shows its result; a failure shows only its code', (
    tester,
  ) async {
    final started = DateTime.utc(2026, 11, 21, 10);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncActivityPage(
          accountId: const AccountId(1),
          repository: _Runs(<SyncRunRecord>[
            SyncRunRecord(
              state: SyncRunRecordState.failed,
              triggers: const <String>['refresh'],
              startedAt: started,
              finishedAt: started.add(const Duration(seconds: 75)),
              failureCode: 'google.rate_limited',
            ),
            SyncRunRecord(
              state: SyncRunRecordState.succeeded,
              triggers: const <String>['startup'],
              startedAt: started.subtract(const Duration(hours: 1)),
              finishedAt: started.subtract(
                const Duration(minutes: 59, seconds: 58),
              ),
            ),
          ]),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('sync-run-0')),
        matching: find.textContaining('Failed'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Refresh · 1 min 15 s · Code google.rate_limited'),
      findsOneWidget,
    );
    expect(find.text('App start · 2 s'), findsOneWidget);
  });

  testWidgets('an empty history and a read failure are stated plainly', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SyncActivityPage(
          accountId: AccountId(1),
          repository: _Runs(<SyncRunRecord>[]),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('sync-activity-empty')), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: SyncActivityPage(
          key: UniqueKey(),
          accountId: const AccountId(1),
          repository: const _Runs(null),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('sync-activity-error')), findsOneWidget);
  });
}

final class _Runs implements SyncActivityRepository {
  const _Runs(this.runs);

  /// `null` makes the stream fail.
  final List<SyncRunRecord>? runs;

  @override
  Stream<List<SyncRunRecord>> watchRecentRuns(
    AccountId accountId, {
    int limit = 50,
  }) => runs == null
      ? Stream<List<SyncRunRecord>>.error(StateError('synthetic'))
      : Stream<List<SyncRunRecord>>.value(runs!);
}
