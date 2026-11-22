import 'package:axiotask/src/app/composition/app_composition.dart';
import 'package:axiotask/src/app/composition/synthetic_read_transport.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/repository/sync_activity_repository.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// Account settings restored from v1.5.3: sign-out keeps local data, account
/// switching removes it, and the two startup/sync device settings change
/// what the real coordinator and engine do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TasksFeatureRuntime> open(
    AppComposition composition, {
    AppDatabase? database,
    InMemoryDevicePreferencesBackend? preferences,
  }) => TasksFeatureRuntime.open(
    composition,
    injectedDatabase: database ?? AppDatabase.inMemory(),
    injectedDevicePreferencesBackend:
        preferences ?? InMemoryDevicePreferencesBackend(),
  );

  Future<SyncHealth> health(TasksFeatureRuntime runtime) => runtime
      .syncHealthRepository!
      .watchHealth(runtime.viewModel.accountId)
      .first;

  Future<List<SyncRunRecord>> runs(TasksFeatureRuntime runtime) => runtime
      .syncActivityRepository!
      .watchRecentRuns(runtime.viewModel.accountId)
      .first;

  Future<int> rows(AppDatabase database, String table) async =>
      (await database
              .customSelect('SELECT COUNT(*) AS c FROM $table')
              .getSingle())
          .read<int>('c');

  test('sign-out stops synchronization and keeps every local row', () async {
    final runtime = await open(TestComposition.create(instanceId: 'sign-out'));
    addTearDown(runtime.close);
    await runtime.start();
    expect((await health(runtime)).outcome, SyncHealthOutcome.good);
    final tasksBefore = await rows(runtime.database, 'tasks');
    expect(tasksBefore, greaterThan(0));

    final outcome = await runtime.accountSession!.signOut();

    expect(outcome, isA<Success<void>>());
    final signedOut = await health(runtime);
    expect(signedOut.outcome, SyncHealthOutcome.inactive);
    expect(signedOut.inactiveReason, SyncInactiveReason.noAuthorization);
    expect(await rows(runtime.database, 'tasks'), tasksBefore);
    expect(await runtime.database.allAccounts(), hasLength(1));

    // No trigger may start a run while signed out.
    final runsBefore = (await runs(runtime)).length;
    await runtime.coordinator!.refresh();
    await runtime.coordinator!.localEditCommitted();
    await runtime.coordinator!.whenIdle;
    expect((await runs(runtime)).length, runsBefore);

    // Signing in again with the same account resumes synchronization.
    await runtime.coordinator!.reauthorize();
    await runtime.coordinator!.whenIdle;
    expect((await health(runtime)).outcome, SyncHealthOutcome.good);
    expect((await runs(runtime)).length, runsBefore + 1);
  });

  test('a failed credential removal leaves the account signed in', () async {
    final runtime = await open(
      _Composition(
        TestComposition.create(instanceId: 'sign-out-fails'),
        authorization: (subject) => _FailingSignOut(subject),
      ),
    );
    addTearDown(runtime.close);
    await runtime.start();

    final outcome = await runtime.accountSession!.signOut();

    expect(outcome, isA<Failed<void>>());
    expect((await health(runtime)).outcome, SyncHealthOutcome.good);
    final runsBefore = (await runs(runtime)).length;
    await runtime.coordinator!.refresh();
    expect((await runs(runtime)).length, runsBefore + 1);

    // Switching must not delete data it could not sign out of.
    final switched = await runtime.accountSession!.switchAccount();
    expect(switched, isA<Failed<void>>());
    expect(await runtime.database.allAccounts(), hasLength(1));
  });

  test('an adapter without sign-out reports that honestly', () async {
    final runtime = await open(
      _Composition(
        TestComposition.create(instanceId: 'sign-out-unsupported'),
        authorization: (subject) => _NoSignOut(subject),
      ),
    );
    addTearDown(runtime.close);
    await runtime.start();

    final outcome = await runtime.accountSession!.signOut();

    expect((outcome as Failed<void>).failure.code, 'auth.sign_out_unavailable');
    expect((await health(runtime)).outcome, SyncHealthOutcome.good);
  });

  test(
    'switch account removes the whole local partition and asks to reopen',
    () async {
      final runtime = await open(TestComposition.create(instanceId: 'switch'));
      addTearDown(runtime.close);
      await runtime.start();
      expect(await rows(runtime.database, 'tasks'), greaterThan(0));
      var reloadRequested = false;
      runtime.reloadRequested!.then((_) => reloadRequested = true).ignore();

      final outcome = await runtime.accountSession!.switchAccount();
      await pumpEventQueue();

      expect(outcome, isA<Success<void>>());
      expect(reloadRequested, isTrue);
      expect(await runtime.database.allAccounts(), isEmpty);
      for (final table in <String>[
        'tasks',
        'task_lists',
        'desired_states',
        'sync_runs',
        'sync_facts',
        'account_preferences',
      ]) {
        expect(await rows(runtime.database, table), 0, reason: table);
      }
    },
  );

  test('auto-sync on startup off starts no run until asked', () async {
    final composition = TestComposition.create(instanceId: 'no-startup-sync');
    final preferences = InMemoryDevicePreferencesBackend();
    await preferences.writeBool(
      '${composition.boundary.storage.preferencesNamespace}'
      '.auto_sync_on_startup',
      false,
    );
    final runtime = await open(composition, preferences: preferences);
    addTearDown(runtime.close);

    await runtime.start();
    await runtime.coordinator!.whenIdle;

    expect(await runs(runtime), isEmpty);
    expect(await rows(runtime.database, 'tasks'), 0);

    await runtime.coordinator!.refresh();
    final afterRefresh = await runs(runtime);
    expect(afterRefresh.single.state, SyncRunRecordState.succeeded);
    expect(afterRefresh.single.triggers, <String>['refresh']);
    expect(await rows(runtime.database, 'tasks'), greaterThan(0));
  });

  test('auto-sync on startup on (the default) runs at start', () async {
    final runtime = await open(TestComposition.create(instanceId: 'startup'));
    addTearDown(runtime.close);
    await runtime.start();
    final recorded = await runs(runtime);
    expect(recorded.single.triggers, <String>['startup']);
    expect(recorded.single.state, SyncRunRecordState.succeeded);
    expect(recorded.single.finishedAt, isNotNull);
  });
}

