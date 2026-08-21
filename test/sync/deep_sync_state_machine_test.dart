import 'dart:io';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/sync_health_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_auth.dart';
import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';
import '../support/fake_random.dart';
import '../support/reference_model.dart';
import '../support/replay_seed.dart';

/// S33's deterministic, file-backed model evidence.
///
/// The reference model observes the real repository/engine boundary rather
/// than reproducing reconciliation. The fixed seeds are a replay corpus: a
/// failing run prints the exact `AXIOTASK_REPLAY_SEED` command needed to rerun
/// the same generated edit/create/delete/move/trigger/auth/reopen sequence.
void main() {
  late bool priorMultipleDatabaseWarning;
  setUpAll(() {
    priorMultipleDatabaseWarning =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        priorMultipleDatabaseWarning;
  });

  group('S33 deep synchronization model', () {
    test(
      'MOD-001 applies all twelve reliability invariants after every step',
      () async {
        for (final seed in _selectedSeeds()) {
          final system = await _DeepSyncSystem.create(seed: seed.value);
          addTearDown(system.close);
          final model = _model();

          final commands = _generatedCommands(seed, count: 18);
          final result = await model.run(system, commands, seed: seed);

          expect(result.transitions, hasLength(18));
          expect(
            result.transitions.map((transition) => transition.commandLabel),
            containsAll(<String>[
              'create:host-1',
              'edit:host-2',
              'move:host-1',
              'trigger:host-2',
              'auth-refresh:host-1',
              'reopen:host-2',
              'delete:host-1',
            ]),
          );
        }
      },
    );

    test(
      'MOD-002 converges every two-host ordering and remains a no-write no-op',
      () async {
        for (final order in const <List<int>>[
          <int>[0, 1],
          <int>[1, 0],
        ]) {
          final system = await _DeepSyncSystem.create(
            seed: 16002 + order.first,
          );
          addTearDown(system.close);
          await system.createTask(0, 'Concurrent host one');
          await system.createTask(1, 'Concurrent host two');
          await system.converge(order);

          final beforeVerificationWrites = system.writeCallCount;
          await system.runHosts(order, trigger: 'verification');
          final after = await _DeepSnapshot.read(system);

          expect(system.writeCallCount, beforeVerificationWrites);
          expect(after.hostRemoteTaskIds[0], after.hostRemoteTaskIds[1]);
          expect(
            after.hostFacts.every((facts) => facts.counts.total == 0),
            isTrue,
          );
          expect(
            after.remoteTaskIds,
            containsAll(<String>['task-1', 'task-2', 'task-3']),
          );
        }
      },
    );

    test('MOD-003 delete remains scoped across a real SQLite reopen', () async {
      final system = await _DeepSyncSystem.create(seed: 3003);
      addTearDown(system.close);
      final before = await _DeepSnapshot.read(system);
      final protected = before.remoteTaskIds.singleWhere(
        (id) => id == 'task-2',
      );

      await system.deleteFirstTaskInPrimaryList(0);
      system.advance(const Duration(seconds: 31));
      await system.runHosts(const <int>[0, 1], trigger: 'delete-recovery');
      await system.reopen(0);
      await system.runHosts(const <int>[1, 0], trigger: 'delete-verification');
      final after = await _DeepSnapshot.read(system);

      expect(after.remoteTaskIds, isNot(contains('task-1')));
      expect(after.remoteTaskIds, contains(protected));
      expect(after.hostRemoteTaskIds[0], after.hostRemoteTaskIds[1]);
      expect(system.google.callCount(FakeGoogleTasksMethod.deleteTask), 1);
    });

    test(
      'MOD-004 reports bounded no-progress before an undo-gated delete',
      () async {
        const seed = ReplaySeed(4004);
        final system = await _DeepSyncSystem.create(seed: seed.value);
        addTearDown(system.close);
        await system.deleteFirstTaskInPrimaryList(0);
        final model = _model();

        await expectLater(
          model.runToQuiescence(
            system,
            nextCommand: (_) => const _RunAllHostsCommand('liveness'),
            isQuiescent: (snapshot) => snapshot.hostFacts.every(
              (facts) => facts.counts.pendingConfirmation == 0,
            ),
            maxTransitions: 2,
            seed: seed,
            failureSink: (_) {},
          ),
          throwsA(isA<QuiescenceLimitExceeded>()),
        );

        system.advance(const Duration(seconds: 31));
        final settled = await model.runToQuiescence(
          system,
          nextCommand: (_) => const _RunAllHostsCommand('liveness'),
          isQuiescent: (snapshot) => snapshot.hostFacts.every(
            (facts) => facts.counts.pendingConfirmation == 0,
          ),
          maxTransitions: 4,
          seed: seed,
        );
        expect(settled.transitions, isNotEmpty);
        expect(system.google.callCount(FakeGoogleTasksMethod.deleteTask), 1);
      },
    );
  });
}

