import 'dart:collection';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_auth.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_random.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);
  const subject = AccountSubject('synthetic-auth-recovery-subject');

  test(
    'AUTH-001 one refresh repeats the read and Good requires finalization',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.refreshSuccess(subject),
      );
      fixture.service.outcomes.addAll(<Outcome<RemotePage<RemoteTaskList>>>[
        const Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
        Outcome<RemotePage<RemoteTaskList>>.success(_emptyPage),
      ]);

      final report = await fixture.run();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.complete, isTrue);
      expect(fixture.service.calls, 2);
      expect(
        fixture.authorization.operationLedger,
        <FakeAuthorizationOperation>[FakeAuthorizationOperation.refresh],
      );
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
    },
  );

  test(
    'AUTH-002 a second conclusive rejection latches reauthorization',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      final lists = DatabaseTaskListsRepository(
        database: fixture.database,
        clock: fixture.clock,
      );
      expect(
        await lists.createTaskList(
          CreateTaskListCommand(
            accountId: fixture.accountId,
            title: 'Cached intent',
          ),
        ),
        isA<Success<TaskListId>>(),
      );
      final before = await fixture.database
          .select(fixture.database.taskListCacheRows)
          .get();
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.refreshSuccess(subject),
      );
      fixture.service.outcomes
          .addAll(const <Outcome<RemotePage<RemoteTaskList>>>[
            Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
            Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
          ]);

      final report = await fixture.run();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(fixture.service.calls, 2);
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isTrue,
      );
      final after = await fixture.database
          .select(fixture.database.taskListCacheRows)
          .get();
      expect(
        after.map((row) => (row.id, row.title)),
        before.map((row) => (row.id, row.title)),
      );
      expect(
        await fixture.database.select(fixture.database.desiredStateRows).get(),
        hasLength(1),
      );
    },
  );

  test(
    'AUTH-002 terminal refresh rejection latches without a second call',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.refreshTerminal(subject, _terminal),
      );
      fixture.service.outcomes.add(
        const Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
      );

      final report = await fixture.run();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure, _terminal);
      expect(fixture.service.calls, 1);
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isTrue,
      );
    },
  );

  test('AUTH-002 terminal pre-run refresh latches without HTTP', () async {
    final fixture = await _Fixture.create(now, subject);
    addTearDown(fixture.close);
    fixture.authorization.expire();
    fixture.authorization.enqueue(
      FakeAuthorizationAttempt.refreshTerminal(subject, _terminal),
    );

    final report = await fixture.run();

    expect(report.outcome, SyncRunOutcome.ineligible);
    expect(report.ineligibleReason, SyncRunIneligibleReason.noAuthorization);
    expect(fixture.service.calls, 0);
    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
  });

  test('AUTH-004 refreshed subject mismatch latches before replay', () async {
    final fixture = await _Fixture.create(now, subject);
    addTearDown(fixture.close);
    fixture.authorization.enqueue(
      FakeAuthorizationAttempt.refreshSuccess(
        const AccountSubject('different-synthetic-subject'),
      ),
    );
    fixture.service.outcomes.add(
      const Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
    );

    final report = await fixture.run();

    expect(report.outcome, SyncRunOutcome.failed);
    expect(report.failure?.code, 'account.subject_mismatch');
    expect(fixture.service.calls, 1);
    expect(
      (await fixture.store.readEligibility(
        fixture.accountId,
      )).reauthorizationRequired,
      isTrue,
    );
  });

  test(
    'AUTH-004 already-usable subject mismatch latches before HTTP',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      await fixture.authorization.close();
      final mismatched = FakeAuthorization(
        initialState: const TasksAuthorized(
          AccountSubject('different-synthetic-subject'),
        ),
      );
      addTearDown(mismatched.close);

      final report = await SyncEngine(
        store: fixture.store,
        googleTasks: fixture.service,
        authorization: mismatched,
        clock: fixture.clock,
        scheduler: fixture.clock,
        random: FakeRandom.seeded(31),
      ).run(SyncRunRequest(accountId: fixture.accountId));

      expect(report.outcome, SyncRunOutcome.ineligible);
      expect(report.ineligibleReason, SyncRunIneligibleReason.accountMismatch);
      expect(fixture.service.calls, 0);
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isTrue,
      );
    },
  );

  test(
    'AUTH-006 unknown auth-like failure does not refresh or latch',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      fixture.service.outcomes.add(
        const Outcome<RemotePage<RemoteTaskList>>.failure(_unknownAuthLike),
      );

      final report = await fixture.run();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(fixture.service.calls, 1);
      expect(fixture.authorization.operationLedger, isEmpty);
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
    },
  );

  test(
    'AUTH-001 refresh does not escape the four-attempt request budget',
    () async {
      final fixture = await _Fixture.create(now, subject);
      addTearDown(fixture.close);
      fixture.authorization.enqueue(
        FakeAuthorizationAttempt.refreshSuccess(subject),
      );
      fixture.service.outcomes
          .addAll(const <Outcome<RemotePage<RemoteTaskList>>>[
            Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
            Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
            Outcome<RemotePage<RemoteTaskList>>.failure(_transient),
            Outcome<RemotePage<RemoteTaskList>>.failure(_refreshable),
          ]);

      final run = fixture.run();
      for (var retry = 0; retry < 3; retry += 1) {
        await pumpEventQueue();
        fixture.clock.advance(const Duration(seconds: 10));
      }
      final report = await run;

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure, _refreshable);
      expect(fixture.service.calls, 4);
      expect(fixture.authorization.operationLedger, isEmpty);
      expect(
        (await fixture.store.readEligibility(
          fixture.accountId,
        )).reauthorizationRequired,
        isFalse,
      );
    },
  );
}

