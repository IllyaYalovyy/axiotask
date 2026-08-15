import 'dart:async';

import 'package:axiotask/src/data/connectivity/connectivity.dart';

/// Emits connectivity hints only; it has no remote-health or reachability API.
final class FakeConnectivity implements ConnectivityPort {
  FakeConnectivity({ConnectivityHint initialHint = ConnectivityHint.unknown})
    : _currentHint = initialHint;

  final StreamController<ConnectivityHint> _hints =
      StreamController<ConnectivityHint>.broadcast(sync: true);
  final List<ConnectivityHint> _emissionLedger = <ConnectivityHint>[];
  ConnectivityHint _currentHint;
  var _closed = false;

  @override
  ConnectivityHint get currentHint => _currentHint;

  @override
  Stream<ConnectivityHint> get hints => _hints.stream;

  List<ConnectivityHint> get emissionLedger =>
      List<ConnectivityHint>.unmodifiable(_emissionLedger);

  bool emit(ConnectivityHint hint) {
    if (_closed) throw StateError('Fake connectivity is closed.');
    if (_currentHint == hint) return false;
    _currentHint = hint;
    _emissionLedger.add(hint);
    _hints.add(hint);
    return true;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _hints.close();
  }
}