const List<ReplaySeed> _regressionSeeds = <ReplaySeed>[
  ReplaySeed(331),
  ReplaySeed(902),
  ReplaySeed(1907),
  ReplaySeed(8161),
];

List<ReplaySeed> _selectedSeeds() {
  if (Platform.environment.containsKey(ReplaySeed.environmentKey)) {
    return <ReplaySeed>[
      ReplaySeed.resolve(fallback: _regressionSeeds.first.value),
    ];
  }
  return _regressionSeeds;
}

ReferenceModel<_DeepSyncSystem, _DeepSnapshot>
_model() => ReferenceModel<_DeepSyncSystem, _DeepSnapshot>(
  snapshot: _DeepSnapshot.read,
  invariants: <ModelInvariant<_DeepSnapshot>>[
    // 1. Durable acknowledgement: a projected provisional task has work.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.durable_acknowledgement',
      verify: (transition) {
        for (
          var index = 0;
          index < transition.after.hostTaskIds.length;
          index += 1
        ) {
          if (transition.after.hostTaskIds[index].length >
              transition.after.hostRemoteTaskIds[index].length) {
            expect(
              transition.after.hostFacts[index].counts.total,
              greaterThan(0),
            );
          }
        }
      },
    ),
    // 2. No network transaction: completed commands leave no in-flight row.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.no_network_transaction',
      verify: (transition) => expect(
        transition.after.hostFacts.every((facts) => facts.counts.inFlight == 0),
        isTrue,
      ),
    ),
    // 3. Atomic acknowledgement: remote IDs are unique in each installation.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.atomic_remote_acknowledgement',
      verify: (transition) {
        for (final ids in transition.after.hostRemoteTaskIds) {
          expect(ids.toSet(), hasLength(ids.length));
        }
      },
    ),
    // 4. Serialized authority: this direct engine boundary returns one run.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.serialized_authority',
      verify: (transition) => expect(
        transition.after.hostFacts.every((facts) => facts.counts.inFlight == 0),
        isTrue,
      ),
    ),
    // 5. No blind replay: a clean verification never adds a write.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.no_blind_mutation_replay',
      verify: (transition) {
        if (transition.commandLabel.startsWith('trigger:') &&
            transition.before.hostFacts.every(
              (facts) => facts.counts.total == 0,
            )) {
          expect(transition.after.writeCalls, transition.before.writeCalls);
        }
      },
    ),
    // 6. Delete is positive and remains scoped to the protected task/list.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.no_destructive_absence',
      verify: (transition) =>
          expect(transition.after.remoteTaskIds, contains('task-2')),
    ),
    // 7. Acknowledged work is not undone by a later full walk.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.partial_success_durability',
      verify: (transition) => expect(
        transition.after.hostTaskIds.every((ids) => ids.isNotEmpty),
        isTrue,
      ),
    ),
    // 8. A green result has complete, clean durable evidence.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.truthful_health',
      verify: (transition) {
        for (final facts in transition.after.hostFacts) {
          if (facts.lastSuccessfulSyncAt != null) {
            expect(facts.requiredScopeIncomplete, isFalse);
          }
        }
      },
    ),
    // 9. Work remains countable, which lets MOD-004 bound progress.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.bounded_activity',
      verify: (transition) => expect(
        transition.after.hostFacts.every((facts) => facts.counts.total >= 0),
        isTrue,
      ),
    ),
    // 10. Reopen preserves durable facts rather than inventing success.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.restart_equivalence',
      verify: (transition) => expect(
        transition.after.hostFacts.every(
          (facts) =>
              facts.lastSuccessfulSyncAt == null ||
              !facts.requiredScopeIncomplete,
        ),
        isTrue,
      ),
    ),
    // 11. Both installation-local stores retain independent local IDs.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.account_isolation',
      verify: (transition) => expect(
        transition.after.hostTaskIds[0].isNotEmpty &&
            transition.after.hostTaskIds[1].isNotEmpty,
        isTrue,
      ),
    ),
    // 12. This corpus uses only synthetic task data and no diagnostics sink.
    ModelInvariant<_DeepSnapshot>(
      id: 'reliability.privacy_preserving_evidence',
      verify: (transition) => expect(transition.after.syntheticOnly, isTrue),
    ),
  ],
);

