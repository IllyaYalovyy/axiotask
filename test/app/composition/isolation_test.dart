import 'package:axiotask/src/app/composition/app_composition.dart';
import 'package:axiotask/src/app/composition/development_composition.dart';
import 'package:axiotask/src/app/composition/local_data_reset_isolation.dart';
import 'package:axiotask/src/app/composition/release_composition.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/recovery/local_data_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('development and test boundaries do not overlap normal local state', () {
    final release = ReleaseComposition.create();
    final development = DevelopmentComposition.create(
      expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
    );
    final synthetic = TestComposition.create(instanceId: 'isolation-test');

    expect(
      development.boundary.verifyIsolatedFrom(release.boundary),
      isA<Success<void>>(),
    );
    expect(
      synthetic.boundary.verifyIsolatedFrom(release.boundary),
      isA<Success<void>>(),
    );

    expect(
      development.boundary.storage.databaseName,
      isNot(release.boundary.storage.databaseName),
    );
    expect(
      development.boundary.storage.preferencesNamespace,
      isNot(release.boundary.storage.preferencesNamespace),
    );
    expect(
      development.boundary.storage.secureStorageNamespace,
      isNot(release.boundary.storage.secureStorageNamespace),
    );
    expect(
      development.boundary.oauthConfiguration,
      isNot(release.boundary.oauthConfiguration),
    );
    expect(
      development.boundary.storage.diagnosticsNamespace,
      isNot(release.boundary.storage.diagnosticsNamespace),
    );
  });

  test('namespaced instances cannot read or mutate normal local state', () {
    final release = ReleaseComposition.create();
    final development = DevelopmentComposition.create(
      expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
    );
    final synthetic = TestComposition.create(instanceId: 'parallel-run');
    final store = _PartitionedProbeStore();

    store.write(release.boundary.storage.databaseName, 'normal database value');
    store.write(
      release.boundary.storage.preferencesNamespace,
      'normal preference value',
    );
    store.write(
      release.boundary.storage.secureStorageNamespace,
      'normal secure value',
    );

    for (final boundary in <StorageBoundary>[
      development.boundary.storage,
      synthetic.boundary.storage,
    ]) {
      for (final namespace in <String>[
        boundary.databaseName,
        boundary.preferencesNamespace,
        boundary.secureStorageNamespace,
      ]) {
        expect(store.read(namespace), isNull);
        store.write(namespace, 'isolated value');
      }
    }

    expect(
      store.read(release.boundary.storage.databaseName),
      'normal database value',
    );
    expect(
      store.read(release.boundary.storage.preferencesNamespace),
      'normal preference value',
    );
    expect(
      store.read(release.boundary.storage.secureStorageNamespace),
      'normal secure value',
    );
  });

  test('dedicated account guard fails closed before Google data access', () {
    const normalSubject = AccountSubject('normal-subject');
    const dedicatedSubject = AccountSubject('dedicated-subject');
    final development = DevelopmentComposition.create(
      expectedDedicatedSubject: dedicatedSubject,
    );
    final google = _GuardedGoogleProbe(
      guard: development.accountGuard,
      valuesBySubject: <AccountSubject, List<String>>{
        normalSubject: <String>['normal task'],
        dedicatedSubject: <String>['synthetic dedicated task'],
      },
    );

    expect(google.read(normalSubject), isA<Failed<List<String>>>());
    expect(google.write(normalSubject, 'must not write'), isA<Failed<void>>());
    final dedicatedRead = google.read(dedicatedSubject);
    expect(dedicatedRead, isA<Success<List<String>>>());
    expect((dedicatedRead as Success<List<String>>).value, <String>[
      'synthetic dedicated task',
    ]);
    expect(
      google.write(dedicatedSubject, 'new synthetic task'),
      isA<Success<void>>(),
    );
    expect(google.valuesBySubject[normalSubject], <String>['normal task']);
  });

  test('missing dedicated account setup rejects every subject', () {
    final development = DevelopmentComposition.create();

    expect(
      development.accountGuard.verify(const AccountSubject('any-subject')),
      isA<Failed<void>>(),
    );
  });

  test(
    'development destructive reset requires exact isolated root and subject',
    () async {
      final development = DevelopmentComposition.create(
        expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
      );
      final delegate = _ResetStore();
      final isolated = DevelopmentIsolatedLocalDataResetStore(
        delegate: delegate,
        boundary: development.boundary,
        explicitDatabaseName: development.boundary.storage.databaseName,
        accountGuard: development.accountGuard,
        subject: const AccountSubject('dedicated-subject'),
      );

      await isolated.resetPartition(const AccountId(1));
      expect(delegate.resetCalls, 1);

      expect(
        () => DevelopmentIsolatedLocalDataResetStore(
          delegate: delegate,
          boundary: ReleaseComposition.create().boundary,
          explicitDatabaseName: development.boundary.storage.databaseName,
          accountGuard: development.accountGuard,
          subject: const AccountSubject('dedicated-subject'),
        ),
        throwsA(isA<LocalDataRecoveryException>()),
      );

      final wrongSubject = DevelopmentIsolatedLocalDataResetStore(
        delegate: delegate,
        boundary: development.boundary,
        explicitDatabaseName: development.boundary.storage.databaseName,
        accountGuard: development.accountGuard,
        subject: const AccountSubject('normal-subject'),
      );
      await expectLater(
        wrongSubject.resetPartition(const AccountId(1)),
        throwsA(isA<LocalDataRecoveryException>()),
      );
      expect(delegate.resetCalls, 1);
    },
  );
}

final class _ResetStore implements LocalDataResetStore {
  var resetCalls = 0;

  @override
  Future<LocalDataResetPreview> preview(AccountId accountId) async =>
      LocalDataResetPreview(
        accountId: accountId,
        cachedListCount: 0,
        cachedTaskCount: 0,
        pendingChangeCount: 0,
        uncertainChangeCount: 0,
        undoRecordCount: 0,
        accountPreferenceCount: 0,
        syncHistoryCount: 0,
        importManifestCount: 0,
      );

  @override
  Future<void> resetPartition(AccountId accountId) async => resetCalls += 1;
}

final class _PartitionedProbeStore {
  final Map<String, String> _values = <String, String>{};

  String? read(String namespace) => _values[namespace];

  void write(String namespace, String value) {
    _values[namespace] = value;
  }
}

final class _GuardedGoogleProbe {
  _GuardedGoogleProbe({required this.guard, required this.valuesBySubject});

  final AccountGuard guard;
  final Map<AccountSubject, List<String>> valuesBySubject;

  Outcome<List<String>> read(AccountSubject subject) {
    final access = guard.verify(subject);
    if (access case Failed<void>(:final failure)) {
      return Outcome<List<String>>.failure(failure);
    }
    return Outcome<List<String>>.success(
      List<String>.unmodifiable(valuesBySubject[subject] ?? <String>[]),
    );
  }

  Outcome<void> write(AccountSubject subject, String value) {
    final access = guard.verify(subject);
    if (access case Failed<void>(:final failure)) {
      return Outcome<void>.failure(failure);
    }
    valuesBySubject.putIfAbsent(subject, () => <String>[]).add(value);
    return const Outcome<void>.success(null);
  }
}
