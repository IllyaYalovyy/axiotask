import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/delete_state_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';

void main() {
  const subject = AccountSubject('synthetic-delete-engine');
  final startedAt = DateTime.utc(2026, 8, 15, 16);

  test(
    'RUN-016 refresh cannot dispatch before grace and expiry dispatches once',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _DeleteHarness.open(remote, subject, startedAt);
      addTearDown(harness.close);
      final seeded = await harness.seed(parentWithChild: true);

      await harness.deleteTask(seeded.parent);
      harness.clock.advance(const Duration(seconds: 29, milliseconds: 999));
      final refresh = await harness.run();
      expect(refresh.outcome, SyncRunOutcome.succeeded);
      expect(refresh.deleteOperations, 0);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 0);
      expect(
        await DeleteStateDao(
          harness.database,
        ).readTaskDeleteState(harness.accountId, seeded.parent),
        DesiredStateLifecycle.pending,
      );

      harness.clock.advance(const Duration(milliseconds: 1));
      final expired = await harness.run();
      expect(expired.outcome, SyncRunOutcome.succeeded);
      expect(expired.deleteOperations, 1);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 1);
      final remoteTasks = await harness.remoteTasks(seeded.listRemoteId);
      expect(
        remoteTasks.whereType<RemoteTaskTombstone>().map((task) => task.id),
        containsAll(<RemoteTaskId>[
          seeded.parentRemoteId,
          seeded.childRemoteId!,
        ]),
      );

      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 1);
    },
  );

  test('RUN-016 Undo before dispatch restores and sends no DELETE', () async {
    final remote = FakeGoogleTasksService();
    addTearDown(remote.close);
    final harness = await _DeleteHarness.open(remote, subject, startedAt);
    addTearDown(harness.close);
    final seeded = await harness.seed(parentWithChild: true);

    await harness.deleteTask(seeded.parent);
    harness.clock.advance(const Duration(seconds: 29, milliseconds: 999));
    expect(
      await DatabaseTasksRepository(
        harness.database,
        clock: harness.clock,
      ).undoTaskDelete(
        UndoTaskDeleteCommand(
          accountId: harness.accountId,
          taskId: seeded.parent,
        ),
      ),
      isA<Success<void>>(),
    );
    await harness.run();

    expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 0);
    final snapshot = await harness.snapshot();
    expect(
      snapshot.tasks.map((task) => task.id),
      containsAll(<TaskId>[seeded.parent, seeded.child!]),
    );
  });

  test('REC-016 remote tombstone defeats a pending local edit', () async {
    final remote = FakeGoogleTasksService();
    addTearDown(remote.close);
    final harness = await _DeleteHarness.open(remote, subject, startedAt);
    addTearDown(harness.close);
    final seeded = await harness.seed();
    await DatabaseTasksRepository(harness.database, clock: harness.clock).apply(
      SetTaskTitleCommand(
        accountId: harness.accountId,
        taskId: seeded.parent,
        title: 'Local edit that must not resurrect',
      ),
    );
    final remoteTask = (await harness.remoteTasks(seeded.listRemoteId))
        .whereType<RemoteLiveTask>()
        .singleWhere((task) => task.id == seeded.parentRemoteId);
    await remote.deleteTask(
      DeleteTaskOperation(
        taskListId: seeded.listRemoteId,
        taskId: seeded.parentRemoteId,
        etag: remoteTask.etag!,
        pathFreshness: MutationPathFreshness.current,
      ),
    );

    await harness.run();
    expect((await harness.snapshot()).tasks, isEmpty);
    expect(
      (await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, seeded.parent))?.state,
      DesiredStateLifecycle.superseded,
    );
    expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 0);
  });

  test('REC-017 child moved away survives authoritative parent delete', () async {
    final remote = FakeGoogleTasksService();
    addTearDown(remote.close);
    final harness = await _DeleteHarness.open(remote, subject, startedAt);
    addTearDown(harness.close);
    final seeded = await harness.seed(parentWithChild: true, secondList: true);
    await harness.deleteTask(seeded.parent);

    final child = (await harness.remoteTasks(seeded.listRemoteId))
        .whereType<RemoteLiveTask>()
        .singleWhere((task) => task.id == seeded.childRemoteId);
    await remote.moveTask(
      MoveTaskOperation(
        sourceTaskListId: seeded.listRemoteId,
        taskId: seeded.childRemoteId!,
        etag: child.etag!,
        pathFreshness: MutationPathFreshness.current,
        destinationTaskListId: seeded.secondListRemoteId,
      ),
    );
    harness.clock.advance(const Duration(seconds: 30));
    await harness.run();

    final snapshot = await harness.snapshot();
    expect(
      snapshot.tasks.map(
        (task) =>
            '${task.id.value}:${task.remoteId?.value}:${task.taskListId.value}',
      ),
      hasLength(1),
    );
    final survivor = snapshot.tasks.single;
    expect(survivor.id, seeded.child);
    expect(survivor.remoteId, TaskRemoteId(seeded.childRemoteId!.value));
    expect(survivor.taskListId, seeded.secondList);
    expect(survivor.parentTaskId, isNull);
    expect(
      await harness.remoteTasks(seeded.secondListRemoteId!),
      contains(isA<RemoteLiveTask>()),
    );
  });

  test(
    'REL-015 uncertain task delete confirms only after tombstone evidence',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UncertainDeleteService(backend);
      final harness = await _DeleteHarness.open(remote, subject, startedAt);
      addTearDown(harness.close);
      final seeded = await harness.seed();
      await harness.deleteTask(seeded.parent);
      harness.clock.advance(const Duration(seconds: 30));

      final uncertain = await harness.run();
      expect(uncertain.outcome, SyncRunOutcome.failed);
      expect(uncertain.failure?.code, 'synthetic.delete_uncertain');
      expect(
        await DeleteStateDao(
          harness.database,
        ).readTaskDeleteState(harness.accountId, seeded.parent),
        DesiredStateLifecycle.uncertain,
      );
      expect(backend.callCount(FakeGoogleTasksMethod.deleteTask), 1);

      harness.clock.advance(const Duration(minutes: 1));
      final recovered = await harness.run();
      expect(recovered.outcome, SyncRunOutcome.succeeded);
      expect(backend.callCount(FakeGoogleTasksMethod.deleteTask), 1);
      expect(
        await DeleteStateDao(
          harness.database,
        ).readTaskDeleteState(harness.accountId, seeded.parent),
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'REL-020 list delete is immediate and leaves unrelated list intact',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _DeleteHarness.open(remote, subject, startedAt);
      addTearDown(harness.close);
      final seeded = await harness.seed(secondList: true);

      await DatabaseTaskListsRepository(
        database: harness.database,
        clock: harness.clock,
      ).deleteTaskList(
        DeleteTaskListCommand(
          accountId: harness.accountId,
          taskListId: seeded.list,
        ),
      );
      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.deleteOperations, 1);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTaskList), 1);
      final remoteLists = switch (await remote.listTaskLists()) {
        Success<RemotePage<RemoteTaskList>>(:final value) => value.items,
        _ => throw StateError('Synthetic list read failed.'),
      };
      expect(remoteLists.map((list) => list.id), <RemoteTaskListId>[
        seeded.secondListRemoteId!,
      ]);
    },
  );

  test(
    'REL-020 uncertain list delete retains evidence and unrelated scope',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UncertainDeleteService(backend)
        ..loseNextTaskDeleteResponse = false
        ..loseNextListDeleteResponse = true;
      final harness = await _DeleteHarness.open(remote, subject, startedAt);
      addTearDown(harness.close);
      final seeded = await harness.seed(secondList: true);

      await DatabaseTaskListsRepository(
        database: harness.database,
        clock: harness.clock,
      ).deleteTaskList(
        DeleteTaskListCommand(
          accountId: harness.accountId,
          taskListId: seeded.list,
        ),
      );
      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTaskList(harness.accountId, seeded.list))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(backend.callCount(FakeGoogleTasksMethod.deleteTaskList), 1);
      final remoteLists = switch (await backend.listTaskLists()) {
        Success<RemotePage<RemoteTaskList>>(:final value) => value.items,
        _ => throw StateError('Synthetic list read failed.'),
      };
      expect(remoteLists.map((list) => list.id), <RemoteTaskListId>[
        seeded.secondListRemoteId!,
      ]);
    },
  );
}

