import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
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
import 'package:axiotask/src/sync/update_operations.dart';
import 'package:drift/drift.dart' hide isNull;
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
    'REL-014 and CRS-004 claimed update refetches and publishes after restart',
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
        DesiredStateLifecycle.confirmed,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
    },
  );

  test(
    'CRS-005 response-before-ack update confirms by read-back after restart',
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
        DesiredStateLifecycle.confirmed,
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
        DesiredStateLifecycle.confirmed,
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
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
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
    expect(
      (await DesiredStateDao(
        harness.database,
      ).readTaskList(harness.accountId, seeded.listId))?.state,
      DesiredStateLifecycle.confirmed,
    );
  });

  test('REL-014 not-landed task update replays once after read-back', () async {
    final backend = FakeGoogleTasksService();
    addTearDown(backend.close);
    final remote = _UpdateInterceptService(backend)
      ..uncertainNextPatchBeforeCommit = true;
    final harness = await _UpdateHarness.open(
      remote: remote,
      subject: subject,
      startedAt: startedAt,
    );
    addTearDown(harness.close);
    final seeded = await harness.seedRemote(
      listTitle: 'Not-landed update list',
      taskTitle: 'Before not-landed update',
    );
    await harness.updateTask(
      seeded.taskId,
      title: 'Replayed after read-back',
      notes: 'Complete desired snapshot',
      status: TaskStatus.needsAction,
      due: null,
    );

    expect((await harness.run()).outcome, SyncRunOutcome.failed);
    harness.clock.advance(const Duration(minutes: 1));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

    expect(remote.updateLedger, <String>[
      'task:Replayed after read-back',
      'task:Replayed after read-back',
    ]);
    expect(
      (await harness.readRemoteTask(seeded)).title,
      'Replayed after read-back',
    );
  });

  test('REL-014 not-landed list title replays once after read-back', () async {
    final backend = FakeGoogleTasksService();
    addTearDown(backend.close);
    final remote = _UpdateInterceptService(backend)
      ..uncertainNextRenameBeforeCommit = true;
    final harness = await _UpdateHarness.open(
      remote: remote,
      subject: subject,
      startedAt: startedAt,
    );
    addTearDown(harness.close);
    final seeded = await harness.seedRemote(
      listTitle: 'Before not-landed rename',
      taskTitle: 'Unchanged task',
    );
    await harness.renameList(seeded.listId, 'Replayed list title');

    expect((await harness.run()).outcome, SyncRunOutcome.failed);
    harness.clock.advance(const Duration(minutes: 1));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

    expect(remote.updateLedger, <String>[
      'list:Replayed list title',
      'list:Replayed list title',
    ]);
    final lists = switch (await backend.listTaskLists()) {
      Success<RemotePage<RemoteTaskList>>(:final value) => value.items,
      _ => throw StateError('Synthetic list read failed.'),
    };
    expect(lists.single.title, 'Replayed list title');
  });

  test(
    'REL-014 landed older update rebases and publishes the newer generation',
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
        listTitle: 'Generation recovery list',
        taskTitle: 'Generation zero',
      );
      remote.afterNextPatchCommit = () async {
        harness.clock.advance(const Duration(seconds: 1));
        await harness.updateTask(
          seeded.taskId,
          title: 'Generation two',
          notes: 'Newest desired content',
          status: TaskStatus.needsAction,
          due: null,
        );
        return null;
      };
      await harness.updateTask(
        seeded.taskId,
        title: 'Generation one',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      harness.clock.advance(const Duration(minutes: 1));
      final history = InMemoryDiagnosticHistory();
      final recovered = await harness.run(
        diagnostics: ProductionDiagnosticSink(history),
      );

      expect(recovered.outcome, SyncRunOutcome.succeeded);
      expect(remote.updateLedger, <String>[
        'task:Generation one',
        'task:Generation two',
      ]);
      expect((await harness.readRemoteTask(seeded)).title, 'Generation two');
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      final unresolvedOlder =
          await (harness.database.select(
                harness.database.desiredStateAttemptRows,
              )..where(
                (row) =>
                    row.accountId.equals(harness.accountId.value) &
                    row.generation.equals(1) &
                    row.state.equals('uncertain'),
              ))
              .get();
      expect(unresolvedOlder, isEmpty);
      final diagnostic = history.records.singleWhere(
        (record) => record.code == 'sync.uncertain_update_readback_resolved',
      );
      expect(diagnostic.fields, <String, String>{
        'confirmed': '1',
        'superseded': '0',
      });
      expect(diagnostic.renderedText, isNot(contains('Generation')));
    },
  );

  test('REL-014 newer delete wins over an uncertain landed update', () async {
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
      listTitle: 'Delete-wins recovery list',
      taskTitle: 'Before uncertain update',
    );
    remote.afterNextPatchCommit = () async {
      final deleted =
          await DatabaseTasksRepository(
            harness.database,
            clock: harness.clock,
          ).deleteTask(
            DeleteTaskCommand(
              accountId: harness.accountId,
              taskId: seeded.taskId,
            ),
          );
      expect(deleted, isA<Success<TaskDeleteReceipt>>());
      return null;
    };
    await harness.updateTask(
      seeded.taskId,
      title: 'Possibly landed before delete',
      notes: null,
      status: TaskStatus.needsAction,
      due: null,
    );

    expect((await harness.run()).outcome, SyncRunOutcome.failed);
    harness.clock.advance(const Duration(seconds: 30));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

    expect(remote.updateLedger, <String>['task:Possibly landed before delete']);
    expect(backend.callCount(FakeGoogleTasksMethod.deleteTask), 1);
    expect((await harness.snapshot()).tasks, isEmpty);
    final uncertainOlder =
        await (harness.database.select(harness.database.desiredStateAttemptRows)
              ..where(
                (row) =>
                    row.accountId.equals(harness.accountId.value) &
                    row.state.equals('uncertain'),
              ))
            .get();
    expect(uncertainOlder, isEmpty);
  });

  test(
    'REC-001–REC-004 Google replaces the entire older local task record',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: DateTime.utc(2026, 8, 15, 12, 0, 2),
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Conflict list',
        taskTitle: 'Base title',
        notes: 'Base notes',
        due: TaskDate(2026, 8, 20),
      );

      await harness.updateTask(
        seeded.taskId,
        title: 'Older local title',
        notes: null,
        status: TaskStatus.completed,
        due: null,
      );
      await harness.patchRemoteTask(
        seeded,
        title: 'Newer Google title',
        notes: 'Newer Google notes',
        status: RemoteTaskStatus.needsAction,
        due: TaskDate(2026, 8, 22),
      );
      final patchesBeforeRun = remote.callCount(
        FakeGoogleTasksMethod.patchTask,
      );

      final report = await harness.run();
      final projected = (await harness.snapshot()).tasks.single;
      final desired = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, seeded.taskId);

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.googleWonReplacements, 1);
      expect(report.updateOperations, 0);
      expect(projected.title, 'Newer Google title');
      expect(projected.notes, 'Newer Google notes');
      expect(projected.status, TaskStatus.needsAction);
      expect(projected.due, TaskDate(2026, 8, 22));
      expect(desired?.state, DesiredStateLifecycle.superseded);
      expect(
        remote.callCount(FakeGoogleTasksMethod.patchTask),
        patchesBeforeRun,
      );

      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      expect(
        remote.callCount(FakeGoogleTasksMethod.patchTask),
        patchesBeforeRun,
      );
    },
  );

  test('REC-021 Google supersession survives restart without replay', () async {
    final root = await Directory.systemTemp.createTemp(
      'axiotask-s16-supersession-restart-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/isolated.sqlite');
    final remote = FakeGoogleTasksService();
    addTearDown(remote.close);
    var harness = await _UpdateHarness.openFile(
      file: file,
      remote: remote,
      subject: subject,
      startedAt: DateTime.utc(2026, 8, 15, 12, 0, 2),
    );
    final seeded = await harness.seedRemote(
      listTitle: 'Restart conflict list',
      taskTitle: 'Restart base',
      notes: 'Restart base notes',
    );
    await harness.updateTask(
      seeded.taskId,
      title: 'Older offline edit',
      notes: null,
      status: TaskStatus.completed,
      due: null,
    );
    await harness.patchRemoteTask(
      seeded,
      title: 'Newer Google after restart',
      notes: 'Complete Google record',
      status: RemoteTaskStatus.needsAction,
      due: TaskDate(2026, 8, 24),
    );

    expect((await harness.run()).googleWonReplacements, 1);
    final patchesBeforeRestart = remote.callCount(
      FakeGoogleTasksMethod.patchTask,
    );
    final clock = harness.clock;
    await harness.close();

    harness = await _UpdateHarness.reopen(
      file: file,
      remote: remote,
      subject: subject,
      clock: clock,
    );
    addTearDown(harness.close);
    harness.clock.advance(const Duration(minutes: 1));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
    final projected = (await harness.snapshot()).tasks.single;

    expect(projected.title, 'Newer Google after restart');
    expect(projected.notes, 'Complete Google record');
    expect(projected.status, TaskStatus.needsAction);
    expect(projected.due, TaskDate(2026, 8, 24));
    expect(
      (await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, seeded.taskId))?.state,
      DesiredStateLifecycle.superseded,
    );
    expect(
      remote.callCount(FakeGoogleTasksMethod.patchTask),
      patchesBeforeRestart,
    );
  });

  test(
    'REC-001–REC-003 strictly newer local task writes one whole record',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: DateTime.utc(2026, 8, 15, 12, 0, 10),
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Local winner list',
        taskTitle: 'Base title',
        notes: 'Base notes',
        due: TaskDate(2026, 8, 20),
      );

      await harness.updateTask(
        seeded.taskId,
        title: 'Newer local title',
        notes: null,
        status: TaskStatus.completed,
        due: null,
      );
      await harness.patchRemoteTask(
        seeded,
        title: 'Older Google title',
        notes: 'Older Google notes',
        status: RemoteTaskStatus.needsAction,
        due: TaskDate(2026, 8, 21),
      );

      final report = await harness.run();
      final current = await harness.readRemoteTask(seeded);

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.updateOperations, 1);
      expect(report.googleWonReplacements, 0);
      expect(current.title, 'Newer local title');
      expect(current.notes, isNull);
      expect(current.status, RemoteTaskStatus.completed);
      expect(current.due, isNull);
      final enginePatch = remote.calls
          .where((call) => call.operation == FakeGoogleTasksMethod.patchTask)
          .elementAt(1);
      expect(enginePatch.body, <String, Object?>{
        'title': 'Newer local title',
        'notes': null,
        'status': 'completed',
        'due': null,
      });
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'REC-001 and REC-005 Google wins task and list timestamp ties',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: DateTime.utc(2026, 8, 15, 12, 0, 3),
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Base list',
        taskTitle: 'Base task',
      );

      await harness.updateTask(
        seeded.taskId,
        title: 'Tied local task',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );
      await harness.renameList(seeded.listId, 'Tied local list');
      await harness.patchRemoteTask(
        seeded,
        title: 'Tied Google task',
        notes: 'Whole Google record',
        status: RemoteTaskStatus.completed,
        due: null,
      );
      final listResult = await remote.renameTaskList(
        RenameTaskListOperation(
          taskListId: seeded.listRemoteId,
          title: 'Newer Google list',
        ),
      );
      expect(listResult, isA<CommittedMutation<RemoteTaskList>>());

      final report = await harness.run();
      final snapshot = await harness.snapshot();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.googleWonReplacements, 2);
      expect(
        report.googleWonReplacementDetails.map(
          (detail) => (detail.kind, detail.count),
        ),
        <(ContentSupersessionKind, int)>[
          (ContentSupersessionKind.taskContent, 1),
          (ContentSupersessionKind.taskListTitle, 1),
        ],
      );
      expect(snapshot.tasks.single.title, 'Tied Google task');
      expect(snapshot.tasks.single.notes, 'Whole Google record');
      expect(snapshot.taskLists.single.title, 'Newer Google list');
    },
  );

  test(
    'REC-007 missing Google timestamp fails closed without a write',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend);
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: DateTime.utc(2026, 8, 15, 12, 0, 2),
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Timestamp list',
        taskTitle: 'Timestamp base',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Timestamp local',
        notes: null,
        status: TaskStatus.needsAction,
        due: null,
      );
      await harness.patchRemoteTask(
        seeded,
        title: 'Timestamp Google',
        notes: null,
        status: RemoteTaskStatus.needsAction,
        due: null,
      );
      final patchesBeforeRun = remote.updateLedger.length;
      remote.stripTaskUpdatedOnRead = true;

      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure?.code, 'sync.content_conflict_timestamp_invalid');
      expect(remote.updateLedger, hasLength(patchesBeforeRun));
      expect((await harness.snapshot()).tasks.single.title, 'Timestamp local');
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.pending,
      );
    },
  );

  test(
    'REL-012 task 412 refetches and replans the current generation',
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
        listTitle: 'Conditional list',
        taskTitle: 'Conditional base',
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Local survives 412',
        notes: null,
        status: TaskStatus.completed,
        due: null,
      );
      remote.beforeNextPatch = (operation) => backend.patchTask(
        PatchTaskOperation(
          taskListId: operation.taskListId,
          taskId: operation.taskId,
          etag: operation.etag,
          title: 'Racing Google content',
          notes: const OptionalFieldWrite<String>.set('Racing notes'),
          status: RemoteTaskStatus.needsAction,
          due: const OptionalFieldWrite<RemoteDate>.clear(),
        ),
      );

      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.conditionalReplans, 1);
      expect(report.updateOperations, 2);
      expect(remote.updateLedger, <String>[
        'task:Local survives 412',
        'task:Local survives 412',
      ]);
      expect(
        (await harness.snapshot()).tasks.single.title,
        'Local survives 412',
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'REC-004 Google completion cascade supersedes an impossible child reopen',
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
        listTitle: 'Cascade list',
        taskTitle: 'Completed parent',
      );
      await harness.patchRemoteTask(
        seeded,
        title: 'Completed parent',
        notes: null,
        status: RemoteTaskStatus.completed,
        due: null,
      );
      final child = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Completed child',
        parentId: seeded.taskRemoteId,
      );
      await harness.run();
      final childId = (await harness.snapshot()).tasks
          .singleWhere((task) => task.remoteId?.value == child.id.value)
          .id;

      await harness.updateTask(
        childId,
        title: 'Requested child reopen',
        notes: 'Must stay one whole record',
        status: TaskStatus.needsAction,
        due: null,
      );
      final report = await harness.run();
      final projected = (await harness.snapshot()).tasks.singleWhere(
        (task) => task.id == childId,
      );

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.googleWonReplacements, 1);
      expect(
        report.googleWonReplacementDetails.single.kind,
        ContentSupersessionKind.completionCascade,
      );
      expect(report.googleWonReplacementDetails.single.count, 1);
      expect(projected.title, 'Requested child reopen');
      expect(projected.notes, 'Must stay one whole record');
      expect(projected.status, TaskStatus.completed);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, childId))?.state,
        DesiredStateLifecycle.superseded,
      );
    },
  );

  test(
    'REC-011/REC-012 cross-list MOVE preserves a subtree and adopts canonical order',
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
        listTitle: 'Source',
        taskTitle: 'Moving root',
      );
      final child = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Moving child',
        parentId: seeded.taskRemoteId,
      );
      final destination = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Destination'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic destination setup failed.'),
      };
      final anchor = await harness.seedTask(destination.id, title: 'Anchor');
      await harness.run();
      final before = await harness.snapshot();
      final destinationId = before.taskLists
          .singleWhere((list) => list.remoteId?.value == destination.id.value)
          .id;
      final anchorId = before.tasks
          .singleWhere((task) => task.remoteId?.value == anchor.id.value)
          .id;
      final childId = before.tasks
          .singleWhere((task) => task.remoteId?.value == child.id.value)
          .id;

      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: destinationId,
        previousTaskId: anchorId,
      );
      await harness.updateTask(
        seeded.taskId,
        title: 'Moved and edited',
        notes: 'Independent content facet',
        status: TaskStatus.needsAction,
        due: null,
      );
      final report = await harness.run();
      final moveCall = remote.calls.lastWhere(
        (call) => call.operation == FakeGoogleTasksMethod.moveTask,
      );
      final after = await harness.snapshot();
      final root = after.tasks.singleWhere((task) => task.id == seeded.taskId);
      final projectedChild = after.tasks.singleWhere(
        (task) => task.id == childId,
      );

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.moveOperations, 1);
      expect(report.updateOperations, 0);
      expect(moveCall.query['destinationTasklist'], destination.id.value);
      expect(moveCall.query['previous'], anchor.id.value);
      expect(root.taskListId, destinationId);
      expect(root.parentTaskId, isNull);
      expect(root.title, 'Moved and edited');
      expect(projectedChild.taskListId, destinationId);
      expect(projectedChild.parentTaskId, seeded.taskId);
      expect(
        after.tasks.indexWhere((task) => task.id == anchorId),
        lessThan(after.tasks.indexWhere((task) => task.id == seeded.taskId)),
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.pending,
      );
      harness.clock.advance(const Duration(minutes: 1));
      final contentReport = await harness.run();
      expect(contentReport.updateOperations, 1);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.moveTask), 1);

      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: seeded.listId,
      );
      harness.clock.advance(const Duration(minutes: 1));
      final repeatedMove = await harness.run();
      final returned = await harness.snapshot();
      expect(repeatedMove.moveOperations, 1);
      expect(remote.callCount(FakeGoogleTasksMethod.moveTask), 2);
      expect(
        returned.tasks
            .singleWhere((task) => task.id == seeded.taskId)
            .taskListId,
        seeded.listId,
      );
      expect(
        returned.tasks.singleWhere((task) => task.id == childId).taskListId,
        seeded.listId,
      );
    },
  );

  test(
    'REC-008/REC-009 concurrent remote placement wins without oscillation',
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
        listTitle: 'Concurrent list',
        taskTitle: 'First',
      );
      final second = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Second',
      );
      final third = await harness.seedTask(seeded.listRemoteId, title: 'Third');
      await harness.run();
      final snapshot = await harness.snapshot();
      final secondId = snapshot.tasks
          .singleWhere((task) => task.remoteId?.value == second.id.value)
          .id;
      final thirdId = snapshot.tasks
          .singleWhere((task) => task.remoteId?.value == third.id.value)
          .id;

      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: seeded.listId,
        previousTaskId: secondId,
      );
      final current = await (harness.database.select(
        harness.database.taskRemoteBases,
      )..where((row) => row.taskId.equals(seeded.taskId.value))).getSingle();
      expect(
        await remote.moveTask(
          MoveTaskOperation(
            sourceTaskListId: seeded.listRemoteId,
            taskId: seeded.taskRemoteId,
            etag: current.etag!,
            pathFreshness: MutationPathFreshness.current,
            previousId: third.id,
          ),
        ),
        isA<CommittedMutation<RemoteTask>>(),
      );
      final movesBeforeReconcile = remote.callCount(
        FakeGoogleTasksMethod.moveTask,
      );
      final report = await harness.run();
      final after = await harness.snapshot();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.googleWonStructures, 1);
      expect(report.moveOperations, 0);
      expect(after.tasks.map((task) => task.id).toList(), <TaskId>[
        thirdId,
        seeded.taskId,
        secondId,
      ]);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.superseded,
      );
      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(
        remote.callCount(FakeGoogleTasksMethod.moveTask),
        movesBeforeReconcile,
      );
    },
  );

  test(
    'REC-017 deleted previous anchor supersedes MOVE without replay',
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
        listTitle: 'Anchor race',
        taskTitle: 'Move target',
      );
      final anchor = await harness.seedTask(
        seeded.listRemoteId,
        title: 'Anchor',
      );
      await harness.run();
      final snapshot = await harness.snapshot();
      final anchorId = snapshot.tasks
          .singleWhere((task) => task.remoteId?.value == anchor.id.value)
          .id;
      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: seeded.listId,
        previousTaskId: anchorId,
      );
      final anchorBase = await (harness.database.select(
        harness.database.taskRemoteBases,
      )..where((row) => row.taskId.equals(anchorId.value))).getSingle();
      expect(
        await remote.deleteTask(
          DeleteTaskOperation(
            taskListId: seeded.listRemoteId,
            taskId: anchor.id,
            etag: anchorBase.etag!,
            pathFreshness: MutationPathFreshness.current,
          ),
        ),
        isA<CommittedMutation<void>>(),
      );
      final movesBefore = remote.callCount(FakeGoogleTasksMethod.moveTask);

      final report = await harness.run();

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.moveOperations, 0);
      expect(report.googleWonStructures, 1);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, seeded.taskId))?.state,
        DesiredStateLifecycle.superseded,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.moveTask), movesBefore);
    },
  );

  test(
    'REL-016 landed older move rebases and publishes the newer move',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend)
        ..uncertainNextMoveAfterCommit = true;
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Move generation source',
        taskTitle: 'Move generation target',
      );
      final destinationOne = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Move destination one'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic destination setup failed.'),
      };
      final destinationTwo = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Move destination two'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic destination setup failed.'),
      };
      await harness.run();
      final listed = await harness.snapshot();
      final destinationOneId = listed.taskLists
          .singleWhere(
            (list) => list.remoteId?.value == destinationOne.id.value,
          )
          .id;
      final destinationTwoId = listed.taskLists
          .singleWhere(
            (list) => list.remoteId?.value == destinationTwo.id.value,
          )
          .id;
      remote.afterNextMoveCommit = () => harness.moveTask(
        seeded.taskId,
        destinationTaskListId: destinationTwoId,
      );
      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: destinationOneId,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      harness.clock.advance(const Duration(minutes: 1));
      final history = InMemoryDiagnosticHistory();
      final recovered = await harness.run(
        diagnostics: ProductionDiagnosticSink(history),
      );

      expect(recovered.outcome, SyncRunOutcome.succeeded);
      expect(remote.moveLedger, <String>[
        destinationOne.id.value,
        destinationTwo.id.value,
      ]);
      expect(
        (await harness.snapshot()).tasks
            .singleWhere((task) => task.id == seeded.taskId)
            .taskListId,
        destinationTwoId,
      );
      final destinationRemoteTasks = switch (await backend.listTasks(
        destinationTwo.id,
      )) {
        Success<RemotePage<RemoteTask>>(:final value) => value.items,
        _ => throw StateError('Synthetic destination read failed.'),
      };
      expect(
        destinationRemoteTasks.whereType<RemoteLiveTask>().map(
          (task) => task.id,
        ),
        contains(seeded.taskRemoteId),
      );
      final diagnostic = history.records.singleWhere(
        (record) => record.code == 'sync.uncertain_move_readback_resolved',
      );
      expect(diagnostic.fields, <String, String>{
        'confirmed': '1',
        'superseded': '0',
      });
      expect(diagnostic.renderedText, isNot(contains('Move generation')));
    },
  );

  test(
    'REL-016 not-landed move replays once after placement read-back',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final remote = _UpdateInterceptService(backend)
        ..uncertainNextMoveBeforeCommit = true;
      final harness = await _UpdateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final seeded = await harness.seedRemote(
        listTitle: 'Not-landed move source',
        taskTitle: 'Not-landed move target',
      );
      final destination = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Not-landed move destination'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic destination setup failed.'),
      };
      await harness.run();
      final destinationId = (await harness.snapshot()).taskLists
          .singleWhere((list) => list.remoteId?.value == destination.id.value)
          .id;
      await harness.moveTask(
        seeded.taskId,
        destinationTaskListId: destinationId,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      expect(remote.moveLedger, <String>[
        destination.id.value,
        destination.id.value,
      ]);
      expect(
        (await harness.snapshot()).tasks
            .singleWhere((task) => task.id == seeded.taskId)
            .taskListId,
        destinationId,
      );
    },
  );
}

