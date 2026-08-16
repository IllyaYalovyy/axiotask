import 'dart:async';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/sync_health_repository.dart';
import 'package:axiotask/src/data/database/sync_settings_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/coordinator/sync_coordinator.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth.dart';
import '../support/fake_clock.dart';
import '../support/fake_lifecycle.dart';
import '../support/fake_random.dart';

void main() {
  const subject = AccountSubject('synthetic-foreground-read-subject');
  final now = DateTime.utc(2026, 8, 15, 12);

  test(
    'RUN-005 warm startup stays Pending until authorization and full verification',
    () async {
      final authorization = _DelayedAuthorization(subject);
      final harness = await _Harness.create(
        authorization: authorization,
        now: now,
        priorSuccess: now.subtract(const Duration(minutes: 1)),
      );
      addTearDown(harness.close);

      final run = harness.coordinator.start();
      await pumpEventQueue();

      expect(
        harness.coordinator.currentFacts.authorization,
        SyncAuthorization.refreshing,
      );
      expect(harness.coordinator.currentFacts.verificationRequired, isTrue);
      expect(harness.remote.listCalls, 0);
      authorization.completeRestore();
      await run;

      expect(harness.remote.listCalls, 1);
      expect((await harness.health()).outcome, SyncHealthOutcome.good);
    },
  );

  test('resume and Refresh each request foreground verification', () async {
    final lifecycle = FakeLifecycle();
    final harness = await _Harness.create(
      authorization: const SyntheticAuthorization(subject),
      now: now,
      lifecycle: lifecycle,
    );
    addTearDown(harness.close);
    addTearDown(lifecycle.close);

    await harness.coordinator.start();
    expect(harness.remote.listCalls, 1);

    await harness.coordinator.refresh();
    expect(harness.remote.listCalls, 2);

    lifecycle.enterBackground();
    lifecycle.acknowledgeCancellation();
    lifecycle.enterForeground();
    await harness.coordinator.whenIdle;
    expect(harness.remote.listCalls, 3);
  });

  test(
    'HLT-006 trigger during a run queues one follow-up without a Good emission',
    () async {
      final remote = _ScriptedReadService(blockFirstList: true);
      final harness = await _Harness.create(
        authorization: const SyntheticAuthorization(subject),
        now: now,
        remote: remote,
      );
      addTearDown(harness.close);
      final outcomes = <SyncHealthOutcome>[];
      final subscription = harness.watchHealth().listen(
        (health) => outcomes.add(health.outcome),
      );
      addTearDown(subscription.cancel);

      final startup = harness.coordinator.start();
      await remote.firstListRequested;
      final refresh = harness.coordinator.refresh();
      remote.releaseFirstList();
      await Future.wait(<Future<void>>[startup, refresh]);

      expect(remote.listCalls, 2);
      expect(
        outcomes.where((outcome) => outcome == SyncHealthOutcome.good),
        hasLength(1),
      );
      expect(outcomes.last, SyncHealthOutcome.good);
    },
  );

  test(
    'HLT-007 partial data failure retains old success and cache under Failed',
    () async {
      final remote = _ScriptedReadService(failTasksAfterList: true);
      final priorSuccess = now.subtract(const Duration(minutes: 2));
      final harness = await _Harness.create(
        authorization: const SyntheticAuthorization(subject),
        now: now,
        priorSuccess: priorSuccess,
        remote: remote,
      );
      addTearDown(harness.close);

      await harness.coordinator.start();

      final facts = await SyncHealthDao(
        harness.database,
      ).watchFacts(harness.accountId).first;
      final health = await harness.health();
      expect(facts.lastSuccessfulSyncAt, priorSuccess);
      expect(facts.requiredScopeIncomplete, isTrue);
      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.noConnection);
    },
  );

  test(
    'REL-005 deadline cancellation finalizes durable Failed facts',
    () async {
      final remote = _ScriptedReadService(blockFirstList: true);
      final harness = await _Harness.create(
        authorization: const SyntheticAuthorization(subject),
        now: now,
        remote: remote,
      );
      addTearDown(harness.close);

      final startup = harness.coordinator.start();
      await remote.firstListRequested;
      harness.clock.advance(
        const Duration(minutes: 1, seconds: 59, milliseconds: 999),
      );
      expect(harness.coordinator.currentFacts.detectedFailureReason, isNull);

      harness.clock.advance(const Duration(milliseconds: 1));
      expect(
        harness.coordinator.currentFacts.detectedFailureReason,
        SyncFailureReason.remoteFailure,
      );
      remote.releaseFirstList();
      await startup;

      final facts = await SyncHealthDao(
        harness.database,
      ).watchFacts(harness.accountId).first;
      expect(facts.latestFailure?.diagnosticCode, 'sync.run_timeout');
      expect((await harness.health()).outcome, SyncHealthOutcome.failed);
    },
  );

  test(
    'RUN-009 Stop aborts an active read and persists Inactive without cache loss',
    () async {
      final remote = _ScriptedReadService(blockFirstList: true);
      final harness = await _Harness.create(
        authorization: const SyntheticAuthorization(subject),
        now: now,
        remote: remote,
      );
      addTearDown(harness.close);

      unawaited(harness.coordinator.start());
      await remote.firstListRequested;
      final stop = harness.coordinator.stop();
      await remote.cancellationObserved;
      await stop;

      final facts = await SyncHealthDao(
        harness.database,
      ).watchFacts(harness.accountId).first;
      expect(facts.syncEnabled, isFalse);
      expect((await harness.health()).outcome, SyncHealthOutcome.inactive);
      expect(remote.listCalls, 1);
    },
  );

  test(
    'malformed remote data becomes application Failed and never Good',
    () async {
      final harness = await _Harness.create(
        authorization: const SyntheticAuthorization(subject),
        now: now,
        remote: _ScriptedReadService(malformedTask: true),
      );
      addTearDown(harness.close);

      await harness.coordinator.start();

      final health = await harness.health();
      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.applicationFailure);
      expect(health.diagnosticCode, 'sync.malformed_live_task');
    },
  );

  test(
    'HLT-008 absent authorization is Inactive and performs no Google read',
    () async {
      final authorization = FakeAuthorization()
        ..enqueue(
          FakeAuthorizationAttempt.restoreMismatch(
            subject,
            _noAuthorizationFailure,
          ),
        );
      final harness = await _Harness.create(
        authorization: authorization,
        now: now,
      );
      addTearDown(harness.close);
      addTearDown(authorization.close);

      await harness.coordinator.start();

      final health = await harness.health();
      expect(health.outcome, SyncHealthOutcome.inactive);
      expect(health.inactiveReason, SyncInactiveReason.noAuthorization);
      expect(harness.remote.listCalls, 0);
    },
  );
}

