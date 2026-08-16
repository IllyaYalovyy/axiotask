import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/bulk_operations.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';
import '../support/multi_host.dart';

void main() {
  const subject = AccountSubject('synthetic-create-sync-subject');
  final startedAt = DateTime.utc(2026, 8, 15, 12);

  test(
    'RUN-013 publishes list, parent, then child and binds stable local IDs',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _CreateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final list = await harness.createList('Offline list');
      final parent = await harness.createTask(list, 'Offline parent');
      final child = await harness.createTask(
        list,
        'Offline child',
        parentTaskId: parent,
      );

      final report = await harness.run();
      final snapshot = await harness.snapshot();
      final createCalls = remote.calls
          .where(
            (call) =>
                call.operation == FakeGoogleTasksMethod.createTaskList ||
                call.operation == FakeGoogleTasksMethod.createTask,
          )
          .toList(growable: false);

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(createCalls.map((call) => call.operation), <FakeGoogleTasksMethod>[
        FakeGoogleTasksMethod.createTaskList,
        FakeGoogleTasksMethod.createTask,
        FakeGoogleTasksMethod.createTask,
      ]);
      expect(createCalls[0].body, <String, Object?>{'title': 'Offline list'});
      expect(createCalls[1].query, isEmpty);
      expect(createCalls[1].body?['title'], 'Offline parent');
      expect(createCalls[2].query['parent'], isNotEmpty);
      expect(createCalls[2].body?['title'], 'Offline child');

      expect(snapshot.taskLists.single.id, list);
      expect(snapshot.taskLists.single.remoteId, isNotNull);
      expect(
        snapshot.tasks.singleWhere((task) => task.id == parent).remoteId,
        isNotNull,
      );
      expect(
        snapshot.tasks.singleWhere((task) => task.id == child).remoteId,
        isNotNull,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTaskList(harness.accountId, list))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, parent))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, child))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );

  test(
    'identical creates remain independent and confirmed creates do not replay',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final harness = await _CreateHarness.open(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final list = await harness.createList('Duplicate-safe list');
      final first = await harness.createTask(list, 'Same content');
      final second = await harness.createTask(list, 'Same content');

      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final afterFirstRun = await harness.snapshot();
      final firstRemoteId = afterFirstRun.tasks
          .singleWhere((task) => task.id == first)
          .remoteId;
      final secondRemoteId = afterFirstRun.tasks
          .singleWhere((task) => task.id == second)
          .remoteId;
      expect(firstRemoteId, isNotNull);
      expect(secondRemoteId, isNotNull);
      expect(firstRemoteId, isNot(secondRemoteId));
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 2);

      harness.clock.advance(const Duration(minutes: 1));
      final finalReport = await harness.run();
      expect(
        finalReport.outcome,
        SyncRunOutcome.succeeded,
        reason: finalReport.failure?.code,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 2);
    },
  );

  test(
    'REL-004 partial success keeps independent work and suppresses dependents',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final service = _CreateInterceptService(remote)..rejectFirstList = true;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final failedList = await harness.createList('Failed dependency');
      final failedChild = await harness.createTask(failedList, 'Must not send');
      final safeList = await harness.createList('Independent list');
      final safeTask = await harness.createTask(safeList, 'Independent task');

      final report = await harness.run();
      final snapshot = await harness.snapshot();

      expect(report.outcome, SyncRunOutcome.failed);
      expect(service.createLedger, <String>[
        'list:Failed dependency',
        'list:Independent list',
        'task:Independent task',
      ]);
      expect(
        snapshot.taskLists
            .singleWhere((list) => list.id == failedList)
            .remoteId,
        isNull,
      );
      expect(
        snapshot.tasks.singleWhere((task) => task.id == failedChild).remoteId,
        isNull,
      );
      expect(
        snapshot.taskLists.singleWhere((list) => list.id == safeList).remoteId,
        isNotNull,
      );
      expect(
        snapshot.tasks.singleWhere((task) => task.id == safeTask).remoteId,
        isNotNull,
      );

      final confirmedCallCount = service.createLedger.length;
      harness.clock.advance(const Duration(minutes: 1));
      await harness.run();
      expect(service.createLedger.length, confirmedCallCount);
    },
  );

  test(
    'PAR-BULK-002 failed parent publication leaves its bulk child waiting',
    () async {
      final backend = FakeGoogleTasksService();
      addTearDown(backend.close);
      final service = _CreateInterceptService(backend);
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final list = await harness.createList('Bulk dependency list');
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final parent = await harness.createTask(list, 'Rejected bulk parent');
      final child = await harness.createTask(
        list,
        'Waiting bulk child',
        parentTaskId: parent,
      );
      final repository = DatabaseTasksRepository(
        harness.database,
        clock: harness.clock,
      );
      final accepted = await repository.applyBulk(
        BulkCompleteTasksCommand(
          accountId: harness.accountId,
          taskIds: <TaskId>{parent, child},
        ),
      );
      expect(
        (accepted as Success<BulkOperationReceipt>).value.summary.pendingCount,
        2,
      );
      service.rejectFirstTask = true;

      final report = await harness.run();
      final summary = await repository
          .watchLatestBulkOperation(harness.accountId)
          .first;

      expect(report.outcome, SyncRunOutcome.failed);
      expect(service.createLedger.last, 'task:Rejected bulk parent');
      expect(service.createLedger, isNot(contains('task:Waiting bulk child')));
      expect(summary?.confirmedCount, 0);
      expect(summary?.pendingCount, 1);
      expect(summary?.failedCount, 1);
    },
  );

  test(
    'REL-013 uncertain create retries without content matching and diagnoses duplicate risk',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Confirmed list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final service = _CreateInterceptService(remote);
      final releaseHistory = InMemoryDiagnosticHistory();
      final developmentHistory = InMemoryDiagnosticHistory();
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
        diagnostics: _FanoutDiagnosticSink(<DiagnosticSink>[
          ProductionDiagnosticSink(releaseHistory),
          SensitiveDevelopmentDiagnosticSink(developmentHistory),
        ]),
      );
      addTearDown(harness.close);
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final confirmedList = (await harness.snapshot()).taskLists.singleWhere(
        (list) => list.remoteId?.value == remoteList.value,
      );
      final provisional = await harness.createTask(
        confirmedList.id,
        'Identical visible content',
      );
      service.uncertainNextTaskAfterCommit = true;

      final uncertain = await harness.run();

      expect(uncertain.outcome, SyncRunOutcome.failed);
      expect(
        (await DesiredStateDao(
          harness.database,
        ).readTask(harness.accountId, provisional))?.state,
        DesiredStateLifecycle.uncertain,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);

      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final matching = (await harness.snapshot()).tasks
          .where((task) => task.title == 'Identical visible content')
          .toList(growable: false);
      expect(matching, hasLength(2));
      expect(matching.map((task) => task.id).toSet(), hasLength(2));
      expect(
        matching.singleWhere((task) => task.id == provisional).remoteId,
        isNotNull,
      );
      expect(
        matching.singleWhere((task) => task.id != provisional).remoteId,
        isNotNull,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 2);
      final releaseRecord = releaseHistory.records.singleWhere(
        (record) => record.code == 'sync.create_recovery_duplicate_possible',
      );
      final developmentRecord = developmentHistory.records.singleWhere(
        (record) => record.code == 'sync.create_recovery_duplicate_possible',
      );
      expect(releaseRecord.fields, containsPair('resource_kind', 'task'));
      expect(releaseRecord.fields, isNot(contains('title')));
      expect(
        developmentRecord.fields,
        allOf(
          containsPair('resource_kind', 'task'),
          containsPair('title', 'Identical visible content'),
        ),
      );
    },
  );

  test(
    'REL-013 repeated response loss retries the original generation and preserves a newer edit',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Recovery list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final service = _CreateInterceptService(remote)
        ..uncertainTaskResponsesAfterCommit = 2;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final list = (await harness.snapshot()).taskLists.singleWhere(
        (candidate) => candidate.remoteId?.value == remoteList.value,
      );
      final task = await harness.createTask(list.id, 'Generation one');

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      expect(
        await DatabaseTasksRepository(
          harness.database,
          clock: harness.clock,
        ).apply(
          SetTaskTitleCommand(
            accountId: harness.accountId,
            taskId: task,
            title: 'Generation two',
          ),
        ),
        isA<Success<void>>(),
      );

      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      harness.clock.advance(const Duration(minutes: 1));
      final updatedReport = await harness.run();
      expect(
        updatedReport.outcome,
        SyncRunOutcome.succeeded,
        reason: updatedReport.failure?.code,
      );

      final projected = (await harness.snapshot()).tasks.singleWhere(
        (candidate) => candidate.id == task,
      );
      final desired = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, task);
      expect(projected.remoteId, isNotNull);
      expect(projected.title, 'Generation two');
      expect(desired?.generation, 2);
      expect(desired?.state, DesiredStateLifecycle.confirmed);
      expect(desired?.baseTitle, 'Generation two');
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 3);
      expect(remote.callCount(FakeGoogleTasksMethod.patchTask), 1);
      expect(
        (await harness.database
                .customSelect(
                  'SELECT COUNT(*) AS count FROM desired_state_attempts '
                  "WHERE account_id = ${harness.accountId.value} AND state = 'uncertain'",
                )
                .getSingle())
            .read<int>('count'),
        2,
      );
    },
  );

  test(
    'REL-013 recovered list create releases its provisional task dependency',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final service = _CreateInterceptService(remote)
        ..uncertainListResponsesAfterCommit = 1;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final list = await harness.createList('Uncertain parent list');

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      final task = await harness.createTask(list, 'Dependent task');
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      final snapshot = await harness.snapshot();
      expect(
        snapshot.taskLists
            .singleWhere((candidate) => candidate.id == list)
            .remoteId,
        isNotNull,
      );
      expect(
        snapshot.tasks
            .singleWhere((candidate) => candidate.id == task)
            .remoteId,
        isNotNull,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 2);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
    },
  );

  test(
    'REL-013 recovered parent create releases its provisional child dependency',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Parent recovery list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final service = _CreateInterceptService(remote)
        ..uncertainTaskResponsesAfterCommit = 1;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final list = (await harness.snapshot()).taskLists.singleWhere(
        (candidate) => candidate.remoteId?.value == remoteList.value,
      );
      final parent = await harness.createTask(list.id, 'Uncertain parent');
      final child = await harness.createTask(
        list.id,
        'Dependent child',
        parentTaskId: parent,
      );

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      final snapshot = await harness.snapshot();
      expect(
        snapshot.tasks
            .singleWhere((candidate) => candidate.id == parent)
            .remoteId,
        isNotNull,
      );
      expect(
        snapshot.tasks
            .singleWhere((candidate) => candidate.id == child)
            .remoteId,
        isNotNull,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 3);
    },
  );

  test(
    'API-004 multi-host enumeration keeps every accepted duplicate independent',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Shared recovery list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final service = _CreateInterceptService(remote);
      final hosts = await MultiHostHarness.create(
        hostCount: 2,
        googleTasks: service,
        accountSubject: subject,
        initialWallTime: startedAt,
        seed: 20004,
      );
      addTearDown(hosts.close);
      final accounts = <AccountId>[];
      for (final host in hosts.hosts) {
        accounts.add(AccountId(await host.store.createAccount(subject.value)));
      }
      for (var index = 0; index < 2; index += 1) {
        expect(
          (await _runHost(hosts.hosts[index], accounts[index])).outcome,
          SyncRunOutcome.succeeded,
        );
      }
      final hostOneList =
          (await DatabaseTasksRepository(
                hosts.hosts[0].store,
              ).watchTasks(TasksQuery(accountId: accounts[0])).first).taskLists
              .singleWhere(
                (candidate) => candidate.remoteId?.value == remoteList.value,
              );
      final provisional =
          (await DatabaseTasksRepository(
                    hosts.hosts[0].store,
                    clock: hosts.hosts[0].clock,
                  ).createTask(
                    CreateTaskCommand(
                      accountId: accounts[0],
                      taskListId: hostOneList.id,
                      title: 'Same content on every host',
                    ),
                  )
                  as Success<TaskId>)
              .value;
      service.uncertainTaskResponsesAfterCommit = 1;

      expect(
        (await _runHost(hosts.hosts[0], accounts[0])).outcome,
        SyncRunOutcome.failed,
      );
      expect(
        (await _runHost(hosts.hosts[1], accounts[1])).outcome,
        SyncRunOutcome.succeeded,
      );
      hosts.hosts[0].clockControl.advance(const Duration(minutes: 1));
      expect(
        (await _runHost(hosts.hosts[0], accounts[0])).outcome,
        SyncRunOutcome.succeeded,
      );
      hosts.hosts[1].clockControl.advance(const Duration(minutes: 1));
      expect(
        (await _runHost(hosts.hosts[1], accounts[1])).outcome,
        SyncRunOutcome.succeeded,
      );

      for (var index = 0; index < 2; index += 1) {
        final matching =
            (await DatabaseTasksRepository(
                  hosts.hosts[index].store,
                ).watchTasks(TasksQuery(accountId: accounts[index])).first)
                .tasks
                .where((task) => task.title == 'Same content on every host')
                .toList(growable: false);
        expect(matching, hasLength(2));
        expect(matching.map((task) => task.remoteId).toSet(), hasLength(2));
        if (index == 0) {
          expect(
            matching.singleWhere((task) => task.id == provisional).remoteId,
            isNotNull,
          );
        }
      }
    },
  );

  test(
    'REL-013 newer cross-list move waits for create recovery then applies by bound ID',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final sourceRemote = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Source'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic source setup failed.'),
      };
      final destinationRemote = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Destination'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic destination setup failed.'),
      };
      final service = _CreateInterceptService(remote)
        ..uncertainTaskResponsesAfterCommit = 1;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final initial = await harness.snapshot();
      final source = initial.taskLists.singleWhere(
        (candidate) => candidate.remoteId?.value == sourceRemote.value,
      );
      final destination = initial.taskLists.singleWhere(
        (candidate) => candidate.remoteId?.value == destinationRemote.value,
      );
      final task = await harness.createTask(source.id, 'Move after recovery');

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      expect(
        await DatabaseTasksRepository(
          harness.database,
          clock: harness.clock,
        ).apply(
          MoveTaskCommand(
            accountId: harness.accountId,
            taskId: task,
            destinationTaskListId: destination.id,
          ),
        ),
        isA<Success<void>>(),
      );
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final afterBinding = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, task);
      expect(afterBinding?.state, DesiredStateLifecycle.pending);
      expect(afterBinding?.structureDirty, isTrue);
      expect(afterBinding?.baseTaskListId, source.id);
      expect(afterBinding?.taskListId, destination.id);
      harness.clock.advance(const Duration(minutes: 1));
      final moved = await harness.run();

      expect(
        moved.moveOperations,
        1,
        reason:
            'outcome=${moved.outcome.name} failure=${moved.failure?.code} '
            'calls=${remote.callCount(FakeGoogleTasksMethod.moveTask)}',
      );
      final projected = (await harness.snapshot()).tasks.singleWhere(
        (candidate) => candidate.id == task,
      );
      expect(projected.remoteId, isNotNull);
      expect(projected.taskListId, destination.id);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 2);
      expect(remote.callCount(FakeGoogleTasksMethod.moveTask), 1);
    },
  );

  test(
    'REL-013 newer delete retains authority after recovered create binding',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final remoteList = switch (await remote.createTaskList(
        const CreateTaskListOperation(title: 'Delete recovery list'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value.id,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final service = _CreateInterceptService(remote)
        ..uncertainTaskResponsesAfterCommit = 1;
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final list = (await harness.snapshot()).taskLists.singleWhere(
        (candidate) => candidate.remoteId?.value == remoteList.value,
      );
      final task = await harness.createTask(list.id, 'Delete after recovery');

      expect((await harness.run()).outcome, SyncRunOutcome.failed);
      expect(
        await DatabaseTasksRepository(
          harness.database,
          clock: harness.clock,
        ).deleteTask(
          DeleteTaskCommand(accountId: harness.accountId, taskId: task),
        ),
        isA<Success<TaskDeleteReceipt>>(),
      );
      harness.clock.advance(const Duration(seconds: 31));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      harness.clock.advance(const Duration(minutes: 1));
      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);

      final deleteState = await harness.database
          .customSelect(
            'SELECT state FROM desired_states WHERE account_id = '
            '${harness.accountId.value} AND target_task_id = ${task.value}',
          )
          .getSingle();
      expect(deleteState.read<String>('state'), 'confirmed');
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 2);
      expect(remote.callCount(FakeGoogleTasksMethod.deleteTask), 1);
    },
  );

  test(
    'DUR-004 a newer local generation survives older create acknowledgement',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final service = _CreateInterceptService(remote);
      final harness = await _CreateHarness.open(
        remote: service,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final list = await harness.createList('Create generation list');
      final task = await harness.createTask(list, 'Generation one');
      service.afterNextTaskCommit = () =>
          DatabaseTasksRepository(harness.database, clock: harness.clock).apply(
            SetTaskTitleCommand(
              accountId: harness.accountId,
              taskId: task,
              title: 'Generation two',
            ),
          );

      expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
      final desired = await DesiredStateDao(
        harness.database,
      ).readTask(harness.accountId, task);
      final projected = (await harness.snapshot()).tasks.single;

      expect(projected.id, task);
      expect(projected.remoteId, isNotNull);
      expect(projected.title, 'Generation two');
      expect(desired?.generation, 2);
      expect(desired?.state, DesiredStateLifecycle.pending);
      expect(desired?.baseRemoteId, projected.remoteId);
      expect(desired?.baseTitle, 'Generation one');
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
    },
  );

  test('CRS-003 interruption before claim leaves create pending', () async {
    final remote = FakeGoogleTasksService();
    addTearDown(remote.close);
    final harness = await _CreateHarness.open(
      remote: remote,
      subject: subject,
      startedAt: startedAt,
    );
    addTearDown(harness.close);
    final list = await harness.createList('Pending before claim');

    final interrupted = await _engine(
      database: harness.database,
      remote: remote,
      subject: subject,
      clock: harness.clock,
      control: _InterruptAtFirst(SyncRunBoundaryKind.beforeOperationClaim),
    ).run(SyncRunRequest(accountId: harness.accountId));

    expect(interrupted.outcome, SyncRunOutcome.interrupted);
    expect(
      (await DesiredStateDao(
        harness.database,
      ).readTaskList(harness.accountId, list))?.state,
      DesiredStateLifecycle.pending,
    );
    expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 0);

    harness.clock.advance(const Duration(minutes: 1));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
    harness.clock.advance(const Duration(minutes: 1));
    expect((await harness.run()).outcome, SyncRunOutcome.succeeded);
    expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
  });

  test(
    'CRS-004 claimed create recovers conservatively and retries after restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15a-claim-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final clock = FakeClock(startedAt);
      final list =
          (await DatabaseTaskListsRepository(
                    database: database,
                    clock: clock,
                  ).createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Claimed before death',
                    ),
                  )
                  as Success<TaskListId>)
              .value;

      expect(
        (await _engine(
          database: database,
          remote: remote,
          subject: subject,
          clock: clock,
          control: _InterruptAtFirst(SyncRunBoundaryKind.afterOperationClaim),
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.interrupted,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 0);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      clock.advance(const Duration(minutes: 1));
      await _engine(
        database: database,
        remote: remote,
        subject: subject,
        clock: clock,
      ).run(SyncRunRequest(accountId: account));

      expect(
        (await DesiredStateDao(database).readTaskList(account, list))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
    },
  );

  test(
    'CRS-005 response-before-ack restart replays and binds the returned ID',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15a-response-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final clock = FakeClock(startedAt);
      final list =
          (await DatabaseTaskListsRepository(
                    database: database,
                    clock: clock,
                  ).createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Committed before acknowledgement',
                    ),
                  )
                  as Success<TaskListId>)
              .value;

      expect(
        (await _engine(
          database: database,
          remote: remote,
          subject: subject,
          clock: clock,
          control: _InterruptAtFirst(
            SyncRunBoundaryKind.beforeRemoteAcknowledgement,
          ),
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.interrupted,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      clock.advance(const Duration(minutes: 1));
      expect(
        (await _engine(
          database: database,
          remote: remote,
          subject: subject,
          clock: clock,
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.succeeded,
      );
      expect(
        (await DesiredStateDao(database).readTaskList(account, list))?.state,
        DesiredStateLifecycle.confirmed,
      );
      expect(
        (await DatabaseTasksRepository(
              database,
            ).watchTasks(TasksQuery(accountId: account)).first).taskLists
            .singleWhere((candidate) => candidate.id == list)
            .remoteId,
        isNotNull,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 2);
      expect(
        (await SyncHealthDao(
          database,
        ).watchFacts(account).first).counts.uncertain,
        0,
      );
    },
  );

  test(
    'CRS-007 restart resumes only the child after list acknowledgement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'axiotask-s15a-partial-restart-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/isolated.sqlite');
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final clock = FakeClock(startedAt);
      final list =
          (await DatabaseTaskListsRepository(
                    database: database,
                    clock: clock,
                  ).createTaskList(
                    CreateTaskListCommand(
                      accountId: account,
                      title: 'Restart list',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final task =
          (await DatabaseTasksRepository(database, clock: clock).createTask(
                    CreateTaskCommand(
                      accountId: account,
                      taskListId: list,
                      title: 'Restart task',
                    ),
                  )
                  as Success<TaskId>)
              .value;

      expect(
        (await _engine(
          database: database,
          remote: remote,
          subject: subject,
          clock: clock,
          control: _InterruptAtFirst(
            SyncRunBoundaryKind.afterRemoteAcknowledgement,
          ),
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.interrupted,
      );
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 0);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      clock.advance(const Duration(minutes: 1));
      expect(
        (await _engine(
          database: database,
          remote: remote,
          subject: subject,
          clock: clock,
        ).run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.succeeded,
      );
      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      expect(snapshot.taskLists.single.id, list);
      expect(snapshot.tasks.single.id, task);
      expect(snapshot.taskLists.single.remoteId, isNotNull);
      expect(snapshot.tasks.single.remoteId, isNotNull);
      expect(remote.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      expect(remote.callCount(FakeGoogleTasksMethod.createTask), 1);
    },
  );

  test(
    'recovery leaves an unknown account ineligible without persistence',
    () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);

      final report = await _engine(
        database: database,
        remote: remote,
        subject: subject,
        clock: FakeClock(startedAt),
      ).run(SyncRunRequest(accountId: const AccountId(999)));

      expect(report.outcome, SyncRunOutcome.ineligible);
      expect(report.ineligibleReason, SyncRunIneligibleReason.accountMissing);
      expect(await database.allAccounts(), isEmpty);
      expect(remote.calls, isEmpty);
    },
  );
}

final class _CreateHarness {
  _CreateHarness._({
    required this.database,
    required this.accountId,
    required this.clock,
    required this.engine,
  });

  static Future<_CreateHarness> open({
    required GoogleTasksService remote,
    required AccountSubject subject,
    required DateTime startedAt,
    DiagnosticSink? diagnostics,
  }) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    final clock = FakeClock(startedAt);
    return _CreateHarness._(
      database: database,
      accountId: accountId,
      clock: clock,
      engine: SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: SyntheticAuthorization(subject),
        clock: clock,
        random: SequenceRandomSource(
          List<int>.generate(256, (index) => index % 256),
        ),
        diagnostics: diagnostics,
      ),
    );
  }

  final AppDatabase database;
  final AccountId accountId;
  final FakeClock clock;
  final SyncEngine engine;

  Future<TaskListId> createList(String title) async {
    final result = await DatabaseTaskListsRepository(
      database: database,
      clock: clock,
    ).createTaskList(CreateTaskListCommand(accountId: accountId, title: title));
    return (result as Success<TaskListId>).value;
  }

  Future<TaskId> createTask(
    TaskListId taskListId,
    String title, {
    TaskId? parentTaskId,
  }) async {
    final result = await DatabaseTasksRepository(database, clock: clock)
        .createTask(
          CreateTaskCommand(
            accountId: accountId,
            taskListId: taskListId,
            parentTaskId: parentTaskId,
            title: title,
          ),
        );
    return (result as Success<TaskId>).value;
  }

  Future<SyncRunReport> run() =>
      engine.run(SyncRunRequest(accountId: accountId));

  Future<CachedTasksSnapshot> snapshot() => DatabaseTasksRepository(
    database,
  ).watchTasks(TasksQuery(accountId: accountId)).first;

  Future<void> close() => database.close();
}

SyncEngine _engine({
  required AppDatabase database,
  required GoogleTasksService remote,
  required AccountSubject subject,
  required FakeClock clock,
  SyncRunControl control = const NoopSyncRunControl(),
  DiagnosticSink? diagnostics,
}) => SyncEngine(
  store: DatabaseReadSyncStore(database),
  googleTasks: remote,
  authorization: SyntheticAuthorization(subject),
  clock: clock,
  random: SequenceRandomSource(List<int>.generate(256, (index) => index % 256)),
  control: control,
  diagnostics: diagnostics,
);

Future<SyncRunReport> _runHost(MultiHost host, AccountId accountId) =>
    SyncEngine(
      store: DatabaseReadSyncStore(host.store),
      googleTasks: host.googleTasks,
      authorization: host.authorization,
      clock: host.clock,
      random: host.random,
    ).run(SyncRunRequest(accountId: accountId));

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

final class _FanoutDiagnosticSink implements DiagnosticSink {
  const _FanoutDiagnosticSink(this.sinks);

  final List<DiagnosticSink> sinks;

  @override
  void record(DiagnosticEvent event) {
    for (final sink in sinks) {
      sink.record(event);
    }
  }
}

final class _CreateInterceptService implements GoogleTasksService {
  _CreateInterceptService(this.delegate);

  final FakeGoogleTasksService delegate;
  final List<String> createLedger = <String>[];
  bool rejectFirstList = false;
  bool rejectFirstTask = false;
  bool uncertainNextTaskAfterCommit = false;
  int uncertainTaskResponsesAfterCommit = 0;
  int uncertainListResponsesAfterCommit = 0;
  Future<Object?> Function()? afterNextTaskCommit;
  var _listCalls = 0;
  var _taskCalls = 0;

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
  ) async {
    createLedger.add('list:${operation.title}');
    _listCalls += 1;
    if (rejectFirstList && _listCalls == 1) {
      return const RejectedMutation<RemoteTaskList>(_rejectedCreateError);
    }
    final result = await delegate.createTaskList(operation);
    if (uncertainListResponsesAfterCommit > 0) {
      uncertainListResponsesAfterCommit -= 1;
      return const UncertainMutation<RemoteTaskList>(_uncertainCreateError);
    }
    return result;
  }

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async {
    createLedger.add('task:${operation.title}');
    _taskCalls += 1;
    if (rejectFirstTask && _taskCalls == 1) {
      return const RejectedMutation<RemoteTask>(_rejectedCreateError);
    }
    final result = await delegate.createTask(operation);
    final callback = afterNextTaskCommit;
    afterNextTaskCommit = null;
    await callback?.call();
    if (uncertainNextTaskAfterCommit || uncertainTaskResponsesAfterCommit > 0) {
      uncertainNextTaskAfterCommit = false;
      if (uncertainTaskResponsesAfterCommit > 0) {
        uncertainTaskResponsesAfterCommit -= 1;
      }
      return const UncertainMutation<RemoteTask>(_uncertainCreateError);
    }
    return result;
  }

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

const Failure _rejectedCreateFailure = Failure(
  code: 'synthetic.create_rejected',
  category: FailureCategory.remote,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The synthetic create was rejected.',
  safeSummary: 'Synthetic create rejection.',
);

const GoogleTasksMutationError _rejectedCreateError = GoogleTasksMutationError(
  failure: _rejectedCreateFailure,
  kind: GoogleTasksErrorKind.permanent,
  commitState: MutationCommitState.notCommitted,
);

const Failure _uncertainCreateFailure = Failure(
  code: 'synthetic.create_uncertain',
  category: FailureCategory.network,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The synthetic create may have committed.',
  safeSummary: 'Synthetic create response was lost.',
);

const GoogleTasksMutationError _uncertainCreateError = GoogleTasksMutationError(
  failure: _uncertainCreateFailure,
  kind: GoogleTasksErrorKind.transient,
  commitState: MutationCommitState.uncertain,
);