/// A [TestComposition] whose transport uses a different authorization.
final class _Composition implements AppComposition {
  _Composition(
    this._delegate, {
    required AuthorizationPort Function(AccountSubject subject) authorization,
  }) : _transportAuthorization = authorization;

  final TestComposition _delegate;
  final AuthorizationPort Function(AccountSubject subject)
  _transportAuthorization;

  @override
  AccountGuard get accountGuard => _delegate.accountGuard;

  @override
  AuthorizationPort get authorization => _delegate.authorization;

  @override
  CompositionBoundary get boundary => _delegate.boundary;

  @override
  Clock get clock => _delegate.clock;

  @override
  AccountSubject? get configuredAccountSubject =>
      _delegate.configuredAccountSubject;

  @override
  DiagnosticSink get diagnostics => _delegate.diagnostics;

  @override
  RandomSource get randomness => _delegate.randomness;

  @override
  MonotonicScheduler get scheduler => _delegate.scheduler;

  @override
  Future<ReadSliceTransport> createReadTransport(
    AccountSubject? subject,
  ) async {
    final selected = subject ?? _delegate.authorization.subject;
    final synthetic = createSyntheticReadTransport(selected);
    return ReadSliceTransport(
      authorization: _transportAuthorization(selected),
      googleTasks: synthetic.googleTasks,
    );
  }
}

base class _NoSignOut implements AuthorizationPort {
  const _NoSignOut(this.subject);

  final AccountSubject subject;

  @override
  AuthorizationState get currentState => TasksAuthorized(subject);

  @override
  Stream<AuthorizationState> get states =>
      Stream<AuthorizationState>.value(currentState);

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      Outcome<AccountSubject>.success(subject);
}

final class _FailingSignOut extends _NoSignOut implements SignOutAuthorization {
  const _FailingSignOut(super.subject);

  @override
  Future<Outcome<void>> signOut() async => const Outcome<void>.failure(
    Failure(
      code: 'synthetic.sign_out_failed',
      category: FailureCategory.authorization,
      operation: FailureOperation.authorize,
      retry: RetryClassification.unknown,
      impact: 'Synthetic sign-out failure.',
      safeSummary: 'Synthetic sign-out failure.',
    ),
  );
}
