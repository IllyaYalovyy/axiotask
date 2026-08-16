import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/run.dart';

const _startedAt = '2026-08-15T12:00:00.000Z';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Expected a boundary mode and isolated database path.');
    exitCode = 64;
    return;
  }
  final mode = arguments[0];
  final database = await AppDatabase.openFile(File(arguments[1]));
  final account = AccountId(
    await database.createAccount('synthetic-process-death-subject'),
  );
  final clock = ManualClock(DateTime.parse(_startedAt));

  switch (mode) {
    case 'local_before_commit':
      final repository = DatabaseTaskListsRepository(
        database: database,
        clock: clock,
        transactionControl: (boundary) async {
          if (boundary == DesiredStateTransactionBoundary.beforeLocalCommit) {
            await _boundary();
          }
        },
      );
      await repository.createTaskList(
        CreateTaskListCommand(accountId: account, title: 'Pending list'),
      );
    case 'local_after_commit':
      await _createList(database, account, clock, 'Pending list');
      await _boundary();
    case 'run_after_begin':
      await _createList(database, account, clock, 'Pending list');
      await DatabaseReadSyncStore(database).beginReadRun(
        accountId: account,
        runId: const SyncRunId('synthetic-run'),
        triggers: const <String>{'startup'},
        startedAt: clock.now(),
      );
      await _boundary();
    case 'claim_in_flight':
      final list = await _createList(database, account, clock, 'Pending list');
      await DesiredStateDao(database).claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      await _boundary();
    case 'ack_after_identity' || 'ack_after_base' || 'ack_before_commit':
      final list = await _createList(database, account, clock, 'Pending list');
      final attempt = await DesiredStateDao(database).claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      final target = switch (mode) {
        'ack_after_identity' =>
          DesiredStateTransactionBoundary.afterRemoteIdentityWrite,
        'ack_after_base' =>
          DesiredStateTransactionBoundary.afterRemoteBaseWrite,
        _ => DesiredStateTransactionBoundary.beforeRemoteCommit,
      };
      await DesiredStateDao(
        database,
        transactionControl: (boundary) async {
          if (boundary == target) await _boundary();
        },
      ).acknowledgeTaskList(
        accountId: account,
        attemptId: attempt.id,
        remoteId: const TaskListRemoteId('remote-created-list'),
        title: 'Canonical remote title',
        etag: 'canonical-etag',
        remoteUpdatedAt: DateTime.utc(2026, 8, 15, 12, 10),
        observedPublicationId: 'synthetic-observation',
        acknowledgedAt: DateTime.utc(2026, 8, 15, 12, 15),
      );
    case 'ack_after_commit':
      final list = await _createList(database, account, clock, 'Pending list');
      await _acknowledgeList(database, account, list);
      await _boundary();
    case 'partial_acknowledgement':
      final first = await _createList(database, account, clock, 'First');
      await DatabaseTasksRepository(database, clock: clock).createTask(
        CreateTaskCommand(
          accountId: account,
          taskListId: first,
          title: 'Dependent task',
        ),
      );
      await _acknowledgeList(database, account, first);
      await _boundary();
    case 'page_before_commit':
      await _beginRun(database, account, clock);
      await _boundary();
    case 'page_after_commit':
      final store = await _beginRun(database, account, clock);
      await store.publishTaskListPage(
        accountId: account,
        runId: const SyncRunId('synthetic-run'),
        items: <RemoteTaskList>[_remoteList],
        nextPageToken: const PageToken('unreached-page'),
        collectionEtag: 'synthetic-collection-etag',
      );
      await _boundary();
    case 'finalize_before_commit':
      await _completeRun(database, account, clock);
      await _boundary();
    case 'finalize_after_commit':
      final store = await _completeRun(database, account, clock);
      await store.finalizeReadSuccess(
        accountId: account,
        runId: const SyncRunId('synthetic-run'),
        completedAt: DateTime.utc(2026, 8, 15, 12, 30),
      );
      await _boundary();
    case 'stale_finalizer_after_rejection':
      final store = DatabaseReadSyncStore(database);
      const older = SyncRunId('synthetic-older-run');
      const newer = SyncRunId('synthetic-newer-run');
      await store.beginReadRun(
        accountId: account,
        runId: older,
        triggers: const <String>{'startup'},
        startedAt: clock.now(),
      );
      await store.publishTaskListPage(
        accountId: account,
        runId: older,
        items: const <RemoteTaskList>[],
        nextPageToken: null,
        collectionEtag: null,
      );
      await store.beginReadRun(
        accountId: account,
        runId: newer,
        triggers: const <String>{'follow_up'},
        startedAt: DateTime.utc(2026, 8, 15, 12, 20),
      );
      final accepted = await store.finalizeReadSuccess(
        accountId: account,
        runId: older,
        completedAt: DateTime.utc(2026, 8, 15, 12, 30),
      );
      if (accepted) throw StateError('Stale finalizer was accepted.');
      await _boundary();
    case 'recovery_before_commit' || 'recovery_after_commit':
      final list = await _createList(database, account, clock, 'Pending list');
      await DesiredStateDao(database).claimTaskList(
        accountId: account,
        taskListId: list,
        claimedAt: clock.now(),
      );
      await DatabaseReadSyncStore(database).beginReadRun(
        accountId: account,
        runId: const SyncRunId('synthetic-run'),
        triggers: const <String>{'startup'},
        startedAt: clock.now(),
      );
      await DatabaseReadSyncStore(
        database,
        recoveryTransactionControl: (boundary) async {
          if (mode == 'recovery_before_commit') await _boundary();
        },
      ).recoverStartup(
        accountId: account,
        recoveredAt: DateTime.utc(2026, 8, 15, 12, 30),
      );
      await _boundary();
    default:
      stderr.writeln('Unknown boundary mode.');
      exitCode = 64;
  }
}

