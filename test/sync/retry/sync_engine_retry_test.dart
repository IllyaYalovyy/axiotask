import 'dart:collection';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_google_tasks_service.dart';
import '../../support/fake_random.dart';

void main() {
  final startedAt = DateTime.utc(2026, 8, 15, 12);

  test('REL-007 safe request retries initial plus three exact waits', () async {
    final fixture = await _Fixture.create(
      startedAt,
      outcomes: <Outcome<RemotePage<RemoteTaskList>>>[
        const Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
        const Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
        const Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
        Outcome<RemotePage<RemoteTaskList>>.success(_emptyPage),
      ],
      jitter: const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ],
    );
    addTearDown(fixture.close);

    final run = fixture.run();
    await pumpEventQueue();
    expect(fixture.service.calls, 1);
    expect(fixture.observer.states, <SyncRequestRetryState>[
      SyncRequestRetryState.waiting,
    ]);

    for (final delay in const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]) {
      fixture.clock.advance(delay - const Duration(milliseconds: 1));
      await pumpEventQueue();
      final before = fixture.service.calls;
      fixture.clock.advance(const Duration(milliseconds: 1));
      await pumpEventQueue();
      expect(fixture.service.calls, before + 1);
    }

    final report = await run;
    expect(report.outcome, SyncRunOutcome.succeeded);
    expect(fixture.service.calls, 4);
    expect(
      fixture.observer.states.where(
        (value) => value == SyncRequestRetryState.executing,
      ),
      hasLength(3),
    );
  });

  test('REL-008 a longer Retry-After is the actual request boundary', () async {
    final fixture = await _Fixture.create(
      startedAt,
      outcomes: <Outcome<RemotePage<RemoteTaskList>>>[
        Outcome<RemotePage<RemoteTaskList>>.failure(
          _withRetryAfter(const Duration(seconds: 40)),
        ),
        Outcome<RemotePage<RemoteTaskList>>.success(_emptyPage),
      ],
      jitter: const <Duration>[Duration(seconds: 1)],
    );
    addTearDown(fixture.close);

    final run = fixture.run();
    await pumpEventQueue();
    fixture.clock.advance(const Duration(seconds: 39, milliseconds: 999));
    await pumpEventQueue();
    expect(fixture.service.calls, 1);
    fixture.clock.advance(const Duration(milliseconds: 1));
    await pumpEventQueue();

    expect((await run).outcome, SyncRunOutcome.succeeded);
    expect(fixture.service.calls, 2);
  });

  test(
    'REL-005 retry does not begin when attempt cannot fit run budget',
    () async {
      final fixture = await _Fixture.create(
        startedAt,
        outcomes: const <Outcome<RemotePage<RemoteTaskList>>>[
          Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
        ],
        jitter: const <Duration>[Duration(seconds: 1)],
      );
      addTearDown(fixture.close);

      final report = await fixture.run(deadline: const Duration(seconds: 30));

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure?.code, 'sync.request_budget_exhausted');
      expect(fixture.service.calls, 1);
    },
  );

  test(
    'REL-011/017 unknown and permanent responses are never retried',
    () async {
      for (final failure in const <Failure>[_unknown, _permanent]) {
        final fixture = await _Fixture.create(
          startedAt,
          outcomes: <Outcome<RemotePage<RemoteTaskList>>>[
            Outcome<RemotePage<RemoteTaskList>>.failure(failure),
          ],
          jitter: const <Duration>[],
        );
        final report = await fixture.run();
        expect(report.outcome, SyncRunOutcome.failed);
        expect(report.failure, failure);
        expect(fixture.service.calls, 1);
        await fixture.close();
      }
    },
  );

  test(
    'REL-007 conclusively uncommitted mutation uses the same budget',
    () async {
      const subject = AccountSubject('synthetic-mutation-retry-subject');
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final account = AccountId(await database.createAccount(subject.value));
      final delegate = FakeGoogleTasksService();
      addTearDown(delegate.close);
      final remoteList = switch (await delegate.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic retry list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      await delegate.createTask(
        CreateTaskOperation(
          taskListId: remoteList.id,
          title: 'Before retry',
          status: RemoteTaskStatus.needsAction,
        ),
      );
      final service = _PatchRetryService(delegate);
      final clock = FakeClock(startedAt);
      final store = DatabaseReadSyncStore(database);
      final first = await SyncEngine(
        store: store,
        googleTasks: service,
        authorization: const SyntheticAuthorization(subject),
        clock: clock,
        scheduler: clock,
        random: FakeRandom.seeded(1),
      ).run(SyncRunRequest(accountId: account));
      expect(first.outcome, SyncRunOutcome.succeeded);

      final tasks = DatabaseTasksRepository(database, clock: clock);
      final local =
          (await tasks.watchTasks(TasksQuery(accountId: account)).first)
              .tasks
              .single;
      expect(
        await tasks.apply(
          UpdateTaskContentCommand(
            accountId: account,
            taskId: local.id,
            title: 'After retry',
            notes: null,
            status: TaskStatus.needsAction,
            due: null,
          ),
        ),
        isA<Success<void>>(),
      );

      service.remainingPatchFailures = 3;
      final run = SyncEngine(
        store: store,
        googleTasks: service,
        authorization: const SyntheticAuthorization(subject),
        clock: clock,
        scheduler: clock,
        random: FakeRandom.scriptedJitter(const <Duration>[
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
        ]),
      ).run(SyncRunRequest(accountId: account));
      await pumpEventQueue();
      expect(service.patchCalls, 1);
      for (final delay in const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]) {
        clock.advance(delay);
        await pumpEventQueue();
      }

      expect((await run).outcome, SyncRunOutcome.succeeded);
      expect(service.patchCalls, 4);
      expect(
        (await tasks.watchTasks(TasksQuery(accountId: account)).first)
            .tasks
            .single
            .title,
        'After retry',
      );
    },
  );
}

