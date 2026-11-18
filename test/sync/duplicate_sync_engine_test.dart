// Publication of Duplicate's copies: each copy goes to Google as one ordinary
// create (the v1.5.3 insert payload: "(copy)" title, open, no notes, no date,
// no `previous`, the source's parent), binds its own new Google ID, never
// mutates or conflates the source, and recovers from interruption, restart
// and failed attempts by the shared create rules.

import 'dart:io';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/duplication_fixture.dart';
import '../support/fake_google_tasks_service.dart';

void main() {
  Future<TaskDuplicateReceipt> duplicate(
    DuplicationFixture fixture,
    TaskId source,
  ) async => switch (await fixture.duplicate(source)) {
    Success<TaskDuplicateReceipt>(:final value) => value,
    Failed<TaskDuplicateReceipt>(:final failure) => fail(failure.code),
  };

  Future<RemoteTaskListId> remoteList(
    DuplicationFixture fixture,
    TaskListId list,
  ) async => RemoteTaskListId(
    (await fixture.snapshot()).taskLists
        .singleWhere((candidate) => candidate.id == list)
        .remoteId!
        .value,
  );

  test('leaf and parent copies publish as new creates and leave every '
      'source unchanged on Google', () async {
    final google = FakeGoogleTasksService();
    addTearDown(google.close);
    final fixture = await DuplicationFixture.open(google: google);
    addTearDown(fixture.close);
    final sources = await fixture.seedSyncedSources();
    final list = await remoteList(fixture, sources.list);
    final remoteBefore = {
      for (final task in await remoteTasks(google, list)) task.id.value: task,
    };
    final callsBefore = google.calls.length;

    final leafCopy = await duplicate(fixture, sources.leaf);
    final parentCopy = await duplicate(fixture, sources.parent);
    final report = await fixture.sync();

    expect(report.outcome, SyncRunOutcome.succeeded);
    final mutations = google.calls
        .skip(callsBefore)
        .where(
          (call) =>
              call.operation != FakeGoogleTasksMethod.listTaskLists &&
              call.operation != FakeGoogleTasksMethod.getTaskList &&
              call.operation != FakeGoogleTasksMethod.listTasks,
        )
        .toList();
    expect(
      mutations.map((call) => call.operation),
      everyElement(FakeGoogleTasksMethod.createTask),
      reason: 'Duplicate never patches, moves or deletes the source',
    );
    expect(
      mutations.map((call) => call.body),
      unorderedEquals(<Map<String, Object?>>[
        <String, Object?>{
          'title': 'Call plumber (copy)',
          'status': 'needsAction',
        },
        <String, Object?>{'title': 'Groceries (copy)', 'status': 'needsAction'},
      ]),
      reason: 'v1.5.3 copies neither notes nor due date nor completion',
    );
    expect(
      mutations.map((call) => call.query),
      everyElement(isEmpty),
      reason: 'top-level copies are inserted with no parent or previous',
    );

    final remoteAfter = await remoteTasks(google, list);
    for (final before in remoteBefore.values) {
      final after = remoteAfter.singleWhere((task) => task.id == before.id);
      expect(after.etag, before.etag, reason: before.title);
      expect(after.title, before.title);
      expect(after.notes, before.notes);
      expect(after.due, before.due);
      expect(after.status, before.status);
      expect(after.parentId, before.parentId);
    }
    final snapshot = await fixture.snapshot();
    final leafRemote = snapshot.tasks
        .singleWhere((task) => task.id == leafCopy.taskId)
        .remoteId;
    final parentRemote = snapshot.tasks
        .singleWhere((task) => task.id == parentCopy.taskId)
        .remoteId;
    expect(leafRemote, isNotNull);
    expect(parentRemote, isNotNull);
    expect(remoteBefore.keys, isNot(contains(leafRemote!.value)));
    expect(remoteBefore.keys, isNot(contains(parentRemote!.value)));
    expect(
      remoteAfter.where((task) => task.parentId?.value == parentRemote.value),
      isEmpty,
      reason: 'the parent copy has no subtasks on Google',
    );
    expect(remoteAfter, hasLength(remoteBefore.length + 2));
    for (final copy in <TaskDuplicateReceipt>[leafCopy, parentCopy]) {
      expect(
        (await fixture.desired.readTask(fixture.accountId, copy.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
    }

    final creates = google.callCount(FakeGoogleTasksMethod.createTask);
    expect((await fixture.sync()).outcome, SyncRunOutcome.succeeded);
    expect(
      google.callCount(FakeGoogleTasksMethod.createTask),
      creates,
      reason: 'a confirmed copy is never published again',
    );
  });

  test(
    'a subtask copy is inserted under the source parent Google ID',
    () async {
      final google = FakeGoogleTasksService();
      addTearDown(google.close);
      final fixture = await DuplicationFixture.open(google: google);
      addTearDown(fixture.close);
      final sources = await fixture.seedSyncedSources();
      final parentRemote = (await fixture.task(sources.parent)).remoteId!;
      final callsBefore = google.calls.length;

      final copy = await duplicate(fixture, sources.child);
      expect((await fixture.sync()).outcome, SyncRunOutcome.succeeded);

      final create = google.calls
          .skip(callsBefore)
          .singleWhere(
            (call) => call.operation == FakeGoogleTasksMethod.createTask,
          );
      expect(create.query, <String, String>{'parent': parentRemote.value});
      expect(create.body, <String, Object?>{
        'title': 'Milk (copy)',
        'status': 'needsAction',
      });
      final copyRemote = (await fixture.task(copy.taskId)).remoteId!;
      final remote = (await remoteTasks(
        google,
        await remoteList(fixture, sources.list),
      )).singleWhere((task) => task.id.value == copyRemote.value);
      expect(remote.parentId?.value, parentRemote.value);
      expect(
        copyRemote.value,
        isNot((await fixture.task(sources.child)).remoteId!.value),
      );
    },
  );

  test(
    'a copy under an unpublished parent waits for the parent create',
    () async {
      final google = FakeGoogleTasksService();
      addTearDown(google.close);
      final fixture = await DuplicationFixture.open(google: google);
      addTearDown(fixture.close);
      final sources = await fixture.seedSyncedSources();
      final localParent = await fixture.createTask(
        sources.list,
        'Local parent',
      );
      final localChild = await fixture.createTask(
        sources.list,
        'Local child',
        parentTaskId: localParent,
      );
      final callsBefore = google.calls.length;

      final copy = await duplicate(fixture, localChild);
      expect((await fixture.sync()).outcome, SyncRunOutcome.succeeded);

      final creates = google.calls
          .skip(callsBefore)
          .where((call) => call.operation == FakeGoogleTasksMethod.createTask)
          .toList();
      expect(creates.first.body?['title'], 'Local parent');
      final parentRemote = (await fixture.task(localParent)).remoteId!;
      final copyCreate = creates.singleWhere(
        (call) => call.body?['title'] == 'Local child (copy)',
      );
      expect(copyCreate.query, <String, String>{'parent': parentRemote.value});
      expect((await fixture.task(copy.taskId)).remoteId, isNotNull);
    },
  );

  test('a copy acknowledged locally but interrupted before publication '
      'publishes exactly once after a restart', () async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-duplicate-sync-',
    );
    addTearDown(() => root.delete(recursive: true));
    final google = FakeGoogleTasksService();
    addTearDown(google.close);
    final fixture = await DuplicationFixture.open(
      google: google,
      file: File('${root.path}/isolated.sqlite'),
    );
    final sources = await fixture.seedSyncedSources();
    final copy = await duplicate(fixture, sources.parent);
    final creates = google.callCount(FakeGoogleTasksMethod.createTask);

    final interrupted = await fixture.sync(
      control: _InterruptAtFirst(SyncRunBoundaryKind.beforeOperationClaim),
    );
    expect(interrupted.outcome, SyncRunOutcome.interrupted);
    expect(google.callCount(FakeGoogleTasksMethod.createTask), creates);

    await fixture.reopen();
    addTearDown(fixture.close);
    expect(
      (await fixture.desired.readTask(fixture.accountId, copy.taskId))?.state,
      DesiredStateLifecycle.pending,
    );
    expect((await fixture.sync()).outcome, SyncRunOutcome.succeeded);
    expect((await fixture.sync()).outcome, SyncRunOutcome.succeeded);

    expect(google.callCount(FakeGoogleTasksMethod.createTask), creates + 1);
    final remote = await remoteTasks(
      google,
      await remoteList(fixture, sources.list),
    );
    expect(
      remote.where((task) => task.title == 'Groceries (copy)'),
      hasLength(1),
    );
    final copyTask = await fixture.task(copy.taskId);
    expect(copyTask.title, 'Groceries (copy)');
    expect(copyTask.remoteId, isNotNull);
  });

  test('a rejected copy publication is retried by the same create and '
      'leaves exactly one copy on Google, with the source untouched', () async {
    final google = FakeGoogleTasksService();
    addTearDown(google.close);
    final service = _RejectNextCreate(google);
    final fixture = await DuplicationFixture.open(
      google: service,
      ledger: google,
    );
    addTearDown(fixture.close);
    final sources = await fixture.seedSyncedSources();
    final source = await _sourceFacts(fixture, sources.leaf);
    final committedBefore = google.callCount(FakeGoogleTasksMethod.createTask);
    service.attempts.clear();
    final copy = await duplicate(fixture, sources.leaf);
    service.rejectNext = true;

    await fixture.sync();
    await fixture.settle();

    expect(service.attempts, <String>[
      'Call plumber (copy)',
      'Call plumber (copy)',
    ], reason: 'the declined insert is retried, not abandoned or forked');
    expect(
      google.callCount(FakeGoogleTasksMethod.createTask),
      committedBefore + 1,
    );
    final copies = (await remoteTasks(
      google,
      await remoteList(fixture, sources.list),
    )).where((task) => task.title == 'Call plumber (copy)').toList();
    expect(copies, hasLength(1));
    expect(
      (await fixture.task(copy.taskId)).remoteId?.value,
      copies.single.id.value,
    );
    expect(
      (await fixture.desired.readTask(fixture.accountId, copy.taskId))?.state,
      DesiredStateLifecycle.confirmed,
    );
    expect(await _sourceFacts(fixture, sources.leaf), source);
  });
}

/// The source's identity, content and publication state. Sibling positions
/// are excluded: Google renumbers them when the copy is inserted first.
Future<List<Object?>> _sourceFacts(
  DuplicationFixture fixture,
  TaskId source,
) async {
  final task = await fixture.task(source);
  final desired = (await fixture.desired.readTask(fixture.accountId, source))!;
  return <Object?>[
    task.id,
    task.remoteId?.value,
    task.taskListId,
    task.parentTaskId,
    task.title,
    task.notes,
    task.status,
    task.due?.toString(),
    desired.generation,
    desired.state,
    desired.baseRemoteId,
    desired.baseEtag,
    desired.title,
    desired.notes,
    desired.status,
    desired.due?.toString(),
  ];
}

final class _InterruptAtFirst implements SyncRunControl {
  _InterruptAtFirst(this.kind);

  final SyncRunBoundaryKind kind;
  var interrupted = false;

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async {
    if (!interrupted && boundary.kind == kind) {
      interrupted = true;
      return SyncRunControlDecision.interrupt;
    }
    return SyncRunControlDecision.proceed;
  }
}

/// Declines the next task insert before Google commits it, with a transient
/// failure the engine does not retry within the same run.
final class _RejectNextCreate implements GoogleTasksService {
  _RejectNextCreate(this.delegate);

  final FakeGoogleTasksService delegate;
  final List<String> attempts = <String>[];
  bool rejectNext = false;

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async {
    attempts.add(operation.title);
    if (rejectNext) {
      rejectNext = false;
      return const RejectedMutation<RemoteTask>(_rejected);
    }
    return delegate.createTask(operation);
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
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => delegate.deleteTaskList(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => delegate.patchTask(operation);

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

const GoogleTasksMutationError _rejected = GoogleTasksMutationError(
  failure: Failure(
    code: 'synthetic.duplicate_create_rejected',
    category: FailureCategory.internal,
    operation: FailureOperation.write,
    retry: RetryClassification.transient,
    impact: 'The synthetic copy was not created.',
    safeSummary: 'Synthetic create rejection.',
  ),
  kind: GoogleTasksErrorKind.transient,
  commitState: MutationCommitState.notCommitted,
);