Future<TaskListId> _createList(
  AppDatabase database,
  AccountId account,
  Clock clock,
  String title,
) async {
  final outcome = await DatabaseTaskListsRepository(
    database: database,
    clock: clock,
  ).createTaskList(CreateTaskListCommand(accountId: account, title: title));
  return (outcome as Success<TaskListId>).value;
}

Future<void> _acknowledgeList(
  AppDatabase database,
  AccountId account,
  TaskListId list,
) async {
  final attempt = await DesiredStateDao(database).claimTaskList(
    accountId: account,
    taskListId: list,
    claimedAt: DateTime.utc(2026, 8, 15, 12, 5),
  );
  await DesiredStateDao(database).acknowledgeTaskList(
    accountId: account,
    attemptId: attempt.id,
    remoteId: const TaskListRemoteId('remote-created-list'),
    title: 'Canonical remote title',
    etag: 'canonical-etag',
    remoteUpdatedAt: DateTime.utc(2026, 8, 15, 12, 10),
    observedPublicationId: 'synthetic-observation',
    acknowledgedAt: DateTime.utc(2026, 8, 15, 12, 15),
  );
}

Future<DatabaseReadSyncStore> _beginRun(
  AppDatabase database,
  AccountId account,
  Clock clock,
) async {
  final store = DatabaseReadSyncStore(database);
  await store.beginReadRun(
    accountId: account,
    runId: const SyncRunId('synthetic-run'),
    triggers: const <String>{'startup'},
    startedAt: clock.now(),
  );
  return store;
}

Future<DatabaseReadSyncStore> _completeRun(
  AppDatabase database,
  AccountId account,
  Clock clock,
) async {
  final store = await _beginRun(database, account, clock);
  await store.publishTaskListPage(
    accountId: account,
    runId: const SyncRunId('synthetic-run'),
    items: const <RemoteTaskList>[],
    nextPageToken: null,
    collectionEtag: null,
  );
  return store;
}

Future<Never> _boundary() async {
  stdout.writeln('DURABLE_BOUNDARY');
  await stdout.flush();
  await Completer<void>().future;
  throw StateError('Unreachable boundary released.');
}

final RemoteTaskList _remoteList = RemoteTaskList(
  id: const RemoteTaskListId('process-list'),
  etag: 'process-etag',
  title: 'Committed process page',
  updated: DateTime.utc(2026, 8, 15, 11),
  selfLink: Uri.parse('https://example.invalid/process-list'),
);
