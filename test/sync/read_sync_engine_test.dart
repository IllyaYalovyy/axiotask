import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/phase.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';

void main() {
  const subject = AccountSubject('synthetic-read-sync-subject');
  final startedAt = DateTime.utc(2026, 8, 15, 12);

  test(
    'RUN-001 cold run executes ordered phases and publishes all pages',
    () async {
      final remote = FakeGoogleTasksService(
        taskListPageSize: 1,
        taskPageSize: 1,
      );
      addTearDown(remote.close);
      final listA = await _createList(remote, 'List A');
      final listB = await _createList(remote, 'List B');
      await _createTask(remote, listA, 'Task A');
      await _createTask(remote, listB, 'Task B');
      final control = _RecordingControl();
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
        control: control,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.complete, isTrue);
      expect(harness.observer.phases, SyncRunPhase.values);
      expect(
        control.boundaries
            .where((boundary) => boundary.kind == SyncRunBoundaryKind.phase)
            .map((boundary) => boundary.phase),
        SyncRunPhase.values,
      );
      expect(report.taskListPages, 2);
      expect(report.taskPages, 2);
      expect(report.remoteTaskLists, 2);
      expect(report.remoteTasks, 2);
      final snapshot = await harness.snapshot();
      expect(snapshot.completeness, CacheCompleteness.complete);
      expect(snapshot.taskLists.map((list) => list.title), <String>[
        'List A',
        'List B',
      ]);
      expect(snapshot.tasks.map((task) => task.title), <String>[
        'Task A',
        'Task B',
      ]);
      final facts = await harness.healthFacts();
      expect(facts.lastSuccessfulSyncAt, startedAt);
      expect(facts.requiredScopeIncomplete, isFalse);
      expect(facts.latestFailure, isNull);
    },
  );

  test(
    'RUN-011 warm no-op run preserves identities and performs reads only',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[_remoteList('list-a', 'List A')]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[_remoteTask('task-a', 'Task A')]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final first = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );
      final firstSnapshot = await harness.snapshot();
      harness.clock.advance(const Duration(minutes: 1));
      final second = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );
      final secondSnapshot = await harness.snapshot();

      expect(first.outcome, SyncRunOutcome.succeeded);
      expect(second.outcome, SyncRunOutcome.succeeded);
      expect(second.resourceProjectionWrites, 0);
      expect(
        secondSnapshot.taskLists.single.id,
        firstSnapshot.taskLists.single.id,
      );
      expect(secondSnapshot.tasks.single.id, firstSnapshot.tasks.single.id);
      expect(remote.listTaskListCalls, 2);
      expect(remote.listTaskCalls, 2);
      expect(remote.mutationCalls, 0);
      expect(
        (await harness.healthFacts()).lastSuccessfulSyncAt,
        startedAt.add(const Duration(minutes: 1)),
      );
    },
  );

  test('RUN-012 request count scales with pages and lists, not rows', () async {
    final remote = _ScriptedReadService(
      taskListPages: <RemotePage<RemoteTaskList>>[
        _listPage(<RemoteTaskList>[
          _remoteList('list-a', 'List A'),
          _remoteList('list-b', 'List B'),
        ]),
      ],
      taskPages: <String, List<RemotePage<RemoteTask>>>{
        'list-a': <RemotePage<RemoteTask>>[
          _taskPage(<RemoteTask>[
            _remoteTask('task-a1', 'A1'),
            _remoteTask('task-a2', 'A2'),
            _remoteTask('task-a3', 'A3'),
          ], next: 'list-a-next'),
          _taskPage(<RemoteTask>[
            _remoteTask('task-a4', 'A4'),
            _remoteTask('task-a5', 'A5'),
          ]),
        ],
        'list-b': <RemotePage<RemoteTask>>[
          _taskPage(<RemoteTask>[
            _remoteTask('task-b1', 'B1'),
            _remoteTask('task-b2', 'B2'),
            _remoteTask('task-b3', 'B3'),
            _remoteTask('task-b4', 'B4'),
          ]),
        ],
      },
    );
    final harness = await _Harness.create(
      remote: remote,
      subject: subject,
      startedAt: startedAt,
    );
    addTearDown(harness.close);

    final report = await harness.engine.run(
      SyncRunRequest(accountId: harness.accountId),
    );

    expect(report.outcome, SyncRunOutcome.succeeded);
    expect(report.taskListPages, 1);
    expect(report.taskPages, 3);
    expect(report.remoteTasks, 9);
    expect(remote.listTaskListCalls, 1);
    expect(remote.listTaskCalls, 3);
    expect(remote.mutationCalls, 0);
  });

  test(
    'child before parent is deferred across pages and published safely',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[_remoteList('list-a', 'Hierarchy')]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask('child', 'Child', parent: 'parent'),
            ], next: 'parent-page'),
            _taskPage(<RemoteTask>[_remoteTask('parent', 'Parent')]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );
      final snapshot = await harness.snapshot();

      expect(report.outcome, SyncRunOutcome.succeeded);
      final parent = snapshot.tasks.singleWhere(
        (task) => task.remoteId == const TaskRemoteId('parent'),
      );
      final child = snapshot.tasks.singleWhere(
        (task) => task.remoteId == const TaskRemoteId('child'),
      );
      expect(child.parentTaskId, parent.id);
      expect(snapshot.completeness, CacheCompleteness.complete);
    },
  );

  test('eligibility and subject checks issue zero Google requests', () async {
    final remote = _ScriptedReadService(
      taskListPages: <RemotePage<RemoteTaskList>>[
        _listPage(const <RemoteTaskList>[]),
      ],
    );
    final database = AppDatabase.inMemory();
    addTearDown(database.close);
    final account = AccountId(await database.createAccount(subject.value));
    await SyncHealthDao(
      database,
    ).writeFacts(account, const PersistedSyncFacts(syncEnabled: false));
    final stopped = SyncEngine(
      store: DatabaseReadSyncStore(database),
      googleTasks: remote,
      authorization: const SyntheticAuthorization(subject),
      clock: FakeClock(startedAt),
      random: SequenceRandomSource(List<int>.filled(16, 1)),
    );

    final stoppedReport = await stopped.run(SyncRunRequest(accountId: account));
    expect(stoppedReport.ineligibleReason, SyncRunIneligibleReason.syncStopped);
    expect(remote.listTaskListCalls, 0);

    await SyncHealthDao(
      database,
    ).writeFacts(account, const PersistedSyncFacts());
    final mismatch = SyncEngine(
      store: DatabaseReadSyncStore(database),
      googleTasks: remote,
      authorization: const SyntheticAuthorization(
        AccountSubject('different-synthetic-subject'),
      ),
      clock: FakeClock(startedAt),
      random: SequenceRandomSource(List<int>.filled(16, 2)),
    );
    final mismatchReport = await mismatch.run(
      SyncRunRequest(accountId: account),
    );
    expect(
      mismatchReport.ineligibleReason,
      SyncRunIneligibleReason.accountMismatch,
    );
    expect(remote.listTaskListCalls, 0);
  });

  test(
    'REL-001 failed list page retains published cache without completeness',
    () async {
      final priorSuccess = startedAt.subtract(const Duration(minutes: 2));
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[
            _remoteList('list-a', 'Published before failure'),
          ], next: 'list-next'),
        ],
        listPageFailure: const Failure(
          code: 'google_tasks.synthetic_page_failure',
          category: FailureCategory.remote,
          operation: FailureOperation.read,
          retry: RetryClassification.transient,
          impact: 'The synthetic list page did not load.',
          safeSummary: 'Synthetic list page failure.',
        ),
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
        priorSuccess: priorSuccess,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure?.code, 'google_tasks.synthetic_page_failure');
      final snapshot = await harness.snapshot();
      expect(snapshot.taskLists.single.title, 'Published before failure');
      expect(snapshot.completeness, CacheCompleteness.incomplete);
      final facts = await harness.healthFacts();
      expect(facts.lastSuccessfulSyncAt, priorSuccess);
      expect(facts.requiredScopeIncomplete, isTrue);
      expect(
        facts.latestFailure?.diagnosticCode,
        'google_tasks.synthetic_page_failure',
      );
      expect(remote.listTaskCalls, 0);
    },
  );

  test(
    'REL-002 one task scope failure does not discard another complete scope',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[
            _remoteList('list-a', 'List A'),
            _remoteList('list-b', 'List B'),
          ]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-b': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[_remoteTask('task-b', 'Safe task')]),
          ],
        },
        taskFailures: <String, Failure>{
          'list-a': const Failure(
            code: 'google_tasks.synthetic_task_page_failure',
            category: FailureCategory.network,
            operation: FailureOperation.read,
            retry: RetryClassification.transient,
            impact: 'One synthetic task scope did not load.',
            safeSummary: 'Synthetic task scope failure.',
          ),
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.failed);
      expect((await harness.snapshot()).tasks.single.title, 'Safe task');
      expect(
        (await harness.snapshot()).completeness,
        CacheCompleteness.incomplete,
      );
      expect(remote.requestedTaskLists, <String>['list-a', 'list-b']);
    },
  );

  test(
    'REL-003 malformed row fails its scope and retains the warm cache',
    () async {
      final goodRemote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[_remoteList('list-a', 'Warm list')]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[_remoteTask('task-a', 'Warm task')]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: goodRemote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      expect(
        (await harness.engine.run(
          SyncRunRequest(accountId: harness.accountId),
        )).outcome,
        SyncRunOutcome.succeeded,
      );
      harness.clock.advance(const Duration(minutes: 1));
      final malformedEngine = SyncEngine(
        store: DatabaseReadSyncStore(harness.database),
        googleTasks: _ScriptedReadService(
          taskListPages: <RemotePage<RemoteTaskList>>[
            _listPage(<RemoteTaskList>[_remoteList('list-a', 'Warm list')]),
          ],
          taskPages: <String, List<RemotePage<RemoteTask>>>{
            'list-a': <RemotePage<RemoteTask>>[
              _taskPage(<RemoteTask>[
                RemoteLiveTask(
                  id: const RemoteTaskId('malformed-task'),
                  etag: 'etag-malformed',
                  updated: startedAt,
                  selfLink: null,
                  title: 'Malformed',
                  parentId: null,
                  position: '',
                  notes: null,
                  status: RemoteTaskStatus.needsAction,
                  due: null,
                  completed: null,
                  hidden: false,
                  links: const <RemoteTaskLink>[],
                  webViewLink: null,
                ),
              ]),
            ],
          },
        ),
        authorization: const SyntheticAuthorization(subject),
        clock: harness.clock,
        random: SequenceRandomSource(
          List<int>.generate(32, (index) => 255 - index),
        ),
      );

      final report = await malformedEngine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure?.category, FailureCategory.unsupportedRemoteState);
      final snapshot = await harness.snapshot();
      expect(snapshot.tasks.single.title, 'Warm task');
      expect(snapshot.completeness, CacheCompleteness.incomplete);
    },
  );

  test(
    'unsupported third-level hierarchy is not flattened or published',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[_remoteList('list-a', 'Hierarchy')]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask('parent', 'Parent'),
              _remoteTask('child', 'Child', parent: 'parent'),
              _remoteTask('grandchild', 'Grandchild', parent: 'child'),
            ]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.failed);
      expect(report.failure?.code, 'sync.unsupported_task_depth');
      expect((await harness.snapshot()).tasks, isEmpty);
      expect(
        (await harness.snapshot()).completeness,
        CacheCompleteness.incomplete,
      );
      expect(remote.mutationCalls, 0);
    },
  );

  test(
    'REC-023 protects decoded hierarchy evidence and persists safe failure only',
    () async {
      final history = InMemoryDiagnosticHistory();
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[
            _remoteList('list-a', 'Hierarchy'),
            _remoteList('list-b', 'Unrelated'),
          ]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask('parent', 'Protected parent'),
              _remoteTask('child', 'Protected child', parent: 'parent'),
              _remoteTask(
                'grandchild',
                'Protected grandchild',
                parent: 'child',
              ),
            ]),
          ],
          'list-b': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask('unrelated-task', 'Visible unrelated task'),
            ]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final engine = SyncEngine(
        store: DatabaseReadSyncStore(harness.database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: harness.clock,
        random: SequenceRandomSource(List<int>.generate(32, (i) => i + 1)),
        diagnostics: SensitiveDevelopmentDiagnosticSink(history),
      );

      final report = await engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.failure?.code, 'sync.unsupported_task_depth');
      expect(remote.mutationCalls, 0);
      expect(
        (await harness.snapshot()).tasks.map((task) => task.title),
        contains('Visible unrelated task'),
      );
      final record = history.records.singleWhere(
        (record) => record.code == 'sync.unsupported_task_depth',
      );
      expect(record.fields['decoded_scope'], contains('Protected grandchild'));
      expect(record.fields['decoded_scope'], contains('grandchild'));
      final facts = await harness.healthFacts();
      expect(
        facts.latestFailure?.diagnosticCode,
        'sync.unsupported_task_depth',
      );
      expect(facts.latestFailure.toString(), isNot(contains('Protected')));

      final releaseHistory = InMemoryDiagnosticHistory();
      await SyncEngine(
        store: DatabaseReadSyncStore(harness.database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: harness.clock,
        random: SequenceRandomSource(List<int>.generate(32, (i) => 64 + i)),
        diagnostics: ProductionDiagnosticSink(releaseHistory),
      ).run(SyncRunRequest(accountId: harness.accountId));
      final releaseRecord = releaseHistory.records.singleWhere(
        (record) => record.code == 'sync.unsupported_task_depth',
      );
      expect(releaseRecord.fields, isNot(contains('decoded_scope')));
      expect(releaseRecord.renderedText, isNot(contains('Protected')));
    },
  );

  test(
    'local hierarchy projection survives read-back without remote MOVE',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[_remoteList('list-a', 'Hierarchy')]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask('task', 'Task'),
              _remoteTask('parent', 'Parent'),
            ]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);
      final cache = CacheDao(harness.database);
      final list = await cache.putTaskList(
        accountId: harness.accountId,
        remoteId: const TaskListRemoteId('list-a'),
        title: 'Hierarchy',
      );
      final task = await cache.putTask(
        accountId: harness.accountId,
        taskListId: list,
        remoteId: const TaskRemoteId('task'),
        title: 'Task',
        position: '0001',
      );
      final parent = await cache.putTask(
        accountId: harness.accountId,
        taskListId: list,
        remoteId: const TaskRemoteId('parent'),
        title: 'Parent',
        position: '0002',
      );
      for (final (id, remoteId, title, position)
          in <(TaskId, TaskRemoteId, String, String)>[
            (task, const TaskRemoteId('task'), 'Task', '0001'),
            (parent, const TaskRemoteId('parent'), 'Parent', '0002'),
          ]) {
        await cache.putTaskRemoteBase(
          accountId: harness.accountId,
          taskId: id,
          taskListId: list,
          remoteId: remoteId,
          observedPublicationId: 'prior',
          deleted: false,
          title: title,
          status: TaskStatus.needsAction,
          position: position,
          etag: 'etag-$position',
          remoteUpdatedAt: startedAt.subtract(const Duration(minutes: 1)),
        );
      }
      final repository = DatabaseTasksRepository(
        harness.database,
        clock: harness.clock,
      );
      expect(
        await repository.apply(
          DemoteTaskCommand(
            accountId: harness.accountId,
            taskId: task,
            parentTaskId: parent,
          ),
        ),
        isA<Success<void>>(),
      );

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.updateOperations, 0);
      expect(remote.mutationCalls, 0);
      final projected = (await harness.snapshot()).tasks.singleWhere(
        (value) => value.id == task,
      );
      expect(projected.parentTaskId, parent);
      expect(
        (await cache.readTaskRemoteBase(harness.accountId, task))?.parentTaskId,
        isNull,
      );
    },
  );

  test(
    'REL-018 traverses terminal empty pages and every supported task scope',
    () async {
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[
            _remoteList('list-a', 'List A'),
          ], next: 'lists-terminal'),
          _listPage(const <RemoteTaskList>[]),
        ],
        taskPages: <String, List<RemotePage<RemoteTask>>>{
          'list-a': <RemotePage<RemoteTask>>[
            _taskPage(<RemoteTask>[
              _remoteTask(
                'completed-hidden',
                'Completed hidden',
                status: RemoteTaskStatus.completed,
                hidden: true,
              ),
              RemoteTaskTombstone(
                id: const RemoteTaskId('deleted-task'),
                etag: 'etag-deleted-task',
                updated: startedAt,
                selfLink: null,
                retainedTitle: null,
                retainedParentId: null,
                retainedPosition: null,
                retainedNotes: null,
                retainedStatus: null,
                retainedDue: null,
                retainedCompleted: null,
                hidden: false,
                retainedLinks: const <RemoteTaskLink>[],
                retainedWebViewLink: null,
              ),
            ], next: 'tasks-terminal'),
            _taskPage(const <RemoteTask>[]),
          ],
        },
      );
      final harness = await _Harness.create(
        remote: remote,
        subject: subject,
        startedAt: startedAt,
      );
      addTearDown(harness.close);

      final report = await harness.engine.run(
        SyncRunRequest(accountId: harness.accountId),
      );

      expect(report.outcome, SyncRunOutcome.succeeded);
      expect(report.taskListPages, 2);
      expect(report.taskPages, 2);
      expect((await harness.snapshot()).tasks.single.title, 'Completed hidden');
      expect(remote.mutationCalls, 0);
    },
  );

  test(
    'CRS-008 killed after a page commit reopens partial and never successful',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-read-sync-page-boundary-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic.sqlite');
      final control = _KillOnceControl(
        const SyncRunBoundary(
          kind: SyncRunBoundaryKind.afterPagePublication,
          scope: 'task_lists',
          pageIndex: 0,
        ),
      );
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(<RemoteTaskList>[
            _remoteList('list-a', 'Committed page'),
          ], next: 'next-list-page'),
          _listPage(<RemoteTaskList>[_remoteList('list-b', 'Unreached page')]),
        ],
      );
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final engine = SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: FakeClock(startedAt),
        random: SequenceRandomSource(List<int>.generate(32, (index) => index)),
        control: control,
      );

      final report = await engine.run(SyncRunRequest(accountId: account));
      expect(report.outcome, SyncRunOutcome.interrupted);
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      final snapshot = await DatabaseTasksRepository(
        database,
      ).watchTasks(TasksQuery(accountId: account)).first;
      final facts = await SyncHealthDao(database).watchFacts(account).first;
      expect(snapshot.taskLists.single.title, 'Committed page');
      expect(snapshot.completeness, CacheCompleteness.incomplete);
      expect(facts.lastSuccessfulSyncAt, isNull);
      expect(facts.requiredScopeIncomplete, isTrue);
    },
  );

  test(
    'CRS-009/010 finalization boundary alone advances success; reopen verifies',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'axiotask-read-sync-finalize-boundary-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic.sqlite');
      final remote = _ScriptedReadService(
        taskListPages: <RemotePage<RemoteTaskList>>[
          _listPage(const <RemoteTaskList>[]),
        ],
      );
      var database = await AppDatabase.openFile(file);
      final account = AccountId(await database.createAccount(subject.value));
      final interrupted = SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: FakeClock(startedAt),
        random: SequenceRandomSource(List<int>.generate(32, (index) => index)),
        control: _KillOnceControl(
          const SyncRunBoundary(kind: SyncRunBoundaryKind.beforeFinalization),
        ),
      );
      expect(
        (await interrupted.run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.interrupted,
      );
      expect(
        (await SyncHealthDao(
          database,
        ).watchFacts(account).first).lastSuccessfulSyncAt,
        isNull,
      );
      await database.close();

      database = await AppDatabase.openFile(file);
      final completed = SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: FakeClock(startedAt.add(const Duration(minutes: 1))),
        random: SequenceRandomSource(
          List<int>.generate(32, (index) => 255 - index),
        ),
      );
      expect(
        (await completed.run(SyncRunRequest(accountId: account))).outcome,
        SyncRunOutcome.succeeded,
      );
      await database.close();

      database = await AppDatabase.openFile(file);
      addTearDown(database.close);
      expect(
        (await SyncHealthDao(
          database,
        ).watchFacts(account).first).lastSuccessfulSyncAt,
        startedAt.add(const Duration(minutes: 1)),
      );
    },
  );
}

