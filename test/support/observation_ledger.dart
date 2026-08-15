import 'package:axiotask/src/core/clock.dart';

sealed class Observation {
  const Observation();
}

final class RepositoryObservation<T> extends Observation {
  const RepositoryObservation(this.stream, this.value);

  final String stream;
  final T value;

  @override
  bool operator ==(Object other) =>
      other is RepositoryObservation<T> &&
      stream == other.stream &&
      value == other.value;

  @override
  int get hashCode => Object.hash(stream, value);
}

final class SyncHealthObservation<T> extends Observation {
  const SyncHealthObservation(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      other is SyncHealthObservation<T> && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

final class UserDetailObservation extends Observation {
  const UserDetailObservation(this.code, this.message);

  final String code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is UserDetailObservation &&
      code == other.code &&
      message == other.message;

  @override
  int get hashCode => Object.hash(code, message);
}

final class DiagnosticObservation extends Observation {
  DiagnosticObservation(this.code, Map<String, Object?> fields)
    : fields = Map<String, Object?>.unmodifiable(fields);

  final String code;
  final Map<String, Object?> fields;

  @override
  bool operator ==(Object other) =>
      other is DiagnosticObservation &&
      code == other.code &&
      _mapsEqual(fields, other.fields);

  @override
  int get hashCode => Object.hash(
    code,
    Object.hashAllUnordered(
      fields.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}

enum RunTransitionState { started, finished, failed, cancelled }

final class RunTransitionObservation extends Observation {
  const RunTransitionObservation({
    required this.runId,
    required this.phase,
    required this.state,
  });

  final String runId;
  final String phase;
  final RunTransitionState state;

  @override
  bool operator ==(Object other) =>
      other is RunTransitionObservation &&
      runId == other.runId &&
      phase == other.phase &&
      state == other.state;

  @override
  int get hashCode => Object.hash(runId, phase, state);
}

final class RequestCountObservation extends Observation {
  const RequestCountObservation(this.operation, this.count);

  final String operation;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is RequestCountObservation &&
      operation == other.operation &&
      count == other.count;

  @override
  int get hashCode => Object.hash(operation, count);
}

final class LedgerEntry {
  const LedgerEntry({
    required this.sequence,
    required this.wallTime,
    required this.monotonicElapsed,
    required this.observation,
  });

  final int sequence;
  final DateTime wallTime;
  final Duration monotonicElapsed;
  final Observation observation;
}

final class ObservationLedger {
  ObservationLedger(this._clock);

  final Clock _clock;
  final List<LedgerEntry> _entries = <LedgerEntry>[];

  List<LedgerEntry> get entries => List<LedgerEntry>.unmodifiable(_entries);

  void record(Observation observation) {
    _entries.add(
      LedgerEntry(
        sequence: _entries.length,
        wallTime: _clock.now(),
        monotonicElapsed: _clock.monotonicElapsed,
        observation: observation,
      ),
    );
  }

  List<T> observationsOf<T extends Observation>() => _entries
      .map((entry) => entry.observation)
      .whereType<T>()
      .toList(growable: false);

  void requireExact(List<Observation> expected) {
    if (_entries.length != expected.length) {
      throw StateError(
        'Observation length mismatch: expected ${expected.length}, '
        'actual ${_entries.length}.',
      );
    }
    for (var index = 0; index < expected.length; index += 1) {
      if (_entries[index].observation != expected[index]) {
        throw StateError('Observation mismatch at sequence $index.');
      }
    }
  }
}

bool _mapsEqual(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) return false;
  return left.entries.every(
    (entry) => right.containsKey(entry.key) && right[entry.key] == entry.value,
  );
}
