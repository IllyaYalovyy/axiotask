import 'dart:async';
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
import 'package:axiotask/src/data/database/schema_verifier.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'CRS-012 unavailable storage shows safe Retry Open and no empty account',
    (tester) async {
      const privatePath = '/synthetic/private/account/tasks.sqlite';
      final history = InMemoryDiagnosticHistory();
      var attempts = 0;

      await tester.pumpWidget(
        AxiotaskBootstrap(
          diagnostics: ProductionDiagnosticSink(history),
          openRuntime: () async {
            attempts += 1;
            if (attempts == 1) {
              throw const FileSystemException(
                'Synthetic open failure.',
                privatePath,
              );
            }
            if (attempts == 2) {
              throw const SchemaVerificationException('integrity_check_failed');
            }
            return _FakeRuntime();
          },
        ),
      );
      await tester.pump();

      expect(find.text('Tasks unavailable'), findsOneWidget);
      expect(find.text('Retry Open'), findsOneWidget);
      expect(find.text('No cached tasks in this list'), findsNothing);
      expect(find.textContaining(privatePath), findsNothing);
      expect(find.textContaining('integrity_check_failed'), findsNothing);
      expect(
        find.bySemanticsLabel('Retry opening task storage'),
        findsOneWidget,
      );

      await tester.tap(find.text('Retry Open'));
      await tester.pump();
      expect(find.text('Tasks unavailable'), findsOneWidget);
      expect(attempts, 2);

      await tester.tap(find.text('Retry Open'));
      await tester.pump();
      await tester.pump();
      expect(attempts, 3);
      expect(find.text('Axiotask'), findsOneWidget);
      expect(find.text('Tasks unavailable'), findsNothing);

      expect(history.records, hasLength(2));
      expect(
        history.records.map((record) => record.fields['failure_code']),
        <String>['database_unavailable', 'integrity_check_failed'],
      );
      for (final record in history.records) {
        expect(record.code, 'database.open_failed');
        expect(record.renderedText, isNot(contains(privatePath)));
      }
    },
  );

  testWidgets('Retry Open cannot overlap an active reopen', (tester) async {
    final retry = Completer<AxiotaskRuntime>();
    var attempts = 0;
    await tester.pumpWidget(
      AxiotaskBootstrap(
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        openRuntime: () {
          attempts += 1;
          if (attempts == 1) {
            throw const SchemaVerificationException('database_unreadable');
          }
          return retry.future;
        },
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Retry Open'));
    await tester.pump();
    expect(find.text('Opening task storage…'), findsOneWidget);
    expect(find.text('Retry Open'), findsNothing);
    expect(attempts, 2);

    retry.complete(_FakeRuntime());
    await tester.pump();
    await tester.pump();
    expect(find.text('Axiotask'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('unreadable storage after startup replaces the task UI', (
    tester,
  ) async {
    final failedRuntime = _FakeRuntime();
    var attempts = 0;
    await tester.pumpWidget(
      AxiotaskBootstrap(
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
        openRuntime: () async {
          attempts += 1;
          return attempts == 1 ? failedRuntime : _FakeRuntime();
        },
      ),
    );
    await tester.pump();
    expect(find.text('Axiotask'), findsOneWidget);

    failedRuntime.failStorage(
      const SchemaVerificationException('database_unreadable'),
    );
    await tester.pump();
    expect(find.text('Tasks unavailable'), findsOneWidget);
    expect(find.text('No cached tasks in this list'), findsNothing);

    await tester.tap(find.text('Retry Open'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Tasks unavailable'), findsNothing);
  });

  test('startup read failure constructs no Google transport', () async {
    final database = AppDatabase.inMemory();
    await database.createAccount('synthetic-unreadable-account');
    await database.close();
    final composition = _NoTransportComposition();

    await expectLater(
      TasksFeatureRuntime.open(composition, injectedDatabase: database),
      throwsA(anything),
    );

    expect(composition.transportCreations, 0);
  });
}

final class _FakeRuntime implements AxiotaskRuntime {
  _FakeRuntime()
    : viewModel = TasksViewModel(
        accountId: const AccountId(1),
        tasksRepository: const _EmptyTasksRepository(),
        syncHealthRepository: const _InactiveHealthRepository(),
      );

  @override
  final TasksViewModel viewModel;

  final StreamController<Object> _storageFailures =
      StreamController<Object>.broadcast();

  @override
  Stream<Object> get fatalStorageFailures => _storageFailures.stream;

  void failStorage(Object error) => _storageFailures.add(error);

  @override
  Future<void> start() async {}

  @override
  Future<void> close() async {
    viewModel.dispose();
    await _storageFailures.close();
  }
}

final class _EmptyTasksRepository implements TasksRepository {
  const _EmptyTasksRepository();

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) => Stream.value(
    CachedTasksSnapshot(
      accountId: query.accountId,
      taskLists: const <CachedTaskList>[],
      tasks: const <CachedTask>[],
      completeness: CacheCompleteness.unobserved,
    ),
  );

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      const Stream<List<TaskDeleteUndo>>.empty();

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => const Stream.empty();

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      const Outcome<TaskId>.failure(_failure);

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async =>
      const Outcome<void>.failure(_failure);

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => const Outcome.failure(_failure);

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => const Outcome.failure(_failure);

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => const Outcome<TaskDeleteReceipt>.failure(_failure);

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      const Outcome<void>.failure(_failure);
}

final class _InactiveHealthRepository implements SyncHealthRepository {
  const _InactiveHealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.noAuthorization,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 8, 15),
    ),
  );
}

const _failure = Failure(
  code: 'synthetic.unavailable',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'Synthetic only.',
  safeSummary: 'Synthetic only.',
);

final class _NoTransportComposition implements AppComposition {
  final ManualClock _clock = ManualClock(DateTime.utc(2026, 8, 15));
  final ProductionDiagnosticSink _diagnostics = ProductionDiagnosticSink(
    InMemoryDiagnosticHistory(),
  );
  var transportCreations = 0;

  @override
  Clock get clock => _clock;

  @override
  MonotonicScheduler get scheduler => _clock;

  @override
  RandomSource get randomness =>
      SequenceRandomSource(List<int>.generate(32, (index) => index));

  @override
  AuthorizationPort get authorization => const SyntheticAuthorization(
    AccountSubject('synthetic-unreadable-account'),
  );

  @override
  DiagnosticSink get diagnostics => _diagnostics;

  @override
  AccountGuard get accountGuard => const DedicatedAccountGuard(
    AccountSubject('synthetic-unreadable-account'),
  );

  @override
  AccountSubject? get configuredAccountSubject => null;

  @override
  CompositionBoundary get boundary => const CompositionBoundary(
    profile: CompositionProfile.syntheticTest,
    applicationIdentifier: 'dev.axiotask.synthetic.unreadable',
    storage: StorageBoundary(
      databaseName: 'synthetic-unreadable.sqlite',
      diagnosticsFileName: 'synthetic-unreadable-diagnostics.json',
      preferencesNamespace: 'synthetic.unreadable.preferences',
      secureStorageNamespace: 'synthetic.unreadable.credentials',
      diagnosticsNamespace: 'synthetic.unreadable.diagnostics',
    ),
    oauthConfiguration: OAuthConfigurationBoundary(
      name: 'synthetic-unreadable',
      allowsRealGoogle: false,
    ),
  );

  @override
  Future<ReadSliceTransport> createReadTransport(AccountSubject subject) async {
    transportCreations += 1;
    throw StateError('Transport must not be constructed for unreadable data.');
  }
}