const Failure _noAuthorizationFailure = Failure(
  code: 'auth.synthetic_absent',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization is absent.',
  action: FailureAction.connect,
  safeSummary: 'Synthetic authorization is absent.',
);

final class _Harness {
  _Harness._({
    required this.database,
    required this.accountId,
    required this.remote,
    required this.coordinator,
    required this.clock,
  });

  static Future<_Harness> create({
    required AuthorizationPort authorization,
    required DateTime now,
    DateTime? priorSuccess,
    _ScriptedReadService? remote,
    FakeLifecycle? lifecycle,
  }) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(
      await database.createAccount('synthetic-foreground-read-subject'),
    );
    if (priorSuccess != null) {
      await SyncHealthDao(database).writeFacts(
        accountId,
        PersistedSyncFacts(lastSuccessfulSyncAt: priorSuccess),
      );
    }
    final clock = FakeClock(now);
    final service = remote ?? _ScriptedReadService();
    late final SyncCoordinator coordinator;
    coordinator = SyncCoordinator(
      accountId: accountId,
      authorization: authorization,
      clock: clock,
      scheduler: clock,
      random: SequenceRandomSource(
        List<int>.generate(512, (index) => index % 256),
      ),
      settings: DatabaseSyncSettingsRepository(database),
      retryStore: DatabaseReadSyncStore(database),
      lifecycle: lifecycle,
      run: (request) =>
          SyncEngine(
            store: DatabaseReadSyncStore(database),
            googleTasks: service,
            authorization: authorization,
            clock: clock,
            scheduler: clock,
            random: FakeRandom.scriptedJitter(
              List<Duration>.filled(64, Duration.zero),
            ),
            retryObserver: request.retryObserver,
            control: request.control,
          ).run(
            SyncRunRequest(
              accountId: accountId,
              deadline: request.deadline,
              triggers: request.triggers
                  .map((trigger) => trigger.value)
                  .toSet(),
            ),
          ),
    );
    return _Harness._(
      database: database,
      accountId: accountId,
      remote: service,
      coordinator: coordinator,
      clock: clock,
    );
  }

  final AppDatabase database;
  final AccountId accountId;
  final _ScriptedReadService remote;
  final SyncCoordinator coordinator;
  final FakeClock clock;

  Stream<SyncHealth> watchHealth() => DatabaseSyncHealthRepository(
    dao: SyncHealthDao(database),
    clock: clock,
    runtime: coordinator,
  ).watchHealth(accountId);

  Future<SyncHealth> health() async => projectSyncHealth(
    facts: await SyncHealthDao(database).watchFacts(accountId).first,
    runtime: coordinator.currentFacts,
    now: clock.now(),
  );

  Future<void> close() async {
    await coordinator.close();
    remote.close();
    await database.close();
  }
}

