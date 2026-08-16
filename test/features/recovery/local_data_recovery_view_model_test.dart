import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:axiotask/src/features/recovery/local_data_recovery_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('confirmed reset reports rebuilt only from Good health', () async {
    final store = _Store();
    final model = _model(store, SyncHealthOutcome.good);

    await model.loadPreview();
    await model.resetConfirmed(model.state.preview!);

    expect(store.resetCalls, 1);
    expect(model.state.outcome, LocalDataRecoveryOutcome.rebuilt);
    expect(model.state.preview!.cachedTaskCount, 0);
  });

  test(
    'unavailable Google leaves empty cache visibly rebuild-failed',
    () async {
      final store = _Store();
      final model = _model(store, SyncHealthOutcome.failed);

      await model.loadPreview();
      await model.resetConfirmed(model.state.preview!);

      expect(model.state.preview!.cachedTaskCount, 0);
      expect(model.state.outcome, LocalDataRecoveryOutcome.rebuildFailed);
    },
  );

  test(
    'transaction failure retains preview and reports reset failure',
    () async {
      final store = _Store()..failReset = true;
      final model = _model(store, SyncHealthOutcome.good);

      await model.loadPreview();
      await model.resetConfirmed(model.state.preview!);

      expect(model.state.preview!.cachedTaskCount, 3);
      expect(model.state.outcome, LocalDataRecoveryOutcome.resetFailed);
    },
  );
}

LocalDataRecoveryViewModel _model(_Store store, SyncHealthOutcome health) {
  final service = LocalDataRecoveryService(
    store: store,
    synchronization: _Synchronization(),
  );
  return LocalDataRecoveryViewModel(
    accountId: const AccountId(1),
    recovery: service,
    healthRepository: _Health(health),
  );
}

final class _Store implements LocalDataResetStore {
  var resetCalls = 0;
  var reset = false;
  var failReset = false;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async =>
      LocalDataResetPreview(
        accountId: accountId,
        cachedListCount: reset ? 0 : 1,
        cachedTaskCount: reset ? 0 : 3,
        pendingChangeCount: reset ? 0 : 2,
        uncertainChangeCount: reset ? 0 : 1,
        undoRecordCount: reset ? 0 : 1,
        accountPreferenceCount: reset ? 0 : 2,
        syncHistoryCount: reset ? 0 : 4,
        importManifestCount: reset ? 0 : 1,
      );

  @override
  Future<void> resetPartition(AccountId accountId) async {
    resetCalls += 1;
    if (failReset) throw StateError('synthetic transaction failure');
    reset = true;
  }
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