final class _Harness {
  _Harness._({
    required this.database,
    required this.accountId,
    required this.clock,
    required this.engine,
    required this.observer,
  });

  static Future<_Harness> create({
    required GoogleTasksService remote,
    required AccountSubject subject,
    required DateTime startedAt,
    DateTime? priorSuccess,
    SyncRunControl control = const NoopSyncRunControl(),
  }) async {
    final database = AppDatabase.inMemory();
    final accountId = AccountId(await database.createAccount(subject.value));
    if (priorSuccess != null) {
      await SyncHealthDao(database).writeFacts(
        accountId,
        PersistedSyncFacts(lastSuccessfulSyncAt: priorSuccess),
      );
    }
    final clock = FakeClock(startedAt);
    final observer = _RecordingObserver();
    return _Harness._(
      database: database,
      accountId: accountId,
      clock: clock,
      observer: observer,
      engine: SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: SyntheticAuthorization(subject),
        clock: clock,
        random: SequenceRandomSource(
          List<int>.generate(256, (index) => index % 256),
        ),
        observer: observer,
        control: control,
      ),
    );
  }

  final AppDatabase database;
  final AccountId accountId;
  final FakeClock clock;
  final SyncEngine engine;
  final _RecordingObserver observer;

  Future<CachedTasksSnapshot> snapshot() => DatabaseTasksRepository(
    database,
  ).watchTasks(TasksQuery(accountId: accountId)).first;

  Future<PersistedSyncFacts> healthFacts() =>
      SyncHealthDao(database).watchFacts(accountId).first;

  Future<void> close() => database.close();
}

