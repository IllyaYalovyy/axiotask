import 'dart:async';

import 'replay_seed.dart';

/// A command applied to the system under test through its public boundary.
abstract interface class ModelCommand<System> {
  String get label;

  FutureOr<void> apply(System system);
}

/// An observed transition. It contains facts, not an expected next state.
final class ModelTransition<Snapshot> {
  const ModelTransition({
    required this.step,
    required this.commandLabel,
    required this.before,
    required this.after,
  });

  final int step;
  final String commandLabel;
  final Snapshot before;
  final Snapshot after;
}

/// An independent invariant checked after every observed transition.
final class ModelInvariant<Snapshot> {
  const ModelInvariant({required this.id, required this.verify});

  final String id;
  final void Function(ModelTransition<Snapshot> transition) verify;
}

final class ModelRunResult<Snapshot> {
  ModelRunResult({
    required this.seed,
    required Iterable<Snapshot> snapshots,
    required Iterable<ModelTransition<Snapshot>> transitions,
  }) : snapshots = List<Snapshot>.unmodifiable(snapshots),
       transitions = List<ModelTransition<Snapshot>>.unmodifiable(transitions);

  final ReplaySeed seed;
  final List<Snapshot> snapshots;
  final List<ModelTransition<Snapshot>> transitions;
}

final class ModelRunFailure implements Exception {
  const ModelRunFailure({
    required this.seed,
    required this.step,
    required this.commandLabel,
    required this.invariantId,
    required this.cause,
  });

  final ReplaySeed seed;
  final int step;
  final String commandLabel;
  final String invariantId;
  final Object cause;

  @override
  String toString() =>
      'Model invariant $invariantId failed at step $step. ${seed.replayHint}';
}

final class ModelExecutionFailure implements Exception {
  const ModelExecutionFailure({
    required this.seed,
    required this.step,
    required this.stage,
    required this.cause,
  });

  final ReplaySeed seed;
  final int step;
  final String stage;
  final Object cause;

  @override
  String toString() => 'Model $stage failed at step $step. ${seed.replayHint}';
}

final class QuiescenceLimitExceeded implements Exception {
  const QuiescenceLimitExceeded({
    required this.seed,
    required this.maxTransitions,
    required this.lastSnapshot,
  });

  final ReplaySeed seed;
  final int maxTransitions;
  final Object? lastSnapshot;

  @override
  String toString() =>
      'System did not reach quiescence within $maxTransitions transitions. '
      '${seed.replayHint}';
}

/// Observes a system under test and checks independent invariants.
///
/// The model never computes an expected reconciliation result. Commands drive
/// the real test boundary, [snapshot] reads the resulting facts, and each
/// invariant decides whether the observed transition remains legal.
final class ReferenceModel<System, Snapshot> {
  factory ReferenceModel({
    required FutureOr<Snapshot> Function(System system) snapshot,
    required Iterable<ModelInvariant<Snapshot>> invariants,
  }) {
    final invariantList = List<ModelInvariant<Snapshot>>.unmodifiable(
      invariants,
    );
    final ids = invariantList.map((invariant) => invariant.id).toSet();
    if (ids.length != invariantList.length ||
        ids.any((id) => id.trim().isEmpty)) {
      throw ArgumentError.value(
        invariants,
        'invariants',
        'must have unique, non-empty IDs',
      );
    }
    return ReferenceModel<System, Snapshot>._(snapshot, invariantList);
  }

  ReferenceModel._(this._snapshot, this._invariants);

  final FutureOr<Snapshot> Function(System system) _snapshot;
  final List<ModelInvariant<Snapshot>> _invariants;

  Future<ModelRunResult<Snapshot>> run(
    System system,
    Iterable<ModelCommand<System>> commands, {
    required ReplaySeed seed,
    void Function(String message)? failureSink,
  }) async {
    final snapshots = <Snapshot>[
      await _initialSnapshot(system, seed, failureSink),
    ];
    final transitions = <ModelTransition<Snapshot>>[];
    var step = 0;
    for (final command in commands) {
      step += 1;
      final transition = await _apply(
        system,
        command,
        before: snapshots.last,
        step: step,
        seed: seed,
        failureSink: failureSink,
      );
      transitions.add(transition);
      snapshots.add(transition.after);
    }
    return ModelRunResult<Snapshot>(
      seed: seed,
      snapshots: snapshots,
      transitions: transitions,
    );
  }

  Future<ModelRunResult<Snapshot>> runToQuiescence(
    System system, {
    required ModelCommand<System> Function(Snapshot snapshot) nextCommand,
    required bool Function(Snapshot snapshot) isQuiescent,
    required int maxTransitions,
    required ReplaySeed seed,
    void Function(String message)? failureSink,
  }) async {
    if (maxTransitions < 0) {
      throw ArgumentError.value(
        maxTransitions,
        'maxTransitions',
        'must not be negative',
      );
    }
    final snapshots = <Snapshot>[
      await _initialSnapshot(system, seed, failureSink),
    ];
    final transitions = <ModelTransition<Snapshot>>[];
    while (!isQuiescent(snapshots.last)) {
      if (transitions.length == maxTransitions) {
        final failure = QuiescenceLimitExceeded(
          seed: seed,
          maxTransitions: maxTransitions,
          lastSnapshot: snapshots.last,
        );
        (failureSink ?? print)(failure.toString());
        throw failure;
      }
      final step = transitions.length + 1;
      final transition = await _apply(
        system,
        nextCommand(snapshots.last),
        before: snapshots.last,
        step: step,
        seed: seed,
        failureSink: failureSink,
      );
      transitions.add(transition);
      snapshots.add(transition.after);
    }
    return ModelRunResult<Snapshot>(
      seed: seed,
      snapshots: snapshots,
      transitions: transitions,
    );
  }

  Future<ModelTransition<Snapshot>> _apply(
    System system,
    ModelCommand<System> command, {
    required Snapshot before,
    required int step,
    required ReplaySeed seed,
    required void Function(String message)? failureSink,
  }) async {
    if (command.label.trim().isEmpty) {
      throw ArgumentError.value(command.label, 'command.label');
    }
    late final Snapshot after;
    try {
      await command.apply(system);
      after = await _snapshot(system);
    } on Object catch (cause) {
      final failure = ModelExecutionFailure(
        seed: seed,
        step: step,
        stage: 'command or snapshot',
        cause: cause,
      );
      (failureSink ?? print)(failure.toString());
      throw failure;
    }
    final transition = ModelTransition<Snapshot>(
      step: step,
      commandLabel: command.label,
      before: before,
      after: after,
    );
    for (final invariant in _invariants) {
      try {
        invariant.verify(transition);
      } on Object catch (cause) {
        final failure = ModelRunFailure(
          seed: seed,
          step: step,
          commandLabel: command.label,
          invariantId: invariant.id,
          cause: cause,
        );
        (failureSink ?? print)(failure.toString());
        throw failure;
      }
    }
    return transition;
  }

  Future<Snapshot> _initialSnapshot(
    System system,
    ReplaySeed seed,
    void Function(String message)? failureSink,
  ) async {
    try {
      return await _snapshot(system);
    } on Object catch (cause) {
      final failure = ModelExecutionFailure(
        seed: seed,
        step: 0,
        stage: 'initial snapshot',
        cause: cause,
      );
      (failureSink ?? print)(failure.toString());
      throw failure;
    }
  }
}
