import 'dart:async';

enum BarrierPoint {
  runPhase,
  beforePagePublication,
  afterPagePublication,
  beforeRequestDispatch,
  afterServerCommit,
  beforeResponseHeaders,
  beforeResponseChunk,
  afterResponseDelivery,
  beforeTransactionBegin,
  beforeTransactionCommit,
  afterTransactionCommit,
}

final class BarrierAddress {
  const BarrierAddress({
    required this.point,
    required this.operation,
    this.scope,
    this.chunkIndex,
  }) : assert(operation != '');

  final BarrierPoint point;
  final String operation;
  final String? scope;
  final int? chunkIndex;

  @override
  bool operator ==(Object other) =>
      other is BarrierAddress &&
      point == other.point &&
      operation == other.operation &&
      scope == other.scope &&
      chunkIndex == other.chunkIndex;

  @override
  int get hashCode => Object.hash(point, operation, scope, chunkIndex);

  @override
  String toString() =>
      'BarrierAddress(${point.name}, $operation, '
      'scope: $scope, chunkIndex: $chunkIndex)';
}

enum BarrierOutcome { passed, released, cancelled, killed }

final class BarrierResolution {
  const BarrierResolution(this.address, this.outcome);

  final BarrierAddress address;
  final BarrierOutcome outcome;

  @override
  bool operator ==(Object other) =>
      other is BarrierResolution &&
      address == other.address &&
      outcome == other.outcome;

  @override
  int get hashCode => Object.hash(address, outcome);
}

final class DeterministicBarriers {
  final Map<BarrierAddress, _BarrierGate> _gates =
      <BarrierAddress, _BarrierGate>{};
  final List<BarrierAddress> _arrivals = <BarrierAddress>[];
  final List<BarrierResolution> _resolutions = <BarrierResolution>[];

  List<BarrierAddress> get arrivals =>
      List<BarrierAddress>.unmodifiable(_arrivals);

  List<BarrierResolution> get resolutions =>
      List<BarrierResolution>.unmodifiable(_resolutions);

  BarrierHandle arm(BarrierAddress address) {
    if (_gates.containsKey(address)) {
      throw StateError('Barrier is already armed: $address');
    }
    final gate = _BarrierGate(address);
    _gates[address] = gate;
    return BarrierHandle._(this, gate);
  }

  Future<BarrierOutcome> reach(BarrierAddress address) {
    _arrivals.add(address);
    final gate = _gates[address];
    if (gate == null) {
      return Future<BarrierOutcome>.value(BarrierOutcome.passed);
    }
    if (gate.reached.isCompleted) {
      throw StateError('Armed barrier was reached more than once: $address');
    }
    gate.reached.complete();
    return gate.outcome.future;
  }

  bool _resolve(_BarrierGate gate, BarrierOutcome outcome) {
    if (!gate.reached.isCompleted || gate.outcome.isCompleted) return false;
    gate.outcome.complete(outcome);
    _resolutions.add(BarrierResolution(gate.address, outcome));
    _gates.remove(gate.address);
    return true;
  }
}

final class BarrierHandle {
  BarrierHandle._(this._owner, this._gate);

  final DeterministicBarriers _owner;
  final _BarrierGate _gate;

  Future<void> get whenReached => _gate.reached.future;

  bool get isWaiting => _gate.reached.isCompleted && !_gate.outcome.isCompleted;

  bool release() => _owner._resolve(_gate, BarrierOutcome.released);

  bool cancel() => _owner._resolve(_gate, BarrierOutcome.cancelled);

  bool kill() => _owner._resolve(_gate, BarrierOutcome.killed);
}

final class _BarrierGate {
  _BarrierGate(this.address);

  final BarrierAddress address;
  final Completer<void> reached = Completer<void>();
  final Completer<BarrierOutcome> outcome = Completer<BarrierOutcome>();
}
