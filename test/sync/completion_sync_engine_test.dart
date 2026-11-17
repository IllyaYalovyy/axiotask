import 'dart:io';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
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

import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';

const _subject = AccountSubject('synthetic-completion-sync-subject');

void main() {
  late Directory root;
  late FakeGoogleTasksService backend;
  late _PatchInterceptService remote;
  late _Harness h;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('axiotask-completion-sync-');
    backend = FakeGoogleTasksService();
    remote = _PatchInterceptService(backend);
    h = await _Harness.open(File('${root.path}/sync.sqlite'), remote);
    await h.seed();
  });

  tearDown(() async {
    await h.close();
    backend.close();
    await root.delete(recursive: true);
  });

  test('parent completion publishes exactly the affected tasks and converges '
      'after reopening the database', () async {
    final calls = backend.calls.length;
    final receipt = _value(
      await h.repository().setTaskCompletion(h.command(h.parent)),
    );
    expect(receipt.changedTaskIds, <TaskId>[h.parent, h.child]);

    // Offline: the durable intent covers every affected task and survives
    // reopening before any Google request.
    await h.reopen();
    await h.expectIntent(<TaskId, TaskStatus>{
      h.parent: TaskStatus.completed,
      h.child: TaskStatus.completed,
    }, state: DesiredStateLifecycle.pending);
    expect(backend.calls, hasLength(calls));

    expect((await h.run()).outcome, SyncRunOutcome.succeeded);
    expect(remote.patchedTitles, <String>[
      'Parent',
    ], reason: 'Google cascades the parent completion to the open subtask');
    await h.expectRemote(completed: {'Parent', 'Child', 'Done child'});
    await h.expectLocal(completed: {h.parent, h.child, h.doneChild});
    await h.expectIntent(<TaskId, TaskStatus>{
      h.parent: TaskStatus.completed,
      h.child: TaskStatus.completed,
    }, state: DesiredStateLifecycle.confirmed);

    // Retrying the run never replays a confirmed completion.
    h.clock.advance(const Duration(minutes: 1));
    expect((await h.run()).outcome, SyncRunOutcome.succeeded);
    expect(remote.patchedTitles, <String>['Parent']);
  });

  test('Undo before publication restores Google without any write', () async {
    final repository = h.repository();
    final offer = _value(
      await repository.setTaskCompletion(h.command(h.parent)),
    ).undo!;
    expect(
      _value(await repository.undoTaskCompletion(h.undo(offer.operationId)))
          .restoredTaskIds,
      <TaskId>[h.parent, h.child],
    );
    await h.reopen();
    await h.expectIntent(<TaskId, TaskStatus>{
      h.parent: TaskStatus.needsAction,
      h.child: TaskStatus.needsAction,
    }, state: DesiredStateLifecycle.pending);

    expect((await h.run()).outcome, SyncRunOutcome.succeeded);
    expect(remote.patchedTitles, isEmpty);
    await h.expectRemote(completed: {'Done child'});
    await h.expectLocal(completed: {h.doneChild});
    await h.expectIntent(<TaskId, TaskStatus>{
      h.parent: TaskStatus.needsAction,
      h.child: TaskStatus.needsAction,
    }, state: DesiredStateLifecycle.confirmed);
  });

  test(
    'Undo of a published cascade reopens parent then subtask on Google',
    () async {
      final repository = h.repository();
      final offer = _value(
        await repository.setTaskCompletion(h.command(h.parent)),
      ).undo!;
      expect((await h.run()).outcome, SyncRunOutcome.succeeded);
      await h.expectRemote(completed: {'Parent', 'Child', 'Done child'});
      await h.expectIntent(<TaskId, TaskStatus>{
        h.parent: TaskStatus.completed,
        h.child: TaskStatus.completed,
      }, state: DesiredStateLifecycle.confirmed);
      final published = remote.patchedTitles.length;

      final result = _value(
        await repository.undoTaskCompletion(h.undo(offer.operationId)),
      );
      expect(result.restoredTaskIds, <TaskId>[h.parent, h.child]);
      await h.expectIntent(<TaskId, TaskStatus>{
        h.parent: TaskStatus.needsAction,
        h.child: TaskStatus.needsAction,
      }, state: DesiredStateLifecycle.pending);

      await h.reopen();
      expect((await h.run()).outcome, SyncRunOutcome.succeeded);
      expect(remote.patchedTitles.sublist(published), <String>[
        'Parent',
        'Child',
      ]);
      await h.expectRemote(completed: {'Done child'});
      await h.expectLocal(completed: {h.doneChild});
      await h.expectIntent(<TaskId, TaskStatus>{
        h.parent: TaskStatus.needsAction,
        h.child: TaskStatus.needsAction,
      }, state: DesiredStateLifecycle.confirmed);

      final settled = remote.patchedTitles.length;
      h.clock.advance(const Duration(minutes: 1));
      expect((await h.run()).outcome, SyncRunOutcome.succeeded);
      expect(remote.patchedTitles, hasLength(settled));
    },
  );

  for (final landed in <bool>[false, true]) {
    test('completion then Undo converge after a lost response '
        '(${landed ? 'landed' : 'not landed'}) and a restart', () async {
      final repository = h.repository();
      final offer = _value(
        await repository.setTaskCompletion(h.command(h.parent)),
      ).undo!;
      if (landed) {
        remote.uncertainNextPatchAfterCommit = true;
      } else {
        remote.uncertainNextPatchBeforeCommit = true;
      }
      expect((await h.run()).outcome, SyncRunOutcome.failed);
      await h.expectRemote(
        // The run continues after the parent's lost response and
        // publishes the subtask, which Google accepts either way.
        completed: landed
            ? {'Parent', 'Child', 'Done child'}
            : {'Child', 'Done child'},
      );

      expect(
        _value(await repository.undoTaskCompletion(h.undo(offer.operationId)))
            .restoredTaskIds,
        <TaskId>[h.parent, h.child],
      );
      await h.reopen();
      for (var attempt = 0; attempt < 3; attempt += 1) {
        h.clock.advance(const Duration(minutes: 1));
        await h.run();
      }

      await h.expectRemote(completed: {'Done child'});
      await h.expectLocal(completed: {h.doneChild});
      for (final id in <TaskId>[h.parent, h.child]) {
        final record = await DesiredStateDao(h.database)
            .readTask(h.account, id);
        expect(record?.status, TaskStatus.needsAction);
        expect(
          record?.state,
          isNot(
            anyOf(
              DesiredStateLifecycle.pending,
              DesiredStateLifecycle.inFlight,
              DesiredStateLifecycle.uncertain,
              DesiredStateLifecycle.failed,
            ),
          ),
          reason: 'task ${id.value} intent is resolved',
        );
      }
      final settled = remote.patchedTitles.length;
      h.clock.advance(const Duration(minutes: 1));
      expect((await h.run()).outcome, SyncRunOutcome.succeeded);
      expect(remote.patchedTitles, hasLength(settled));
    });
  }

  test('Undo keeps a Google edit reconciled after the completion', () async {
    final repository = h.repository();
    final offer = _value(
      await repository.setTaskCompletion(h.command(h.parent)),
    ).undo!;
    expect((await h.run()).outcome, SyncRunOutcome.succeeded);

    // Another client renames the completed subtask; the next read adopts it.
    await h.renameRemote('Child', 'Child renamed on Google');
    h.clock.advance(const Duration(seconds: 5));
    expect((await h.run()).outcome, SyncRunOutcome.succeeded);
    expect((await h.localTasks())[h.child]!.title, 'Child renamed on Google');

    final result = _value(
      await repository.undoTaskCompletion(h.undo(offer.operationId)),
    );
    expect(result.restoredTaskIds, <TaskId>[h.parent, h.child]);
    expect((await h.run()).outcome, SyncRunOutcome.succeeded);

    await h.expectRemote(completed: {'Done child'});
    final child = (await h.remoteTasks())['Child renamed on Google']!;
    expect(child.status, RemoteTaskStatus.needsAction);
    expect((await h.localTasks())[h.child]!.title, 'Child renamed on Google');
  });
}