final class _Fixture {
  _Fixture._({
    required this.database,
    required this.account,
    required this.clock,
    required this.service,
    required this.engine,
    required this.observer,
  });

  static Future<_Fixture> create(
    DateTime startedAt, {
    required List<Outcome<RemotePage<RemoteTaskList>>> outcomes,
    required List<Duration> jitter,
  }) async {
    const subject = AccountSubject('synthetic-retry-subject');
    final database = AppDatabase.inMemory();
    final account = AccountId(await database.createAccount(subject.value));
    final clock = FakeClock(startedAt);
    final service = _ScriptedService(outcomes);
    final observer = _RetryObserver();
    return _Fixture._(
      database: database,
      account: account,
      clock: clock,
      service: service,
      observer: observer,
      engine: SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: service,
        authorization: const SyntheticAuthorization(subject),
        clock: clock,
        scheduler: clock,
        random: FakeRandom.scriptedJitter(jitter),
        retryObserver: observer,
      ),
    );
  }

  final AppDatabase database;
  final AccountId account;
  final FakeClock clock;
  final _ScriptedService service;
  final SyncEngine engine;
  final _RetryObserver observer;

  Future<SyncRunReport> run({Duration deadline = const Duration(minutes: 2)}) =>
      engine.run(
        SyncRunRequest(
          accountId: account,
          deadline: clock.monotonicElapsed + deadline,
        ),
      );

  Future<void> close() => database.close();
}

final class _RetryObserver implements SyncRequestRetryObserver {
  final List<SyncRequestRetryState> states = <SyncRequestRetryState>[];

  @override
  void retryStateChanged(
    SyncRequestRetryState state, {
    required Failure failure,
    required int attempt,
    required Duration? delay,
  }) {
    states.add(state);
  }
}

final class _ScriptedService implements GoogleTasksService {
  _ScriptedService(Iterable<Outcome<RemotePage<RemoteTaskList>>> outcomes)
    : _outcomes = Queue<Outcome<RemotePage<RemoteTaskList>>>.from(outcomes);

  final Queue<Outcome<RemotePage<RemoteTaskList>>> _outcomes;
  int calls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    calls += 1;
    return _outcomes.removeFirst();
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => throw StateError('No synthetic lists exist.');

  Never _mutation() => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) async => _mutation();
  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) async => _mutation();
  @override
  void close() {}
}

final class _PatchRetryService implements GoogleTasksService {
  _PatchRetryService(this.delegate);

  final FakeGoogleTasksService delegate;
  int remainingPatchFailures = 0;
  int patchCalls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) =>
      delegate.listTaskLists(pageToken: pageToken, cancellation: cancellation);

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) => delegate.listTasks(
    taskListId,
    pageToken: pageToken,
    cancellation: cancellation,
  );

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async {
    patchCalls += 1;
    if (remainingPatchFailures > 0) {
      remainingPatchFailures -= 1;
      return const RejectedMutation<RemoteTask>(_rateLimitMutationError);
    }
    return delegate.patchTask(operation);
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => delegate.createTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => delegate.renameTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => delegate.deleteTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => delegate.createTask(operation);

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => delegate.deleteTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => delegate.moveTask(operation);

  @override
  void close() {}
}

final RemotePage<RemoteTaskList> _emptyPage = RemotePage<RemoteTaskList>(
  items: <RemoteTaskList>[],
  collectionEtag: 'synthetic-empty',
  nextPageToken: null,
);

const Failure _transient = Failure(
  code: 'synthetic.transport',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Synthetic transport failure.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic transport failure.',
);
const Failure _unknown = Failure(
  code: 'synthetic.unknown',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Synthetic unknown response.',
  safeSummary: 'Synthetic unknown response.',
);
const Failure _permanent = Failure(
  code: 'synthetic.permanent',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Synthetic permanent response.',
  safeSummary: 'Synthetic permanent response.',
);

Failure _withRetryAfter(Duration delay) => Failure(
  code: 'synthetic.rate_limit',
  category: FailureCategory.rateLimit,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Synthetic rate limit.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic rate limit.',
  remoteContext: RemoteFailureContext(
    statusCode: 429,
    retryAfter: RetryAfterDelay(delay),
  ),
);

const GoogleTasksMutationError _rateLimitMutationError =
    GoogleTasksMutationError(
      failure: Failure(
        code: 'synthetic.mutation_rate_limit',
        category: FailureCategory.rateLimit,
        operation: FailureOperation.write,
        retry: RetryClassification.transient,
        impact: 'Synthetic mutation rate limit.',
        action: FailureAction.retry,
        safeSummary: 'Synthetic mutation rate limit.',
      ),
      kind: GoogleTasksErrorKind.quota,
      commitState: MutationCommitState.notCommitted,
    );
