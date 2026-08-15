import 'package:flutter_test/flutter_test.dart';

import 'fake_clock.dart';
import 'observation_ledger.dart';

void main() {
  group('ObservationLedger qualification', () {
    test('preserves typed observation and timestamp order', () {
      final clock = FakeClock(DateTime.utc(2026, 8, 15, 12));
      final ledger = ObservationLedger(clock);

      ledger.record(
        const RepositoryObservation<String>('tasks', 'synthetic snapshot'),
      );
      clock.advance(const Duration(milliseconds: 1));
      ledger.record(const SyncHealthObservation<String>('pending'));
      ledger.record(
        const RunTransitionObservation(
          runId: 'synthetic-run',
          phase: 'enumerate',
          state: RunTransitionState.started,
        ),
      );
      ledger.record(const RequestCountObservation('listTasks', 1));
      ledger.record(
        const UserDetailObservation('sync.verifying', 'Checking Google Tasks'),
      );
      ledger.record(
        DiagnosticObservation('sync.page', const <String, Object?>{
          'resourceCount': 2,
        }),
      );

      expect(ledger.entries.map((entry) => entry.sequence), <int>[
        0,
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(ledger.entries.first.wallTime, DateTime.utc(2026, 8, 15, 12));
      expect(
        ledger.entries[1].monotonicElapsed,
        const Duration(milliseconds: 1),
      );
      expect(
        ledger.observationsOf<RequestCountObservation>(),
        <RequestCountObservation>[
          const RequestCountObservation('listTasks', 1),
        ],
      );
    });

    test('exact-order oracle rejects a deliberately wrong consumer', () {
      final clock = FakeClock(DateTime.utc(2026, 8, 15, 12));
      const started = RunTransitionObservation(
        runId: 'synthetic-run',
        phase: 'execute',
        state: RunTransitionState.started,
      );
      const finished = RunTransitionObservation(
        runId: 'synthetic-run',
        phase: 'execute',
        state: RunTransitionState.finished,
      );
      final correctLedger = ObservationLedger(clock)
        ..record(started)
        ..record(finished);
      expect(
        () => correctLedger.requireExact(<Observation>[started, finished]),
        returnsNormally,
      );

      final wrongLedger = ObservationLedger(clock);
      final wrongConsumer = _WrongRunConsumer(wrongLedger);
      wrongConsumer.run();

      expect(
        () => wrongLedger.requireExact(<Observation>[started, finished]),
        throwsStateError,
      );
    });
  });
}

final class _WrongRunConsumer {
  _WrongRunConsumer(this._ledger);

  final ObservationLedger _ledger;

  void run() {
    _ledger
      ..record(
        const RunTransitionObservation(
          runId: 'synthetic-run',
          phase: 'execute',
          state: RunTransitionState.finished,
        ),
      )
      ..record(
        const RunTransitionObservation(
          runId: 'synthetic-run',
          phase: 'execute',
          state: RunTransitionState.started,
        ),
      );
  }
}
