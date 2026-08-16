import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('explicit warning and cancellation perform no reset', (
    tester,
  ) async {
    final store = _Store();
    final model = _model(store, SyncHealthOutcome.good);
    await model.loadPreview();
    await tester.pumpWidget(
      MaterialApp(home: LocalDataRecoveryView(viewModel: model)),
    );

    expect(find.text('Reset Local Data'), findsOneWidget);
    expect(find.textContaining('Authorization and theme'), findsOneWidget);
    expect(find.textContaining('5 sync records'), findsOneWidget);
    await tester.tap(find.text('Reset Local Data'));
    await tester.pumpAndSettle();

    expect(find.text('Reset local data?'), findsOneWidget);
    expect(find.textContaining('cannot be recalled'), findsOneWidget);
    expect(find.textContaining('sync will remain non-green'), findsOneWidget);
    expect(store.resetCalls, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.resetCalls, 0);
  });

  testWidgets('confirmation shows truthful failed rebuild outcome', (
    tester,
  ) async {
    final store = _Store();
    final model = _model(store, SyncHealthOutcome.failed);
    await model.loadPreview();
    await tester.pumpWidget(
      MaterialApp(home: LocalDataRecoveryView(viewModel: model)),
    );

    await tester.tap(find.text('Reset Local Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset and rebuild'));
    await tester.pumpAndSettle();

    expect(store.resetCalls, 1);
    expect(find.text('Local data reset; rebuild unavailable'), findsOneWidget);
    expect(find.textContaining('cache is empty'), findsOneWidget);
  });
}

LocalDataRecoveryViewModel _model(_Store store, SyncHealthOutcome health) =>
    LocalDataRecoveryViewModel(
      accountId: const AccountId(1),
      recovery: LocalDataRecoveryService(
        store: store,
        synchronization: _Synchronization(),
      ),
      healthRepository: _Health(health),
    );

final class _Store implements LocalDataResetStore {
  var resetCalls = 0;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async =>
      LocalDataResetPreview(
        accountId: accountId,
        cachedListCount: resetCalls == 0 ? 2 : 0,
        cachedTaskCount: resetCalls == 0 ? 7 : 0,
        pendingChangeCount: resetCalls == 0 ? 2 : 0,
        uncertainChangeCount: resetCalls == 0 ? 1 : 0,
        undoRecordCount: resetCalls == 0 ? 1 : 0,
        accountPreferenceCount: resetCalls == 0 ? 3 : 0,
        syncHistoryCount: resetCalls == 0 ? 5 : 0,
        importManifestCount: resetCalls == 0 ? 1 : 0,
      );

  @override
  Future<void> resetPartition(AccountId accountId) async => resetCalls += 1;
}

final class _Synchronization implements LocalDataResetSynchronization {
  @override
  Future<void> serializeResetAndRebuild(Future<void> Function() reset) =>
      reset();
}

final class _Health implements SyncHealthRepository {
  const _Health(this.outcome);

  final SyncHealthOutcome outcome;

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: outcome,
      failureReason: outcome == SyncHealthOutcome.failed
          ? SyncFailureReason.noConnection
          : null,
      action: outcome == SyncHealthOutcome.failed
          ? SyncHealthAction.retry
          : SyncHealthAction.none,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: outcome == SyncHealthOutcome.good
          ? DateTime.utc(2026, 8, 16)
          : null,
      evaluatedAt: DateTime.utc(2026, 8, 16),
    ),
  );
}