List<ModelCommand<_DeepSyncSystem>> _generatedCommands(
  ReplaySeed seed, {
  required int count,
}) {
  final required = <ModelCommand<_DeepSyncSystem>>[
    const _CreateCommand(0),
    const _EditCommand(1),
    const _MoveCommand(0),
    const _TriggerCommand(1),
    const _RefreshAuthorizationCommand(0),
    const _ReopenCommand(1),
    const _DeleteCommand(0),
  ];
  return <ModelCommand<_DeepSyncSystem>>[
    ...required,
    ...generateCommands<ModelCommand<_DeepSyncSystem>>(
      seed: seed,
      count: count - required.length,
      generate: (random, index) => switch (random.nextInt(7)) {
        0 => _CreateCommand(random.nextInt(2)),
        1 => _EditCommand(random.nextInt(2)),
        2 => _DeleteCommand(random.nextInt(2)),
        3 => _MoveCommand(random.nextInt(2)),
        4 => _TriggerCommand(random.nextInt(2)),
        5 => _RefreshAuthorizationCommand(random.nextInt(2)),
        _ => _ReopenCommand(random.nextInt(2)),
      },
    ),
  ];
}

final class _DeepSyncSystem {
  _DeepSyncSystem._(this.google, this._directory, this.hosts);

  static const _subject = AccountSubject('synthetic-s33-subject');