final class _Harness {
  _Harness._(this.file, this.remote, this.database, this.clock);

  static Future<_Harness> open(File file, GoogleTasksService remote) async {
    final database = await AppDatabase.openFile(file);
    final harness = _Harness._(
      file,
      remote,
      database,
      FakeClock(DateTime.utc(2026, 11, 16, 14)),
    );
    harness.account = AccountId(await database.createAccount(_subject.value));
    return harness;
  }

  final File file;
  final GoogleTasksService remote;
  AppDatabase database;
  final FakeClock clock;
  late AccountId account;
  late RemoteTaskListId listRemote;
  late TaskId parent;
  late TaskId child;
  late TaskId doneChild;
  late TaskId unrelated;

  Future<void> seed() async {
    listRemote = switch (await remote.createTaskList(
      const CreateTaskListOperation(title: 'Completion sync'),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value.id,
      _ => throw StateError('Synthetic remote list setup failed.'),
    };
    final remoteParent = await _create('Parent');
    await _create('Child', parent: remoteParent);
    await _create(
      'Done child',
      parent: remoteParent,
      status: RemoteTaskStatus.completed,
    );
    await _create('Unrelated');
    expect((await run()).outcome, SyncRunOutcome.succeeded);
    final byTitle = <String, TaskId>{
      for (final task in (await localTasks()).values) task.title: task.id,
    };
    parent = byTitle['Parent']!;
    child = byTitle['Child']!;
    doneChild = byTitle['Done child']!;
    unrelated = byTitle['Unrelated']!;
  }

  Future<RemoteTaskId> _create(
    String title, {
    RemoteTaskId? parent,
    RemoteTaskStatus status = RemoteTaskStatus.needsAction,
  }) async => switch (await remote.createTask(
    CreateTaskOperation(
      taskListId: listRemote,
      title: title,
      notes: null,
      status: status,
      due: null,
      parentId: parent,
    ),
  )) {
    CommittedMutation<RemoteTask>(:final value) => value.id,
    _ => throw StateError('Synthetic remote task setup failed.'),
  };

  Future<void> renameRemote(String title, String renamed) async {
    final task = (await remoteTasks())[title]!;
    final result = await remote.patchTask(
      PatchTaskOperation(
        taskListId: listRemote,
        taskId: task.id,
        etag: task.etag!,
        title: renamed,
        notes: const OptionalFieldWrite<String>.clear(),
        status: task.status,
        due: const OptionalFieldWrite<RemoteDate>.clear(),
      ),
    );
    expect(result, isA<CommittedMutation<RemoteTask>>());
  }

  DatabaseTasksRepository repository() =>
      DatabaseTasksRepository(database, clock: clock);

  SetTaskCompletionCommand command(
    TaskId id, [
    TaskStatus status = TaskStatus.completed,
  ]) =>
      SetTaskCompletionCommand(accountId: account, taskId: id, status: status);

  UndoTaskCompletionCommand undo(int operationId) =>
      UndoTaskCompletionCommand(accountId: account, operationId: operationId);

  Future<SyncRunReport> run() => SyncEngine(
    store: DatabaseReadSyncStore(database),
    googleTasks: remote,
    authorization: SyntheticAuthorization(_subject),
    clock: clock,
    random: SequenceRandomSource(
      List<int>.generate(256, (index) => index % 256),
    ),
  ).run(SyncRunRequest(accountId: account));

  Future<void> reopen() async {
    await database.close();
    database = await AppDatabase.openFile(file);
  }

  Future<Map<TaskId, CachedTask>> localTasks() async => <TaskId, CachedTask>{
    for (final task in (await DatabaseTasksRepository(
      database,
    ).watchTasks(TasksQuery(accountId: account)).first).tasks)
      task.id: task,
  };

  Future<Map<String, RemoteLiveTask>> remoteTasks() async {
    final page = switch (await remote.listTasks(listRemote)) {
      Success<RemotePage<RemoteTask>>(:final value) => value,
      Failed<RemotePage<RemoteTask>>() => throw StateError('read failed'),
    };
    final tasks = <RemoteLiveTask>[...page.items.whereType<RemoteLiveTask>()];
    var token = page.nextPageToken;
    while (token != null) {
      final next = switch (await remote.listTasks(
        listRemote,
        pageToken: token,
      )) {
        Success<RemotePage<RemoteTask>>(:final value) => value,
        Failed<RemotePage<RemoteTask>>() => throw StateError('read failed'),
      };
      tasks.addAll(next.items.whereType<RemoteLiveTask>());
      token = next.nextPageToken;
    }
    return <String, RemoteLiveTask>{for (final task in tasks) task.title: task};
  }

  Future<void> expectRemote({required Set<String> completed}) async {
    final tasks = await remoteTasks();
    expect(tasks.length, 4);
    for (final MapEntry(key: title, value: task) in tasks.entries) {
      expect(
        task.status,
        completed.contains(title) || completed.contains(_seedTitle(title))
            ? RemoteTaskStatus.completed
            : RemoteTaskStatus.needsAction,
        reason: 'Google task $title',
      );
    }
  }

  Future<void> expectLocal({required Set<TaskId> completed}) async {
    final tasks = await localTasks();
    for (final id in <TaskId>[parent, child, doneChild, unrelated]) {
      expect(
        tasks[id]!.status,
        completed.contains(id) ? TaskStatus.completed : TaskStatus.needsAction,
        reason: 'local task ${id.value}',
      );
    }
  }

  Future<void> expectIntent(
    Map<TaskId, TaskStatus> expected, {
    required DesiredStateLifecycle state,
  }) async {
    final desired = DesiredStateDao(database);
    for (final id in <TaskId>[parent, child, doneChild, unrelated]) {
      final record = await desired.readTask(account, id);
      if (!expected.containsKey(id)) {
        expect(record, isNull, reason: 'task ${id.value} has no intent');
        continue;
      }
      expect(record?.status, expected[id], reason: 'task ${id.value}');
      expect(record?.state, state, reason: 'task ${id.value}');
    }
  }

  Future<void> close() => database.close();
}

String _seedTitle(String title) =>
    title == 'Child renamed on Google' ? 'Child' : title;

final class _PatchInterceptService implements GoogleTasksService {
  _PatchInterceptService(this.delegate);

