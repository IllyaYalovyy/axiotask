import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'reference_model.dart';
import 'replay_seed.dart';

void main() {
  group('ReferenceModel qualification', () {
    test('rejects a deliberately invalid transition after that step', () async {
      final system = _CounterSystem();
      final model = _counterModel();

      final failure = await _captureFailure(
        () => model.run(
          system,
          const <ModelCommand<_CounterSystem>>[
            _DeltaCommand(2),
            _DeltaCommand(-3),
          ],
          seed: const ReplaySeed(41),
          failureSink: (_) {},
        ),
      );

      expect(failure.invariantId, 'counter.non_negative');
      expect(failure.step, 2);
      expect(failure.commandLabel, 'delta:-3');
    });

    test(
      'independent invariant catches a mutated consumer algorithm',
      () async {
        final system = _AccountSystem();
        final model = ReferenceModel<_AccountSystem, _AccountSnapshot>(
          snapshot: (value) => _AccountSnapshot(value.alpha, value.beta),
          invariants: <ModelInvariant<_AccountSnapshot>>[
            ModelInvariant<_AccountSnapshot>(
              id: 'account.beta_unchanged',
              verify: (transition) {
                if (transition.after.beta != transition.before.beta) {
                  throw StateError('A mutation escaped its account scope.');
                }
              },
            ),
          ],
        );

        final failure = await _captureFailure(
          () => model.run(
            system,
            const <ModelCommand<_AccountSystem>>[_MutatedAlphaIncrement()],
            seed: const ReplaySeed(99),
            failureSink: (_) {},
          ),
        );

        expect(system.alpha, 1);
        expect(system.beta, 1);
        expect(failure.invariantId, 'account.beta_unchanged');
      },
    );

    test('checks every transition while driving bounded quiescence', () async {
      final system = _CounterSystem(value: 3);
      final result = await _counterModel().runToQuiescence(
        system,
        nextCommand: (_) => const _DeltaCommand(-1),
        isQuiescent: (snapshot) => snapshot.value == 0,
        maxTransitions: 3,
        seed: const ReplaySeed(13),
      );

      expect(result.transitions, hasLength(3));
      expect(result.snapshots.map((snapshot) => snapshot.value), <int>[
        3,
        2,
        1,
        0,
      ]);

      await expectLater(
        _counterModel().runToQuiescence(
          _CounterSystem(value: 3),
          nextCommand: (_) => const _DeltaCommand(0),
          isQuiescent: (snapshot) => snapshot.value == 0,
          maxTransitions: 2,
          seed: const ReplaySeed(13),
          failureSink: (_) {},
        ),
        throwsA(isA<QuiescenceLimitExceeded>()),
      );
    });
  });
}

ReferenceModel<_CounterSystem, _CounterSnapshot> _counterModel() =>
    ReferenceModel<_CounterSystem, _CounterSnapshot>(
      snapshot: (system) => _CounterSnapshot(system.value),
      invariants: <ModelInvariant<_CounterSnapshot>>[
        ModelInvariant<_CounterSnapshot>(
          id: 'counter.non_negative',
          verify: (transition) {
            if (transition.after.value < 0) {
              throw StateError('Counter must remain non-negative.');
            }
          },
        ),
      ],
    );

Future<ModelRunFailure> _captureFailure(
  FutureOr<void> Function() operation,
) async {
  try {
    await operation();
  } on ModelRunFailure catch (failure) {
    return failure;
  }
  throw StateError('Expected ModelRunFailure.');
}

final class _CounterSystem {
  _CounterSystem({this.value = 0});

  int value;
}

final class _CounterSnapshot {
  const _CounterSnapshot(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is _CounterSnapshot && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class _DeltaCommand implements ModelCommand<_CounterSystem> {
  const _DeltaCommand(this.delta);

  final int delta;

  @override
  String get label => 'delta:$delta';

  @override
  void apply(_CounterSystem system) => system.value += delta;
}

final class _AccountSystem {
  int alpha = 0;
  int beta = 0;
}

final class _AccountSnapshot {
  const _AccountSnapshot(this.alpha, this.beta);

  final int alpha;
  final int beta;
}

/// Deliberately faulty mutation: it changes an account outside its target.
final class _MutatedAlphaIncrement implements ModelCommand<_AccountSystem> {
  const _MutatedAlphaIncrement();

  @override
  String get label => 'increment:alpha';

  @override
  void apply(_AccountSystem system) {
    system.alpha += 1;
    system.beta += 1;
  }
}
