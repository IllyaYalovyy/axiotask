import 'dart:io';

import 'package:axiotask/src/app/app_bootstrap.dart';
import 'package:axiotask/src/app/composition/app_composition.dart';
import 'package:axiotask/src/app/tasks_feature_runtime.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth.dart';
import '../support/fake_google_tasks_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const subject = AccountSubject('first-run-google-subject');

  test(
    'first Connect verifies identity before creating an account and Google work',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'axiotask-first-run-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/first-run.sqlite');
      var database = await AppDatabase.openFile(file);
      final initialAuthorization = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.interactiveSuccess(subject));
      final initialGoogle = FakeGoogleTasksService();
      final restoredAuthorization = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.restoreSuccess(subject));
      final restoredGoogle = FakeGoogleTasksService();
      final devicePreferences = InMemoryDevicePreferencesBackend();
      final composition = _FirstRunComposition(<_TransportPlan>[
        _TransportPlan(initialAuthorization, initialGoogle),
        _TransportPlan(restoredAuthorization, restoredGoogle),
      ]);

      var runtime = await TasksFeatureRuntime.open(
        composition,
        injectedDatabase: database,
        injectedDevicePreferencesBackend: devicePreferences,
      );
      runtime.viewModel.start();
      await pumpEventQueue();
      expect(
        runtime.viewModel.state.health.outcome,
        SyncHealthOutcome.inactive,
      );
      expect(runtime.viewModel.state.health.action, SyncHealthAction.connect);
      expect(await database.allAccounts(), isEmpty);
      expect(composition.requestedSubjects, <AccountSubject?>[null]);

      final reload = runtime.reloadRequested!;
      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);
      await reload;

      final accounts = await database.allAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.single.googleSubject, subject.value);
      expect(initialAuthorization.operationLedger, <FakeAuthorizationOperation>[
        FakeAuthorizationOperation.interactive,
      ]);
      expect(initialGoogle.calls, isEmpty);

      await runtime.close();
      database = await AppDatabase.openFile(file);
      runtime = await TasksFeatureRuntime.open(
        composition,
        injectedDatabase: database,
        injectedDevicePreferencesBackend: devicePreferences,
      );
      await runtime.start();

      expect(composition.requestedSubjects, <AccountSubject?>[null, subject]);
      expect(
        restoredAuthorization.operationLedger,
        <FakeAuthorizationOperation>[FakeAuthorizationOperation.restore],
      );
      expect(restoredGoogle.callCount(FakeGoogleTasksMethod.listTaskLists), 1);
      final health = await runtime.syncHealthRepository!
          .watchHealth(const AccountId(1))
          .first;
      expect(health.outcome, SyncHealthOutcome.good);
      await runtime.close();
    },
  );

  test('cancelled, rejected, and storage failures create no account', () async {
    for (final failure in <Failure>[
      _cancelled,
      _rejected,
      _secureStorageFailure,
    ]) {
      final database = AppDatabase.inMemory();
      final authorization = FakeAuthorization()
        ..enqueue(
          failure == _cancelled
              ? FakeAuthorizationAttempt.interactiveCancelled(failure)
              : FakeAuthorizationAttempt.interactiveRejected(failure),
        );
      final google = FakeGoogleTasksService();
      final runtime = await TasksFeatureRuntime.open(
        _FirstRunComposition(<_TransportPlan>[
          _TransportPlan(authorization, google),
        ]),
        injectedDatabase: database,
        injectedDevicePreferencesBackend: InMemoryDevicePreferencesBackend(),
      );
      runtime.viewModel.start();

      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);

      expect(await database.allAccounts(), isEmpty, reason: failure.code);
      expect(google.calls, isEmpty, reason: failure.code);
      expect(
        runtime.viewModel.state.syncControlFailureMessage,
        failure.safeSummary,
      );
      await runtime.close();
    }
  });

  test(
    'account transaction failure is visible and does not begin sync',
    () async {
      final database = AppDatabase.inMemory();
      await database.customStatement('''
      CREATE TRIGGER reject_first_account
      BEFORE INSERT ON accounts
      BEGIN
        SELECT RAISE(ABORT, 'synthetic account failure');
      END
    ''');
      final authorization = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.interactiveSuccess(subject));
      final google = FakeGoogleTasksService();
      final runtime = await TasksFeatureRuntime.open(
        _FirstRunComposition(<_TransportPlan>[
          _TransportPlan(authorization, google),
        ]),
        injectedDatabase: database,
        injectedDevicePreferencesBackend: InMemoryDevicePreferencesBackend(),
      );
      runtime.viewModel.start();

      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);

      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);
      expect(
        runtime.viewModel.state.syncControlFailureMessage,
        contains('account'),
      );
      await runtime.close();
    },
  );

  test(
    'unexpected authorization adapter failure becomes explicit Failed',
    () async {
      final database = AppDatabase.inMemory();
      final google = FakeGoogleTasksService();
      final runtime = await TasksFeatureRuntime.open(
        _FirstRunComposition(<_TransportPlan>[
          _TransportPlan(const _ThrowingAuthorization(), google),
        ]),
        injectedDatabase: database,
        injectedDevicePreferencesBackend: InMemoryDevicePreferencesBackend(),
      );
      addTearDown(runtime.close);
      runtime.viewModel.start();

      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);

      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);
      final health = await runtime.syncHealthRepository!
          .watchHealth(const AccountId(1))
          .first;
      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.applicationFailure);
      expect(
        runtime.viewModel.state.syncControlFailureMessage,
        contains('failed unexpectedly'),
      );
    },
  );

  test(
    'missing OAuth runtime configuration fails visibly and closed',
    () async {
      final database = AppDatabase.inMemory();
      final google = FakeGoogleTasksService();
      final runtime = await TasksFeatureRuntime.open(
        _FirstRunComposition(<_TransportPlan>[
          _TransportPlan(const UnavailableAuthorization(), google),
        ]),
        injectedDatabase: database,
        injectedDevicePreferencesBackend: InMemoryDevicePreferencesBackend(),
      );
      addTearDown(runtime.close);
      runtime.viewModel.start();

      await runtime.viewModel.handleSyncHealthAction(SyncHealthAction.connect);
      await pumpEventQueue();

      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);
      expect(
        runtime.viewModel.state.syncControlFailureMessage,
        'No platform authorization adapter is configured.',
      );
    },
  );

  testWidgets(
    'fresh install presents onboarding and device Settings before Connect',
    (tester) async {
      final database = AppDatabase.inMemory();
      final preferences = InMemoryDevicePreferencesBackend();
      final authorization = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.interactiveSuccess(subject));
      final google = FakeGoogleTasksService();
      final composition = _FirstRunComposition(<_TransportPlan>[
        _TransportPlan(authorization, google),
      ]);

      await tester.pumpWidget(
        AxiotaskBootstrap(
          diagnostics: composition.diagnostics,
          openRuntime: () => TasksFeatureRuntime.open(
            composition,
            injectedDatabase: database,
            injectedDevicePreferencesBackend: preferences,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Welcome to Axiotask'), findsOneWidget);
      expect(find.text('Connect to Google Tasks'), findsOneWidget);
      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);

      await tester.ensureVisible(find.text('Start using Axiotask'));
      await tester.tap(find.text('Start using Axiotask'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Axiotask'), findsNothing);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      await tester.tap(find.byKey(const Key('settings-theme-dark')));
      await tester.pumpAndSettle();
      expect(
        preferences.values['first-run.preferences.theme'],
        ThemePreference.dark.name,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Connect'), findsOneWidget);
      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'failed fresh-install dismissal is nonblocking and leaves Connect usable',
    (tester) async {
      final database = AppDatabase.inMemory();
      final preferences = InMemoryDevicePreferencesBackend()..failWrites = true;
      final authorization = FakeAuthorization()
        ..enqueue(FakeAuthorizationAttempt.interactiveSuccess(subject));
      final google = FakeGoogleTasksService();
      final composition = _FirstRunComposition(<_TransportPlan>[
        _TransportPlan(authorization, google),
      ]);

      await tester.pumpWidget(
        AxiotaskBootstrap(
          diagnostics: composition.diagnostics,
          openRuntime: () => TasksFeatureRuntime.open(
            composition,
            injectedDatabase: database,
            injectedDevicePreferencesBackend: preferences,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.ensureVisible(find.text('Start using Axiotask'));
      await tester.tap(find.text('Start using Axiotask'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to Axiotask'), findsNothing);
      expect(find.byKey(const Key('onboarding-persistence-notice')), findsOne);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(await database.allAccounts(), isEmpty);
      expect(google.calls, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

final class _TransportPlan {
  const _TransportPlan(this.authorization, this.googleTasks);

  final AuthorizationPort authorization;
  final GoogleTasksService googleTasks;
}

final class _ThrowingAuthorization implements AuthorizationPort {
  const _ThrowingAuthorization();

  @override
  AuthorizationState get currentState => const NoTasksAuthorization();

  @override
  Stream<AuthorizationState> get states => const Stream.empty();

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() =>
      Future<Outcome<AccountSubject>>.error(StateError('synthetic failure'));

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() =>
      throw UnimplementedError();

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() =>
      throw UnimplementedError();
}

final class _FirstRunComposition implements AppComposition {
  _FirstRunComposition(this._plans);

  final List<_TransportPlan> _plans;
  final List<AccountSubject?> requestedSubjects = <AccountSubject?>[];
  final ManualClock _clock = ManualClock(DateTime.utc(2026, 8, 20, 12));
  final ProductionDiagnosticSink _diagnostics = ProductionDiagnosticSink(
    InMemoryDiagnosticHistory(),
  );

  @override
  Clock get clock => _clock;

  @override
  MonotonicScheduler get scheduler => _clock;

  @override
  RandomSource get randomness =>
      SequenceRandomSource(List<int>.generate(1024, (index) => index % 251));

  @override
  AuthorizationPort get authorization => const UnavailableAuthorization();

  @override
  DiagnosticSink get diagnostics => _diagnostics;

  @override
  AccountGuard get accountGuard => const NormalAccountGuard();

  @override
  AccountSubject? get configuredAccountSubject => null;

  @override
  CompositionBoundary get boundary => const CompositionBoundary(
    profile: CompositionProfile.release,
    applicationIdentifier: 'dev.axiotask.first-run-test',
    storage: StorageBoundary(
      databaseName: 'first-run.sqlite',
      diagnosticsFileName: 'first-run-diagnostics.json',
      preferencesNamespace: 'first-run.preferences',
      secureStorageNamespace: 'first-run.credentials',
      diagnosticsNamespace: 'first-run.diagnostics',
    ),
    oauthConfiguration: OAuthConfigurationBoundary(
      name: 'first-run-test',
      allowsRealGoogle: false,
    ),
  );

  @override
  Future<ReadSliceTransport> createReadTransport(
    AccountSubject? subject,
  ) async {
    requestedSubjects.add(subject);
    final plan = _plans.removeAt(0);
    return ReadSliceTransport(
      authorization: plan.authorization,
      googleTasks: plan.googleTasks,
      closeTransport: switch (plan.authorization) {
        final FakeAuthorization fake => fake.close,
        _ => null,
      },
    );
  }
}

const _cancelled = Failure(
  code: 'auth.cancelled',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks was not connected.',
  action: FailureAction.connect,
  safeSummary: 'Authorization was cancelled.',
);

const _rejected = Failure(
  code: 'auth.rejected',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Google Tasks was not connected.',
  action: FailureAction.connect,
  safeSummary: 'Google rejected Tasks authorization.',
);

const _secureStorageFailure = Failure(
  code: 'auth.secure_store_failed',
  category: FailureCategory.authorization,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'Google authorization was not stored.',
  action: FailureAction.retry,
  safeSummary: 'Secure credential storage failed.',
);