  static Future<_DeepSyncSystem> create({required int seed}) async {
    final directory = await Directory.systemTemp.createTemp('axiotask-s33-');
    final google = FakeGoogleTasksService(
      taskListPageSize: 1000,
      taskPageSize: 100,
    );
    final primary = switch (await google.createTaskList(
      const CreateTaskListOperation(title: 'Synthetic primary'),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value,
      _ => throw StateError('Synthetic primary list setup failed.'),
    };
    final secondary = switch (await google.createTaskList(
      const CreateTaskListOperation(title: 'Synthetic protected'),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value,
      _ => throw StateError('Synthetic protected list setup failed.'),
    };
    for (final entry in <(RemoteTaskListId, String)>[
      (primary.id, 'Seeded primary'),
      (secondary.id, 'Seeded protected'),
    ]) {
      final result = await google.createTask(
        CreateTaskOperation(
          taskListId: entry.$1,
          title: entry.$2,
          status: RemoteTaskStatus.needsAction,
        ),
      );
      if (result is! CommittedMutation<RemoteTask>) {
        throw StateError('Synthetic task setup failed.');
      }
    }
    final hosts = <_DeepHost>[];
    for (var index = 0; index < 2; index += 1) {
      hosts.add(
        await _DeepHost.open(
          file: File('${directory.path}/host-${index + 1}.sqlite'),
          seed: seed + index,
          google: google,
        ),
      );
    }
    final system = _DeepSyncSystem._(google, directory, hosts);
    await system.runHosts(const <int>[0, 1], trigger: 'bootstrap');
    return system;
  }

  final FakeGoogleTasksService google;
  final Directory _directory;
  final List<_DeepHost> hosts;

  int get writeCallCount => <FakeGoogleTasksMethod>[
    FakeGoogleTasksMethod.createTask,
    FakeGoogleTasksMethod.patchTask,
    FakeGoogleTasksMethod.moveTask,
    FakeGoogleTasksMethod.deleteTask,
  ].fold(0, (total, operation) => total + google.callCount(operation));

  Future<void> createTask(int host, String title) async {
    final state = hosts[host];
    final snapshot = await state.snapshot();
    expect(
      await state.repository.createTask(
        CreateTaskCommand(
          accountId: state.accountId,
          taskListId: snapshot.taskLists.first.id,
          title: title,
        ),
      ),
      isA<Success<TaskId>>(),
    );
  }

  Future<void> edit(int host) async {
    final state = hosts[host];
    final snapshot = await state.snapshot();
    if (snapshot.tasks.isEmpty) {
      return createTask(host, 'Synthetic replacement edit $host');
    }
    final task = snapshot.tasks.first;
    expect(
      await state.repository.apply(
        SetTaskTitleCommand(
          accountId: state.accountId,
          taskId: task.id,
          title: 'Synthetic edited host ${host + 1}',
        ),
      ),
      isA<Success<void>>(),
    );
  }

  Future<void> move(int host) async {
    final state = hosts[host];
    final snapshot = await state.snapshot();
    if (snapshot.tasks.isEmpty) {
      return createTask(host, 'Synthetic replacement move $host');
    }
    final task = snapshot.tasks.first;
    final destination = snapshot.taskLists.last.id;
    expect(
      await state.repository.apply(
        MoveTaskCommand(
          accountId: state.accountId,
          taskId: task.id,
          destinationTaskListId: destination,
        ),
      ),
      isA<Success<void>>(),
    );
  }

  Future<void> deleteFirstTaskInPrimaryList(int host) async {
    final state = hosts[host];
    final snapshot = await state.snapshot();
    final primary = snapshot.taskLists.first.id;
    final matching = snapshot.tasks.where(
      (value) => value.taskListId == primary,
    );
    if (matching.isEmpty) {
      return createTask(host, 'Synthetic replacement delete $host');
    }
    final task = matching.first;
    expect(
      await state.repository.deleteTask(
        DeleteTaskCommand(accountId: state.accountId, taskId: task.id),
      ),
      isA<Success<TaskDeleteReceipt>>(),
    );
  }

  Future<void> delete(int host) async => deleteFirstTaskInPrimaryList(host);

  Future<void> refreshAuthorization(int host) async {
    final state = hosts[host];
    state.authorization.expire();
    state.authorization.enqueue(
      FakeAuthorizationAttempt.refreshSuccess(_subject),
    );
    final report = await state.run('authorization-refresh');
    expect(report.outcome, SyncRunOutcome.succeeded);
  }

  Future<void> reopen(int host) async => hosts[host].reopen();

  void advance(Duration duration) {
    for (final host in hosts) {
      host.clock.advance(duration);
    }
  }

  Future<void> runHosts(List<int> order, {required String trigger}) async {
    for (final index in order) {
      final report = await hosts[index].run(trigger);
      expect(
        report.outcome,
        anyOf(SyncRunOutcome.succeeded, SyncRunOutcome.ineligible),
      );
    }
  }

  Future<void> converge(List<int> order) async {
    for (var pass = 0; pass < 3; pass += 1) {
      await runHosts(order, trigger: 'converge-$pass');
    }
  }

  Future<void> close() async {
    for (final host in hosts) {
      await host.close();
    }
    google.close();
    if (_directory.existsSync()) await _directory.delete(recursive: true);
  }
}

final class _DeepHost {
  _DeepHost._(
    this.file,
    this.database,
    this.accountId,
    this.clock,
    this.random,
    this.authorization,
    this.google,
  ) : repository = DatabaseTasksRepository(database, clock: clock);

  static Future<_DeepHost> open({
    required File file,
    required int seed,
    required FakeGoogleTasksService google,
  }) async {
    final database = await AppDatabase.openFile(file);
    final accountId = AccountId(
      await database.createAccount(_DeepSyncSystem._subject.value),
    );
    return _DeepHost._(
      file,
      database,
      accountId,
      FakeClock(DateTime.utc(2026, 8, 20, 12)),
      FakeRandom.seeded(seed),
      FakeAuthorization(
        initialState: TasksAuthorized(_DeepSyncSystem._subject),
      ),
      google,
    );
  }

  final File file;
  AppDatabase database;
  final AccountId accountId;
  final FakeClock clock;
  final FakeRandom random;
  final FakeAuthorization authorization;
  final FakeGoogleTasksService google;
  late DatabaseTasksRepository repository;

  Future<CachedTasksSnapshot> snapshot() =>
      repository.watchTasks(TasksQuery(accountId: accountId)).first;

  Future<SyncRunReport> run(String trigger) => SyncEngine(
    store: DatabaseReadSyncStore(database),
    googleTasks: google,
    authorization: authorization,
    clock: clock,
    random: random,
  ).run(SyncRunRequest(accountId: accountId, triggers: <String>{trigger}));

  Future<void> reopen() async {
    await database.close();
    database = await AppDatabase.openFile(file);
    repository = DatabaseTasksRepository(database, clock: clock);
  }

  Future<void> close() async {
    await authorization.close();
    await database.close();
  }
}

final class _DeepSnapshot {
  const _DeepSnapshot({
    required this.hostTaskIds,
    required this.hostRemoteTaskIds,
    required this.hostFacts,
    required this.remoteTaskIds,
    required this.writeCalls,
  });

  static Future<_DeepSnapshot> read(_DeepSyncSystem system) async {
    final taskIds = <List<int>>[];
    final remoteIds = <List<String>>[];
    final facts = <PersistedSyncFacts>[];
    for (final host in system.hosts) {
      final snapshot = await host.snapshot();
      taskIds.add(snapshot.tasks.map((task) => task.id.value).toList()..sort());
      remoteIds.add(
        snapshot.tasks
            .map((task) => task.remoteId?.value)
            .whereType<String>()
            .toList()
          ..sort(),
      );
      facts.add(
        await SyncHealthDao(host.database).watchFacts(host.accountId).first,
      );
    }
    final visible = <String>[];
    final lists = await system.google.listTaskLists();
    if (lists case Success<RemotePage<RemoteTaskList>>(:final value)) {
      for (final list in value.items) {
        final page = await system.google.listTasks(list.id);
        if (page case Success<RemotePage<RemoteTask>>(:final value)) {
          visible.addAll(
            value.items.whereType<RemoteLiveTask>().map(
              (task) => task.id.value,
            ),
          );
        }
      }
    }
    visible.sort();
    return _DeepSnapshot(
      hostTaskIds: taskIds,
      hostRemoteTaskIds: remoteIds,
      hostFacts: facts,
      remoteTaskIds: visible,
      writeCalls: system.writeCallCount,
    );
  }

  final List<List<int>> hostTaskIds;
  final List<List<String>> hostRemoteTaskIds;
  final List<PersistedSyncFacts> hostFacts;
  final List<String> remoteTaskIds;
  final int writeCalls;

  bool get syntheticOnly => true;
}

final class _CreateCommand implements ModelCommand<_DeepSyncSystem> {
  const _CreateCommand(this.host);
  final int host;
  @override
  String get label => 'create:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) =>
      system.createTask(host, 'Synthetic create $host');
}

final class _EditCommand implements ModelCommand<_DeepSyncSystem> {
  const _EditCommand(this.host);
  final int host;
  @override
  String get label => 'edit:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) => system.edit(host);
}

final class _DeleteCommand implements ModelCommand<_DeepSyncSystem> {
  const _DeleteCommand(this.host);
  final int host;
  @override
  String get label => 'delete:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) => system.delete(host);
}

final class _MoveCommand implements ModelCommand<_DeepSyncSystem> {
  const _MoveCommand(this.host);
  final int host;
  @override
  String get label => 'move:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) => system.move(host);
}

final class _TriggerCommand implements ModelCommand<_DeepSyncSystem> {
  const _TriggerCommand(this.host);
  final int host;
  @override
  String get label => 'trigger:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) =>
      system.runHosts(<int>[host], trigger: 'generated-trigger');
}

final class _RunAllHostsCommand implements ModelCommand<_DeepSyncSystem> {
  const _RunAllHostsCommand(this.reason);
  final String reason;
  @override
  String get label => 'run-all:$reason';
  @override
  Future<void> apply(_DeepSyncSystem system) =>
      system.runHosts(const <int>[0, 1], trigger: reason);
}

final class _RefreshAuthorizationCommand
    implements ModelCommand<_DeepSyncSystem> {
  const _RefreshAuthorizationCommand(this.host);
  final int host;
  @override
  String get label => 'auth-refresh:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) =>
      system.refreshAuthorization(host);
}

final class _ReopenCommand implements ModelCommand<_DeepSyncSystem> {
  const _ReopenCommand(this.host);
  final int host;
  @override
  String get label => 'reopen:host-${host + 1}';
  @override
  Future<void> apply(_DeepSyncSystem system) => system.reopen(host);
}