final class _SeededRemote {
  const _SeededRemote({
    required this.listId,
    required this.taskId,
    required this.listRemoteId,
    required this.taskRemoteId,
  });

  final TaskListId listId;
  final TaskId taskId;
  final RemoteTaskListId listRemoteId;
  final RemoteTaskId taskRemoteId;
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
      taskRemoteId: task.id,
    );
  }

  Future<RemoteLiveTask> patchRemoteTask(
    _SeededRemote seeded, {
    required String title,
    required String? notes,
    required RemoteTaskStatus status,
    required TaskDate? due,
  }) async {
    final current = switch (await remote.listTasks(seeded.listRemoteId)) {
      Success<RemotePage<RemoteTask>>(:final value) =>
        value.items.whereType<RemoteLiveTask>().singleWhere(
          (task) => task.id.value == seeded.taskRemoteId.value,
        ),
      _ => throw StateError('Synthetic remote task read failed.'),
    };
    return switch (await remote.patchTask(
      PatchTaskOperation(
        taskListId: seeded.listRemoteId,
        taskId: seeded.taskRemoteId,
        etag: current.etag!,
        title: title,
        notes: notes == null
            ? const OptionalFieldWrite<String>.clear()
            : OptionalFieldWrite<String>.set(notes),
        status: status,
        due: due == null
            ? const OptionalFieldWrite<RemoteDate>.clear()
            : OptionalFieldWrite<RemoteDate>.set(
                RemoteDate(due.year, due.month, due.day),
              ),
      ),
    )) {
      CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) => value,
      _ => throw StateError('Synthetic remote task mutation failed.'),
    };
  }

  Future<RemoteLiveTask> readRemoteTask(_SeededRemote seeded) async =>
      switch (await remote.listTasks(seeded.listRemoteId)) {
        Success<RemotePage<RemoteTask>>(:final value) =>
          value.items.whereType<RemoteLiveTask>().singleWhere(
            (task) => task.id.value == seeded.taskRemoteId.value,
          ),
        _ => throw StateError('Synthetic remote task read failed.'),
      };

  Future<RemoteLiveTask> seedTask(
    RemoteTaskListId listId, {
    required String title,
    String? notes,
    TaskDate? due,
    RemoteTaskId? parentId,
  }) async => switch (await remote.createTask(
    CreateTaskOperation(
      taskListId: listId,
      title: title,
      notes: notes,
      status: RemoteTaskStatus.needsAction,
      due: due == null ? null : RemoteDate(due.year, due.month, due.day),
      parentId: parentId,
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

  Future<void> moveTask(
    TaskId id, {
    required TaskListId destinationTaskListId,
    TaskId? parentTaskId,
    TaskId? previousTaskId,
  }) async {
    final result = await DatabaseTasksRepository(database, clock: clock).apply(
      MoveTaskCommand(
        accountId: accountId,
        taskId: id,
        destinationTaskListId: destinationTaskListId,
        parentTaskId: parentTaskId,
        previousTaskId: previousTaskId,
      ),
    );
    expect(result, isA<Success<void>>());
  }

  Future<SyncRunReport> run({
    SyncRunControl control = const NoopSyncRunControl(),
    DesiredStateTransactionControl? transactionControl,
    DiagnosticSink? diagnostics,
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
    diagnostics: diagnostics,
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
  bool uncertainNextPatchBeforeCommit = false;
  bool uncertainNextRenameAfterCommit = false;
  bool uncertainNextRenameBeforeCommit = false;
  bool uncertainNextMoveAfterCommit = false;
  bool uncertainNextMoveBeforeCommit = false;
  bool stripTaskUpdatedOnRead = false;
  Future<Object?> Function(PatchTaskOperation operation)? beforeNextPatch;
  Future<Object?> Function()? afterNextPatchCommit;
  Future<Object?> Function()? afterNextMoveCommit;
  final List<String> moveLedger = <String>[];
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
  }) async {
    final result = await delegate.listTasks(
      taskListId,
      pageToken: pageToken,
      cancellation: cancellation,
    );
    if (!stripTaskUpdatedOnRead) return result;
    return switch (result) {
      Success<RemotePage<RemoteTask>>(:final value) => Outcome.success(
        RemotePage<RemoteTask>(
          items: value.items.map(_withoutUpdated).toList(growable: false),
          collectionEtag: value.collectionEtag,
          nextPageToken: value.nextPageToken,
        ),
      ),
      Failed<RemotePage<RemoteTask>>(:final failure) => Outcome.failure(
        failure,
      ),
    };
  }

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
    if (uncertainNextRenameBeforeCommit) {
      uncertainNextRenameBeforeCommit = false;
      return const UncertainMutation<RemoteTaskList>(_uncertainUpdateError);
    }
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
    if (uncertainNextPatchBeforeCommit) {
      uncertainNextPatchBeforeCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertainUpdateError);
    }
    if (rejectFirstPatch && _patchCalls == 1) {
      return const RejectedMutation<RemoteTask>(_rejectedUpdateError);
    }
    final before = beforeNextPatch;
    beforeNextPatch = null;
    await before?.call(operation);
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
  ) async {
    moveLedger.add(
      operation.destinationTaskListId?.value ??
          operation.sourceTaskListId.value,
    );
    if (uncertainNextMoveBeforeCommit) {
      uncertainNextMoveBeforeCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertainUpdateError);
    }
    final result = await delegate.moveTask(operation);
    final callback = afterNextMoveCommit;
    afterNextMoveCommit = null;
    await callback?.call();
    if (uncertainNextMoveAfterCommit) {
      uncertainNextMoveAfterCommit = false;
      return const UncertainMutation<RemoteTask>(_uncertainUpdateError);
    }
    return result;
  }

  @override
  void close() {}
}

RemoteTask _withoutUpdated(RemoteTask value) => switch (value) {
  RemoteLiveTask() => RemoteLiveTask(
    id: value.id,
    etag: value.etag,
    updated: null,
    selfLink: value.selfLink,
    title: value.title,
    parentId: value.parentId,
    position: value.position,
    notes: value.notes,
    status: value.status,
    due: value.due,
    completed: value.completed,
    hidden: value.hidden,
    links: value.links,
    webViewLink: value.webViewLink,
  ),
  RemoteTaskTombstone() => RemoteTaskTombstone(
    id: value.id,
    etag: value.etag,
    updated: null,
    selfLink: value.selfLink,
    retainedTitle: value.retainedTitle,
    retainedParentId: value.retainedParentId,
    retainedPosition: value.retainedPosition,
    retainedNotes: value.retainedNotes,
    retainedStatus: value.retainedStatus,
    retainedDue: value.retainedDue,
    retainedCompleted: value.retainedCompleted,
    hidden: value.hidden,
    retainedLinks: value.retainedLinks,
    retainedWebViewLink: value.retainedWebViewLink,
  ),
};

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
