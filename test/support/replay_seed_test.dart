import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_google_tasks_service.dart';
import 'multi_host.dart';
import 'reference_model.dart';
import 'replay_seed.dart';

void main() {
  group('ReplaySeed qualification', () {
    test(
      'prints the selected seed on failure and resolves exact replay',
      () async {
        final seed = ReplaySeed.resolve(
          fallback: 12,
          environment: const <String, String>{
            ReplaySeed.environmentKey: '0x49',
          },
        );
        final messages = <String>[];
        final model = ReferenceModel<_ReplaySystem, _ReplaySnapshot>(
          snapshot: (system) => _ReplaySnapshot(system.value),
          invariants: <ModelInvariant<_ReplaySnapshot>>[
            ModelInvariant<_ReplaySnapshot>(
              id: 'replay.maximum',
              verify: (transition) {
                if (transition.after.value > 2) {
                  throw StateError('Forced qualification failure.');
                }
              },
            ),
          ],
        );

        await expectLater(
          model.run(
            _ReplaySystem(),
            const <ModelCommand<_ReplaySystem>>[_AddCommand(3)],
            seed: seed,
            failureSink: messages.add,
          ),
          throwsA(isA<ModelRunFailure>()),
        );

        expect(seed, const ReplaySeed(73));
        expect(messages.single, contains('AXIOTASK_REPLAY_SEED=73'));
        expect(messages.single, contains('replay.maximum'));
      },
    );

    test(
      'fixed seed reproduces commands and complete transition trace',
      () async {
        const seed = ReplaySeed(1907);
        final firstCommands = generateCommands<_AddCommand>(
          seed: seed,
          count: 12,
          generate: (random, _) => _AddCommand(random.nextBool() ? 1 : -1),
        );
        final replayCommands = generateCommands<_AddCommand>(
          seed: seed,
          count: 12,
          generate: (random, _) => _AddCommand(random.nextBool() ? 1 : -1),
        );
        final model = ReferenceModel<_ReplaySystem, _ReplaySnapshot>(
          snapshot: (system) => _ReplaySnapshot(system.value),
          invariants: const <ModelInvariant<_ReplaySnapshot>>[],
        );

        final first = await model.run(
          _ReplaySystem(),
          firstCommands,
          seed: seed,
        );
        final replay = await model.run(
          _ReplaySystem(),
          replayCommands,
          seed: seed,
        );

        expect(
          replayCommands.map((command) => command.label),
          firstCommands.map((command) => command.label),
        );
        expect(replay.snapshots, first.snapshots);
        expect(
          replay.transitions.map((transition) => transition.commandLabel),
          first.transitions.map((transition) => transition.commandLabel),
        );
      },
    );

    test(
      'replays store, fake service, call, and visible evidence exactly',
      () async {
        const seed = ReplaySeed(509);
        final commands = generateCommands<_HostCreateCommand>(
          seed: seed,
          count: 4,
          generate: (random, index) => _HostCreateCommand(
            hostIndex: random.nextInt(2),
            title: 'Synthetic replay $index-${random.nextInt(100)}',
          ),
        );
        final model = ReferenceModel<_HostReplaySystem, _HostReplaySnapshot>(
          snapshot: _HostReplaySnapshot.read,
          invariants: const <ModelInvariant<_HostReplaySnapshot>>[],
        );

        final firstSystem = await _HostReplaySystem.create();
        final first = await model.run(firstSystem, commands, seed: seed);
        await firstSystem.close();
        final replaySystem = await _HostReplaySystem.create();
        final replay = await model.run(replaySystem, commands, seed: seed);
        await replaySystem.close();

        expect(replay.snapshots, first.snapshots);
        expect(
          replay.transitions.map((transition) => transition.commandLabel),
          first.transitions.map((transition) => transition.commandLabel),
        );
      },
    );

    test('shrinks a forced failure to the same minimal replay trace', () async {
      const original = <_AddCommand>[
        _AddCommand(1),
        _AddCommand(1),
        _AddCommand(99),
        _AddCommand(-1),
      ];
      Future<bool> fails(List<_AddCommand> commands) async {
        final system = _ReplaySystem();
        for (final command in commands) {
          command.apply(system);
          if (system.value >= 99) return true;
        }
        return false;
      }

      final first = await shrinkFailingTrace<_AddCommand>(
        original,
        fails: fails,
      );
      final replay = await shrinkFailingTrace<_AddCommand>(
        original,
        fails: fails,
      );

      expect(first.map((command) => command.label), <String>['add:99']);
      expect(
        replay.map((command) => command.label),
        first.map((command) => command.label),
      );
    });
  });
}