final class _RecordingObserver implements SyncRunObserver {
  final List<SyncRunPhase> phases = <SyncRunPhase>[];

  @override
  void phaseStarted(SyncRunId runId, SyncRunPhase phase) {
    phases.add(phase);
  }
}

final class _KillOnceControl implements SyncRunControl {
  _KillOnceControl(this.target);

  final SyncRunBoundary target;
  var _killed = false;

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async {
    if (!_killed && boundary == target) {
      _killed = true;
      return SyncRunControlDecision.interrupt;
    }
    return SyncRunControlDecision.proceed;
  }
}

final class _RecordingControl implements SyncRunControl {
  final List<SyncRunBoundary> boundaries = <SyncRunBoundary>[];

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async {
    boundaries.add(boundary);
    return SyncRunControlDecision.proceed;
  }
}

final class _ScriptedReadService implements GoogleTasksService {
  _ScriptedReadService({
    required this.taskListPages,
    this.taskPages = const <String, List<RemotePage<RemoteTask>>>{},
    this.listPageFailure,
    this.taskFailures = const <String, Failure>{},
  });

  final List<RemotePage<RemoteTaskList>> taskListPages;
  final Map<String, List<RemotePage<RemoteTask>>> taskPages;
  final Failure? listPageFailure;
  final Map<String, Failure> taskFailures;
  final List<String> requestedTaskLists = <String>[];
  var listTaskListCalls = 0;
  var listTaskCalls = 0;
  var mutationCalls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    listTaskListCalls += 1;
    final index = _pageIndex(taskListPages, pageToken);
    if (cancellation?.isCancelled ?? false) {
      return Outcome<RemotePage<RemoteTaskList>>.failure(_cancelledFailure);
    }
    if (index < taskListPages.length) {
      return Outcome<RemotePage<RemoteTaskList>>.success(taskListPages[index]);
    }
    return Outcome<RemotePage<RemoteTaskList>>.failure(
      listPageFailure ?? _unexpectedReadFailure,
    );
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    requestedTaskLists.add(taskListId.value);
    listTaskCalls += 1;
    if (cancellation?.isCancelled ?? false) {
      return Outcome<RemotePage<RemoteTask>>.failure(_cancelledFailure);
    }
    final pages =
        taskPages[taskListId.value] ?? const <RemotePage<RemoteTask>>[];
    final index = _pageIndex(pages, pageToken);
    if (index < pages.length) {
      return Outcome<RemotePage<RemoteTask>>.success(pages[index]);
    }
    return Outcome<RemotePage<RemoteTask>>.failure(
      taskFailures[taskListId.value] ?? _unexpectedReadFailure,
    );
  }

  Never _mutation() {
    mutationCalls += 1;
    throw StateError('Read-only synchronization issued a mutation.');
  }

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

  int _pageIndex<T>(List<RemotePage<T>> pages, PageToken? token) {
    if (token == null) return 0;
    final prior = pages.indexWhere(
      (page) => page.nextPageToken?.value == token.value,
    );
    return prior < 0 ? pages.length : prior + 1;
  }
}

