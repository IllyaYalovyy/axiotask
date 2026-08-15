import 'dart:io';

import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
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
  const subject = AccountSubject('synthetic-update-sync-subject');
  final startedAt = DateTime.utc(2026, 8, 15, 14);

  test(
    'RUN-013 publishes complete task content before list title and never replays',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Original list',
        taskTitle: 'Original task',
        notes: 'Original notes',
        due: TaskDate(2026, 8, 20),
      );

      await harness.renameList(seeded.listId, 'Renamed list');
      await harness.updateTask(
        seeded.taskId,
        title: 'Updated task',
        notes: null,
        status: TaskStatus.completed,
        due: null,
      );
      final report = await harness.run();
      final updateCalls = remote.calls
          .where(
            (call) =>
                call.operation == FakeGoogleTasksMethod.patchTask ||
                call.operation == FakeGoogleTasksMethod.renameTaskList,
          )
          .toList(growable: false);

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.updateOperations, 2);
      expect(updateCalls.map((call) => call.operation), <FakeGoogleTasksMethod>[
        FakeGoogleTasksMethod.patchTask,
        FakeGoogleTasksMethod.renameTaskList,
      ]);
      expect(updateCalls.first.body, <String, Object?>{
        'title': 'Updated task',
        'notes': null,
        'status': 'completed',
        'due': null,
      });
      expect(updateCalls.first.headers['if-match'], isNotEmpty);
      expect(updateCalls.last.body, <String, Object?>{'title': 'Renamed list'});
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTaskList(harness.accountId, seeded.listId))?.state,
        DesiredStateLifecycle.confirmed,
      );

      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
      expect(remote.callCount(FakeGoogleTasksMethod.renameTaskList), 1);
    },
  );

  test(
    'no-op task and list writes confirm without a remote mutation',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Already current list',
        taskTitle: 'Already current task',
        notes: 'Same notes',
        due: TaskDate(2026, 8, 21),
      );

      await harness.renameList(seeded.listId, 'Already current list');
      await harness.updateTask(
        seeded.taskId,
        title: 'Already current task',
        notes: 'Same notes',
        status: TaskStatus.needsAction,
        due: TaskDate(2026, 8, 21),
      );
      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.updateOperations, 0);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 0);
      expect(remote.callCount(FakeGoogleTasksMethod.renameTaskList), 0);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTaskList(harness.accountId, seeded.listId))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'CRS-003 interruption before update claim leaves intent pending',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Before-claim list',
        taskTitle: 'Before-claim original',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Still pending before claim',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      final interrupted = await harness.run(
        control: _InterruptAtFirst(SyncRunBoundaryKind.beforeOperationClaim),
      );
      expect(interrupted.outcome, SyncRunOutcome.interrupted);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 0);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.pending,
      );

      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
    },
  );

  test(
    'REL-004 independent updates acknowledge after a partial rejection',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend)..rejectFirstPatch = true;
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Partial list',
        taskTitle: 'First task',
      );
      final secondTask = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Second task',
      );
      await harness.run();
      final snapshot = await harness.snapshot();
      final secondLocalId = snapshot.tasks
          .singleWhere((task) => task.remoteId?.value == secondTask.id.value)
          .id;

      await harness.updateTask(
        seeded.taskId,
        title: 'Rejected update',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );
      await harness.updateTask(
        secondLocalId,
        title: 'Confirmed update',
        notes: 'Complete snapshot',
        status: TaskStatus.needsAction,
        due: null,
      );
      await harness.renameList(seeded.listId, 'Confirmed rename');

      final report = await harness.run();
      expect(report.outcome, SyncRunOutcome.failed);
      expect(remote.updateLedger, <String>[
        'task:Rejected update',
        'task:Confirmed update',
        'list:Confirmed rename',
      ]);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.failed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, secondLocalId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTaskList(harness.accountId, seeded.listId))?.state,
        DesiredStateLifecycle.confirmed,
      );

      final callsAfterPartial = remote.updateLedger.length;
      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(remote.updateLedger, hasLength(callsAfterPartial));
    },
  );

  test(
    'DUR-004 older update confirmation preserves a newer generation',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Generation list',
        taskTitle: 'Generation zero',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Generation one',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );
      remote.afterNextPatchCommit = () => harness.updateTask(
        seeded.taskId,
        title: 'Generation two',
        notes: 'Newer local intent',
        status: TaskStatus.needsAction,
        due: null,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final desired = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, seeded.taskId);
      final projected = (await harness.snapshot()).tasks.single;

      expect(projected.title, 'Generation two');
      expect(projected.notes, 'Newer local intent');
      expect(desired?.generation, 2);
      expect(desired?.state, DesiredStateLifecycle.pending);
      expect(desired?.baseTitle, 'Generation one');
      expect(remote.updateLedger, <String>['task:Generation one']);
    },
  );

  test(
    'REL-014 and CRS-004 claimed update becomes uncertain after restart without replay',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15b-update-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var harness = await _UpdateHarness.openFile(
        file: file,
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      final seeded = await harness.seedRemote(
        listTitle: 'Restart list',
        taskTitle: 'Restart original',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Claimed update',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      final interrupted = await harness.run(
        control: _InterruptAtFirst(SyncRunBoundaryKind.afterOperationClaim),
      );
      expect(interrupted.outcome, SyncRunOutcome.interrupted);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 0);
      await harness.close();

      harness = await _UpdateHarness.reopen(
        file: file,
        remote: remote,
        subject: subject,
        clock: harness.clock,
      );
      addTearDown(harness.close);
      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();

      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 0);
    },
  );

  test(
    'CRS-005 response-before-ack update is uncertain after restart without replay',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15b-response-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var harness = await _UpdateHarness.openFile(
        file: file,
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      final seeded = await harness.seedRemote(
        listTitle: 'Response restart list',
        taskTitle: 'Before response loss',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Committed before ack',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      final interrupted = await harness.run(
        control: _InterruptAtFirst(
          SyncRunBoundaryKind.beforeRemoteAcknowledgement,
        ),
      );
      expect(interrupted.outcome, SyncRunOutcome.interrupted);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
      await harness.close();

      harness = await _UpdateHarness.reopen(
        file: file,
        remote: remote,
        subject: subject,
        clock: harness.clock,
      );
      addTearDown(harness.close);
      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();

      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
    },
  );

  test(
    'CRS-006 update acknowledgement transaction is all-or-nothing',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Atomic ack list',
        taskTitle: 'Before atomic ack',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Remote committed content',
        notes: 'Must remain pending locally on rollback',
        status: TaskStatus.needsAction,
        due: null,
      );

      final failed = await harness.run(
        transactionControl: (boundary) {
          if (boundary ==
              DesiredStateTransactionBoundary.afterRemoteBaseWrite) {
            throw const DesiredStatePersistenceException('synthetic_ack_fault');
          }
        },
      );
      final desiredBeforeRecovery = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, seeded.taskId);

      expect(failed.outcome, SyncRunOutcome.failed);
      expect(desiredBeforeRecovery?.state, DesiredStateLifecycle.inFlight);
      expect(desiredBeforeRecovery?.baseTitle, 'Before atomic ack');
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);

      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
    },
  );

  test(
    'CRS-007 restart resumes only the update not already acknowledged',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15b-partial-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var harness = await _UpdateHarness.openFile(
        file: file,
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      final seeded = await harness.seedRemote(
        listTitle: 'Partial restart list',
        taskTitle: 'First original',
      );
      final secondRemote = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Second original',
      );
      await harness.run();
      final secondTask = (await harness.snapshot()).tasks
          .singleWhere((task) => task.remoteId?.value == secondRemote.id.value)
          .id;
      await harness.updateTask(
        seeded.taskId,
        title: 'First confirmed',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );
      await harness.updateTask(
        secondTask,
        title: 'Second pending',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      final interrupted = await harness.run(
        control: _InterruptAtFirst(
          SyncRunBoundaryKind.afterRemoteAcknowledgement,
        ),
      );
      expect(interrupted.outcome, SyncRunOutcome.interrupted);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      await harness.close();

      harness = await _UpdateHarness.reopen(
        file: file,
        remote: remote,
        subject: subject,
        clock: harness.clock,
      );
      addTearDown(harness.close);
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 2);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, secondTask))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'REL-014 uncertain task update is retained and never replayed',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend)
        ..uncertainNextPatchAfterCommit = true;
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Uncertain list',
        taskTitle: 'Before uncertainty',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Possibly landed content',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(remote.updateLedger, <String>['task:Possibly landed content']);

      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(remote.updateLedger, <String>['task:Possibly landed content']);
    },
  );

  test('REL-014 uncertain list title is retained and never replayed', () async {
    final backend = FakeGoogleTasksService();
    addTearDown(backend.close);
    final remote = _UpdateInterceptService(backend)
      ..uncertainNextRenameAfterCommit = true;
    final harness = await _UpdateHarness.open(
      remote: remote,
      subject: subject,
      startedAt: startedAt,
    );
    addTearDown(harness.close);
    final seeded = await harness.seedRemote(
      listTitle: 'Before uncertain rename',
      taskTitle: 'Unchanged task',
    );
    await harness.renameList(seeded.listId, 'Possibly landed rename');

    expect((await harness.run()).outcome, SyncRunOutcome.failed);
    expect(
      (await DesiredStateDao(
        harness.database,
      ).readTaskList(harness.accountId, seeded.listId))?.state,
      DesiredStateLifecycle.uncertain,
    );
    expect(remote.updateLedger, <String>['list:Possibly landed rename']);

    harness.clock.advance(const Duration(minutes: 1));
    await harness.run();
    expect(remote.updateLedger, <String>['list:Possibly landed rename']);
  });
}