final class _ReplaySystem {
  int value = 0;
}

final class _ReplaySnapshot {
  const _ReplaySnapshot(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is _ReplaySnapshot && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class _AddCommand implements ModelCommand<_ReplaySystem> {
  const _AddCommand(this.amount);

  final int amount;

  @override
  String get label => 'add:$amount';

  @override
  void apply(_ReplaySystem system) => system.value += amount;
}

final class _HostReplaySystem {
  _HostReplaySystem._(this.harness, this.google);

  static Future<_HostReplaySystem> create() async {
    final google = FakeGoogleTasksService(taskListPageSize: 1000);
    final harness = await MultiHostHarness.create(
      hostCount: 2,
      googleTasks: google,
      accountSubject: const AccountSubject('synthetic-replay-subject'),
      initialWallTime: DateTime.utc(2026, 8, 15, 12),
      seed: 509,
    );
    for (final host in harness.hosts) {
      await host.store.createAccount('synthetic-replay-subject');
    }
    return _HostReplaySystem._(harness, google);
  }

  final MultiHostHarness harness;
  final FakeGoogleTasksService google;
  final List<String> visibleSequence = <String>[];

  Future<void> close() => harness.close();
}

final class _HostCreateCommand implements ModelCommand<_HostReplaySystem> {
  const _HostCreateCommand({required this.hostIndex, required this.title});

  final int hostIndex;
  final String title;

  @override
  String get label => 'host:$hostIndex:create:$title';

  @override
  Future<void> apply(_HostReplaySystem system) async {
    await system.harness.hosts[hostIndex].googleTasks.createTaskList(
      CreateTaskListOperation(title: title),
    );
    system.visibleSequence.add('remote-change:${hostIndex + 1}');
  }
}

final class _HostReplaySnapshot {
  _HostReplaySnapshot._(this.canonicalEvidence);

  static Future<_HostReplaySnapshot> read(_HostReplaySystem system) async {
    final accounts = <String>[];
    for (final host in system.harness.hosts) {
      final rows = await host.store.allAccounts();
      accounts.add(
        '${host.installationId}:'
        '${rows.map((row) => '${row.id}/${row.googleSubject}').join(',')}',
      );
    }
    final remoteOutcome = await system.google.listTaskLists();
    final remote = switch (remoteOutcome) {
      Success<RemotePage<RemoteTaskList>>(:final value) =>
        value.items.map((item) => '${item.id.value}/${item.title}').join(','),
      Failed<RemotePage<RemoteTaskList>>(:final failure) =>
        'failure:${failure.code}',
    };
    final calls = system.google.calls
        .map(
          (call) =>
              '${call.operation.name}/${call.method}/${call.path}/'
              '${call.body?['title'] ?? '-'}',
        )
        .join(',');
    return _HostReplaySnapshot._(
      '${accounts.join('|')}|remote=$remote|calls=$calls|'
      'visible=${system.visibleSequence.join(',')}',
    );
  }

  final String canonicalEvidence;

  @override
  bool operator ==(Object other) =>
      other is _HostReplaySnapshot &&
      other.canonicalEvidence == canonicalEvidence;

  @override
  int get hashCode => canonicalEvidence.hashCode;
}