const Failure _unexpectedReadFailure = Failure(
  code: 'synthetic.unexpected_read',
  category: FailureCategory.internal,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'The synthetic read plan was exhausted.',
  safeSummary: 'Synthetic read plan exhausted.',
);

const Failure _cancelledFailure = Failure(
  code: 'synthetic.cancelled',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'The synthetic read was cancelled.',
  safeSummary: 'Synthetic read cancelled.',
);

Future<RemoteTaskListId> _createList(
  FakeGoogleTasksService remote,
  String title,
) async {
  final result = await remote.createTaskList(
    CreateTaskListOperation(title: title),
  );
  return switch (result) {
    CommittedMutation<RemoteTaskList>(:final value) => value.id,
    _ => throw StateError('Synthetic list setup failed.'),
  };
}

Future<void> _createTask(
  FakeGoogleTasksService remote,
  RemoteTaskListId list,
  String title,
) async {
  final result = await remote.createTask(
    CreateTaskOperation(
      taskListId: list,
      title: title,
      notes: null,
      status: RemoteTaskStatus.needsAction,
      due: null,
    ),
  );
  if (result is! CommittedMutation<RemoteTask>) {
    throw StateError('Synthetic task setup failed.');
  }
}

RemoteTaskList _remoteList(String id, String title) => RemoteTaskList(
  id: RemoteTaskListId(id),
  etag: 'etag-$id',
  title: title,
  updated: DateTime.utc(2026, 8, 15, 11),
  selfLink: Uri.parse('https://example.invalid/lists/$id'),
);