  final FakeGoogleTasksService delegate;
  final List<String> patchedTitles = <String>[];
  bool uncertainNextPatchBeforeCommit = false;
  bool uncertainNextPatchAfterCommit = false;

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
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => delegate.deleteTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => delegate.createTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async {
    patchedTitles.add(operation.title);
    if (uncertainNextPatchBeforeCommit) {
      uncertainNextPatchBeforeCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertain);
    }
    final result = await delegate.patchTask(operation);
    if (uncertainNextPatchAfterCommit) {
      uncertainNextPatchAfterCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertain);
    }
    return result;
  }

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => delegate.deleteTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => delegate.moveTask(operation);

  @override
  void close() => delegate.close();
}

const GoogleTasksMutationError _uncertain = GoogleTasksMutationError(
  failure: Failure(
    code: 'synthetic.completion_uncertain',
    category: FailureCategory.network,
    operation: FailureOperation.write,
    retry: RetryClassification.unknown,
    impact: 'The synthetic update may have committed.',
    safeSummary: 'Synthetic update response was lost.',
  ),
  kind: GoogleTasksErrorKind.transient,
  commitState: MutationCommitState.uncertain,
);

T _value<T>(Outcome<T> outcome) => switch (outcome) {
  Success<T>(:final value) => value,
  Failed<T>(:final failure) => throw TestFailure(
    'Unexpected failure ${failure.code}',
  ),
};
