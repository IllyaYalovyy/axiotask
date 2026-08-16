import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PAR-DATA-003 preview is read-only and reset requires confirmation',
    () async {
      final store = _Store();
      final synchronization = _Synchronization();
      final service = LocalDataRecoveryService(
        store: store,
        synchronization: synchronization,
      );

      final preview = await service.preview(const AccountId(7));

      expect(preview.accountId, const AccountId(7));
      expect(preview.cachedListCount, 2);
      expect(preview.cachedTaskCount, 5);
      expect(store.resetCalls, 0);
      expect(synchronization.calls, 0);

      await expectLater(
        service.reset(
          confirmation: LocalDataResetConfirmation(
            accountId: const AccountId(8),
            preview: preview,
          ),
        ),
        throwsA(
          isA<LocalDataRecoveryException>().having(
            (error) => error.code,
            'code',
            'confirmation_account_mismatch',
          ),
        ),
      );
      expect(store.resetCalls, 0);

      await service.reset(
        confirmation: LocalDataResetConfirmation(
          accountId: const AccountId(7),
          preview: preview,
        ),
      );

      expect(store.resetCalls, 1);
      expect(synchronization.calls, 1);
      expect(synchronization.events, <String>['serialize', 'reset', 'rebuild']);
    },
  );

  test('transaction failure is surfaced and rebuild is not started', () async {
    final store = _Store()..failReset = true;
    final synchronization = _Synchronization();
    final service = LocalDataRecoveryService(
      store: store,
      synchronization: synchronization,
    );
    final preview = await service.preview(const AccountId(7));

    await expectLater(
      service.reset(
        confirmation: LocalDataResetConfirmation(
          accountId: const AccountId(7),
          preview: preview,
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(synchronization.events, <String>['serialize', 'reset']);
  });
}

final class _Store implements LocalDataResetStore {
  var resetCalls = 0;
  var failReset = false;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async =>
      LocalDataResetPreview(
        accountId: accountId,
        cachedListCount: 2,
        cachedTaskCount: 5,
        pendingChangeCount: 3,
        uncertainChangeCount: 1,
        undoRecordCount: 2,
        accountPreferenceCount: 4,
        syncHistoryCount: 6,
        importManifestCount: 1,
      );

  @override
  Future<void> resetPartition(AccountId accountId) async {
    resetCalls += 1;
    if (failReset) throw StateError('synthetic reset failure');
  }
}

final class _Synchronization implements LocalDataResetSynchronization {
  var calls = 0;
  final events = <String>[];

  @override
  Future<void> serializeResetAndRebuild(Future<void> Function() reset) async {
    calls += 1;
    events.add('serialize');
    events.add('reset');
    await reset();
    events.add('rebuild');
  }
}