RemoteLiveTask _remoteTask(
  String id,
  String title, {
  String? parent,
  RemoteTaskStatus status = RemoteTaskStatus.needsAction,
  bool hidden = false,
}) => RemoteLiveTask(
  id: RemoteTaskId(id),
  etag: 'etag-$id',
  updated: DateTime.utc(2026, 8, 15, 11),
  selfLink: Uri.parse('https://example.invalid/tasks/$id'),
  title: title,
  parentId: parent == null ? null : RemoteTaskId(parent),
  position: 'position-$id',
  notes: null,
  status: status,
  due: null,
  completed: status == RemoteTaskStatus.completed
      ? DateTime.utc(2026, 8, 15, 10)
      : null,
  hidden: hidden,
  links: const <RemoteTaskLink>[],
  webViewLink: null,
);

RemotePage<RemoteTaskList> _listPage(
  List<RemoteTaskList> items, {
  String? next,
}) => RemotePage<RemoteTaskList>(
  items: items,
  collectionEtag: 'collection-lists',
  nextPageToken: next == null ? null : PageToken(next),
);

RemotePage<RemoteTask> _taskPage(List<RemoteTask> items, {String? next}) =>
    RemotePage<RemoteTask>(
      items: items,
      collectionEtag: 'collection-tasks',
      nextPageToken: next == null ? null : PageToken(next),
    );