final class _SeededRemote {
  const _SeededRemote({
    required this.listId,
    required this.taskId,
    required this.listRemoteId,
  });

  final TaskListId listId;
  final TaskId taskId;
  final RemoteTaskListId listRemoteId;
}

final class _UpdateHarness {
  _UpdateHarness._({
    required this.database,
    required this.accountId,
    required this.clock,
    required this.remote,
    required this.subject,
  });

  static Future<_UpdateHarness> open({
    required GoogleTasksService remote,
    required AccountSubject subject,
    required DateTime startedAt,
  }) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    return _UpdateHarness._(
      database: database,
      accountId: accountId,
      clock: FakeClock(startedAt),
      remote: remote,
      subject: subject,
    );
  }

  static Future<_UpdateHarness> openFile({
    required File file,
    required GoogleTasksService remote,
    required AccountSubject subject,
    required DateTime startedAt,
  }) async {
    final database = await AppDatabase.openFile(file);
    final accountId = AccountId(await database.createAccount(subject.value));
    return _UpdateHarness._(
      database: database,
      accountId: accountId,
      clock: FakeClock(startedAt),
      remote: remote,
      subject: subject,
    );
  }

  static Future<_UpdateHarness> reopen({
    required File file,
    required GoogleTasksService remote,
    required AccountSubject subject,
    required FakeClock clock,
  }) async {
    final database = await AppDatabase.openFile(file);
    final accounts = await database.allAccounts();
    return _UpdateHarness._(
      database: database,
      accountId: AccountId(accounts.single.id),
      clock: clock,
      remote: remote,
      subject: subject,
    );
  }

  final AppDatabase database;
  final AccountId accountId;
  final FakeClock clock;
  final GoogleTasksService remote;
  final AccountSubject subject;

  Future<_SeededRemote> seedRemote({
    required String listTitle,
    required String taskTitle,
    String? notes,
    TaskDate? due,
  }) async {
    final list = switch (await remote.createTaskList(
      CreateTaskListOperation(title: listTitle),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value,
      _ => throw StateError('Synthetic remote list setup failed.'),
    };
    final task = await seedTask(
      list.id,
      title: taskTitle,
      notes: notes,
      due: due,
    );
    expect((await run()).outcome, SyncRunOutcome.succeeded);
    final snapshot = await this.snapshot();
    return _SeededRemote(
      listId: snapshot.taskLists
          .singleWhere(
            (candidate) => candidate.remoteId?.value == list.id.value,
          )
          .id,
      taskId: snapshot.tasks
          .singleWhere(
            (candidate) => candidate.remoteId?.value == task.id.value,
          )
          .id,
      listRemoteId: list.id,
    );
  }

  Future<RemoteLiveTask> seedTask(
    RemoteTaskListId listId, {
    required String title,
    String? notes,
    TaskDate? due,
  }) async => switch (await remote.createTask(
    CreateTaskOperation(
      taskListId: listId,
      title: title,
      notes: notes,
      status: RemoteTaskStatus.needsAction,
      due: due == null ? null : RemoteDate(due.year, due.month, due.day),
    ),
  )) {
    CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) => value,
    _ => throw StateError('Synthetic remote task setup failed.'),
  };

  Future<void> renameList(TaskListId id, String title) async {
    final result =
        await DatabaseTaskListsRepository(
          database: database,
          clock: clock,
        ).renameTaskList(
          RenameTaskListCommand(
            accountId: accountId,
            taskListId: id,
            title: title,
          ),
        );
    expect(result, isA<Success<void>>());
  }

  Future<void> updateTask(
    TaskId id, {
    required String title,
    required String? notes,
    required TaskStatus status,
    required TaskDate? due,
  }) async {
    final result = await DatabaseTasksRepository(database, clock: clock).apply(
      UpdateTaskContentCommand(
        accountId: accountId,
        taskId: id,
        title: title,
        notes: notes,
        status: status,
        due: due,
      ),
    );
    expect(result, isA<Success<void>>());
  }

  Future<SyncRunReport> run({
    SyncRunControl control = const NoopSyncRunControl(),
    DesiredStateTransactionControl? transactionControl,
  }) => SyncEngine(
    store: DatabaseReadSyncStore(
      database,
      transactionControl: transactionControl,
    ),
    googleTasks: remote,
    authorization: SyntheticAuthorization(subject),
    clock: clock,
    random: SequenceRandomSource(
      List<int>.generate(256, (index) => index % 256),
    ),
    control: control,
  ).run(SyncRunRequest(accountId: accountId));

  Future<CachedTasksSnapshot> snapshot() => DatabaseTasksRepository(
    database,
  ).watchTasks(TasksQuery(accountId: accountId)).first;

  Future<void> close() => database.close();
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