final class _DeleteHarness {
  _DeleteHarness(
    this.database,
    this.remote,
    this.subject,
    this.clock,
    this.accountId,
  );

  final AppDatabase database;
  final GoogleTasksService remote;
  final AccountSubject subject;
  final FakeClock clock;
  final AccountId accountId;

  static Future<_DeleteHarness> open(
    GoogleTasksService remote,
    AccountSubject subject,
    DateTime startedAt,
  ) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    return _DeleteHarness(
      database,
      remote,
      subject,
      FakeClock(startedAt),
      accountId,
    );
  }

  Future<_Seeded> seed({
    bool parentWithChild = false,
    bool secondList = false,
  }) async {
    final list = switch (await remote.createTaskList(
      const CreateTaskListOperation(title: 'Delete list'),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value,
      _ => throw StateError('Synthetic list setup failed.'),
    };
    final parent = switch (await remote.createTask(
      CreateTaskOperation(
        taskListId: list.id,
        title: 'Delete parent',
        status: RemoteTaskStatus.needsAction,
      ),
    )) {
      CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) => value,
      _ => throw StateError('Synthetic task setup failed.'),
    };
    final child = !parentWithChild
        ? null
        : switch (await remote.createTask(
            CreateTaskOperation(
              taskListId: list.id,
              title: 'Delete child',
              status: RemoteTaskStatus.needsAction,
              parentId: parent.id,
            ),
          )) {
            CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) =>
              value,
            _ => throw StateError('Synthetic child setup failed.'),
          };
    final otherList = !secondList
        ? null
        : switch (await remote.createTaskList(
            const CreateTaskListOperation(title: 'Survivor list'),
          )) {
            CommittedMutation<RemoteTaskList>(:final value) => value,
            _ => throw StateError('Synthetic second list setup failed.'),
          };
    await run();
    final snapshot = await this.snapshot();
    return _Seeded(
      list: snapshot.taskLists
          .singleWhere((value) => value.remoteId?.value == list.id.value)
          .id,
      listRemoteId: list.id,
      parent: snapshot.tasks
          .singleWhere((value) => value.remoteId?.value == parent.id.value)
          .id,
      parentRemoteId: parent.id,
      child: child == null
          ? null
          : snapshot.tasks
                .singleWhere((value) => value.remoteId?.value == child.id.value)
                .id,
      childRemoteId: child?.id,
      secondList: otherList == null
          ? null
          : snapshot.taskLists
                .singleWhere(
                  (value) => value.remoteId?.value == otherList.id.value,
                )
                .id,
      secondListRemoteId: otherList?.id,
    );
  }

  Future<void> deleteTask(TaskId taskId) async {
    final result = await DatabaseTasksRepository(
      database,
      clock: clock,
    ).deleteTask(DeleteTaskCommand(accountId: accountId, taskId: taskId));
    expect(result, isA<Success<TaskDeleteReceipt>>());
  }

  Future<List<RemoteTask>> remoteTasks(RemoteTaskListId listId) async =>
      switch (await remote.listTasks(listId)) {
        Success<RemotePage<RemoteTask>>(:final value) => value.items,
        _ => throw StateError('Synthetic task read failed.'),
      };

  Future<CachedTasksSnapshot> snapshot() => DatabaseTasksRepository(
    database,
    clock: clock,
  ).watchTasks(TasksQuery(accountId: accountId)).first;

  Future<SyncRunReport> run() => SyncEngine(
    store: DatabaseReadSyncStore(database),
    googleTasks: remote,
    authorization: SyntheticAuthorization(subject),
    clock: clock,
    random: SequenceRandomSource(
      List<int>.generate(256, (index) => index % 256),
    ),
  ).run(SyncRunRequest(accountId: accountId));

  Future<void> close() => database.close();
}