final class _Fixture {
  _Fixture._({
    required this.database,
    required this.store,
    required this.accountId,
    required this.authorization,
    required this.service,
    required this.clock,
  });

  static Future<_Fixture> create(DateTime now, AccountSubject subject) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    return _Fixture._(
      database: database,
      store: DatabaseReadSyncStore(database),
      accountId: accountId,
      authorization: FakeAuthorization(initialState: TasksAuthorized(subject)),
      service: _ScriptedReadService(),
      clock: FakeClock(now),
    );
  }

  final AppDatabase database;
  final DatabaseReadSyncStore store;
  final AccountId accountId;
  final FakeAuthorization authorization;
  final _ScriptedReadService service;
  final FakeClock clock;

  Future<SyncRunReport> run() => SyncEngine(
    store: store,
    googleTasks: service,
    authorization: authorization,
    clock: clock,
    scheduler: clock,
    random: FakeRandom.seeded(29),
  ).run(SyncRunRequest(accountId: accountId));

  Future<void> close() async {
    await authorization.close();
    await database.close();
  }
}

final class _ScriptedReadService implements GoogleTasksService {
  final Queue<Outcome<RemotePage<RemoteTaskList>>> outcomes = Queue();
  int calls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    calls += 1;
    if (outcomes.isEmpty) throw StateError('No scripted read outcome.');
    return outcomes.removeFirst();
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) => throw StateError('No task page is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => throw StateError('No mutation is expected.');

  @override
  void close() {}
}

final _emptyPage = RemotePage<RemoteTaskList>(
  items: const <RemoteTaskList>[],
  collectionEtag: 'synthetic-empty-etag',
  nextPageToken: null,
);

const _refreshable = Failure(
  code: 'google_tasks.unauthorized',
  category: FailureCategory.authorization,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Synthetic authorization was rejected.',
  safeSummary: 'Synthetic refreshable authorization rejection.',
  authorizationRecovery: AuthorizationRecovery.refreshOnce,
);

const _terminal = Failure(
  code: 'auth.refresh_rejected',
  category: FailureCategory.authorization,
  operation: FailureOperation.authorize,
  retry: RetryClassification.permanent,
  impact: 'Synthetic authorization requires renewal.',
  safeSummary: 'Synthetic terminal refresh rejection.',
);

const _unknownAuthLike = Failure(
  code: 'google_tasks.remote_rejected',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Synthetic response was not classified.',
  safeSummary: 'Synthetic unknown auth-like response.',
);

const _transient = Failure(
  code: 'network.synthetic_transient',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Synthetic request did not complete.',
  safeSummary: 'Synthetic transient read failure.',
);