final class _UpdateInterceptService implements GoogleTasksService {
  _UpdateInterceptService(this.delegate);

  final FakeGoogleTasksService delegate;
  final List<String> updateLedger = <String>[];
  bool rejectFirstPatch = false;
  bool uncertainNextPatchAfterCommit = false;
  bool uncertainNextRenameAfterCommit = false;
  Future<Object?> Function()? afterNextPatchCommit;
  var _patchCalls = 0;

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
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => delegate.createTask(operation);

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) async {
    updateLedger.add('list:${operation.title}');
    final result = await delegate.renameTaskList(operation);
    if (uncertainNextRenameAfterCommit) {
      uncertainNextRenameAfterCommit = false;
      return const UncertainMutation<RemoteTaskList>(_uncertainUpdateError);
    }
    return result;
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async {
    updateLedger.add('task:${operation.title}');
    _patchCalls += 1;
    if (rejectFirstPatch && _patchCalls == 1) {
      return const RejectedMutation<RemoteTask>(_rejectedUpdateError);
    }
    final result = await delegate.patchTask(operation);
    final callback = afterNextPatchCommit;
    afterNextPatchCommit = null;
    await callback?.call();
    if (uncertainNextPatchAfterCommit) {
      uncertainNextPatchAfterCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertainUpdateError);
    }
    return result;
  }

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => delegate.deleteTaskList(operation);

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

const Failure _rejectedUpdateFailure = Failure(
  code: 'synthetic.update_rejected',
  category: FailureCategory.remote,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The synthetic update was rejected.',
  safeSummary: 'Synthetic update rejection.',
);

const GoogleTasksMutationError _rejectedUpdateError = GoogleTasksMutationError(
  failure: _rejectedUpdateFailure,
  kind: GoogleTasksErrorKind.permanent,
  commitState: MutationCommitState.notCommitted,
);

const Failure _uncertainUpdateFailure = Failure(
  code: 'synthetic.update_uncertain',
  category: FailureCategory.network,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The synthetic update may have committed.',
  safeSummary: 'Synthetic update response was lost.',
);

const GoogleTasksMutationError _uncertainUpdateError = GoogleTasksMutationError(
  failure: _uncertainUpdateFailure,
  kind: GoogleTasksErrorKind.transient,
  commitState: MutationCommitState.uncertain,
);