final class _Seeded {
  const _Seeded({
    required this.list,
    required this.listRemoteId,
    required this.parent,
    required this.parentRemoteId,
    required this.child,
    required this.childRemoteId,
    required this.secondList,
    required this.secondListRemoteId,
  });

  final TaskListId list;
  final RemoteTaskListId listRemoteId;
  final TaskId parent;
  final RemoteTaskId parentRemoteId;
  final TaskId? child;
  final RemoteTaskId? childRemoteId;
  final TaskListId? secondList;
  final RemoteTaskListId? secondListRemoteId;
}

final class _UncertainDeleteService implements GoogleTasksService {
  _UncertainDeleteService(this.delegate);

  final FakeGoogleTasksService delegate;
  var loseNextTaskDeleteResponse = true;
  var loseNextListDeleteResponse = false;

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) async {
    final result = await delegate.deleteTaskList(operation);
    if (loseNextListDeleteResponse) {
      loseNextListDeleteResponse = false;
      return const UncertainMutation<void>(_uncertainDeleteError);
    }
    return result;
  }

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) async {
    final result = await delegate.deleteTask(operation);
    if (loseNextTaskDeleteResponse) {
      loseNextTaskDeleteResponse = false;
      return const UncertainMutation<void>(_uncertainDeleteError);
    }
    return result;
  }

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
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => delegate.createTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => delegate.renameTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => delegate.createTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => delegate.patchTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => delegate.moveTask(operation);

  @override
  void close() {}
}

const Failure _uncertainDeleteFailure = Failure(
  code: 'synthetic.delete_uncertain',
  category: FailureCategory.network,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The synthetic delete may have committed.',
  safeSummary: 'The synthetic delete response was lost.',
);

const GoogleTasksMutationError _uncertainDeleteError = GoogleTasksMutationError(
  failure: _uncertainDeleteFailure,
  kind: GoogleTasksErrorKind.transient,
  commitState: MutationCommitState.uncertain,
);