final class _DelayedAuthorization implements AuthorizationPort {
  _DelayedAuthorization(this.subject);

  final AccountSubject subject;
  final StreamController<AuthorizationState> _states =
      StreamController.broadcast(sync: true);
  final Completer<Outcome<AccountSubject>> _restore = Completer();
  AuthorizationState _state = const NoTasksAuthorization();

  @override
  AuthorizationState get currentState => _state;

  @override
  Stream<AuthorizationState> get states => _states.stream;

  void completeRestore() {
    _state = TasksAuthorized(subject);
    _states.add(_state);
    _restore.complete(Outcome<AccountSubject>.success(subject));
  }

  @override
  Future<Outcome<AccountSubject>> restoreTasksAuthorization() {
    _state = AuthorizationRefreshPending(subject);
    _states.add(_state);
    return _restore.future;
  }

  @override
  Future<Outcome<AccountSubject>> refreshTasksAuthorization() async =>
      Outcome.success(subject);

  @override
  Future<Outcome<AccountSubject>> requestTasksAuthorization() async =>
      Outcome.success(subject);
}

final class _ScriptedReadService implements GoogleTasksService {
  _ScriptedReadService({
    this.blockFirstList = false,
    this.failTasksAfterList = false,
    this.malformedTask = false,
  });

  final bool blockFirstList;
  final bool failTasksAfterList;
  final bool malformedTask;
  final Completer<void> _firstListRequested = Completer<void>();
  final Completer<void> _releaseList = Completer<void>();
  final Completer<void> _cancellationObserved = Completer<void>();
  var listCalls = 0;

  Future<void> get firstListRequested => _firstListRequested.future;

  Future<void> get cancellationObserved => _cancellationObserved.future;

  void releaseFirstList() {
    if (!_releaseList.isCompleted) _releaseList.complete();
  }

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    listCalls += 1;
    if (listCalls == 1 && blockFirstList) {
      _firstListRequested.complete();
      final completedNormally = await Future.any(<Future<bool>>[
        _releaseList.future.then((_) => true),
        if (cancellation != null)
          cancellation.whenCancelled.then((_) {
            if (!_cancellationObserved.isCompleted) {
              _cancellationObserved.complete();
            }
            return false;
          }),
      ]);
      if (!completedNormally) {
        return const Outcome.failure(
          Failure(
            code: 'google_tasks.read_cancelled',
            category: FailureCategory.network,
            operation: FailureOperation.read,
            retry: RetryClassification.unknown,
            impact: 'The synthetic read was cancelled safely.',
            safeSummary: 'The synthetic read was cancelled.',
          ),
        );
      }
    }
    return Outcome.success(
      RemotePage<RemoteTaskList>(
        items: <RemoteTaskList>[
          RemoteTaskList(
            id: const RemoteTaskListId('synthetic-list'),
            etag: 'synthetic-list-etag',
            title: 'Validated remote list',
            updated: DateTime.utc(2026, 8, 15, 12),
            selfLink: null,
          ),
        ],
        collectionEtag: 'synthetic-lists-etag',
        nextPageToken: null,
      ),
    );
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    if (failTasksAfterList) {
      return const Outcome.failure(
        Failure(
          code: 'google_tasks.synthetic_connection',
          category: FailureCategory.network,
          operation: FailureOperation.read,
          retry: RetryClassification.transient,
          impact: 'Synthetic task data was not verified.',
          action: FailureAction.retry,
          safeSummary: 'Synthetic connection failed.',
        ),
      );
    }
    return Outcome.success(
      RemotePage<RemoteTask>(
        items: <RemoteTask>[
          RemoteLiveTask(
            id: const RemoteTaskId('synthetic-task'),
            etag: 'synthetic-task-etag',
            updated: DateTime.utc(2026, 8, 15, 12),
            selfLink: null,
            title: 'Validated remote task',
            parentId: null,
            position: malformedTask ? '' : '00000000000000000001',
            notes: 'Synthetic data only.',
            status: RemoteTaskStatus.needsAction,
            due: null,
            completed: null,
            hidden: false,
            links: const <RemoteTaskLink>[],
            webViewLink: null,
          ),
        ],
        collectionEtag: 'synthetic-tasks-etag',
        nextPageToken: null,
      ),
    );
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => throw UnsupportedError('read only');
  @override
  void close() {}
}
