import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../data/connectivity/connectivity.dart';
export '../data/connectivity/connectivity.dart';

abstract interface class LinuxConnectivitySource {
  Future<List<ConnectivityResult>> checkConnectivity();

  Stream<List<ConnectivityResult>> get changes;
}

final class ConnectivityPlusLinuxSource implements LinuxConnectivitySource {
  ConnectivityPlusLinuxSource([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() =>
      _connectivity.checkConnectivity();

  @override
  Stream<List<ConnectivityResult>> get changes =>
      _connectivity.onConnectivityChanged;
}

/// Linux network-interface observations mapped to scheduling hints only.
///
/// An available interface never claims internet or Google reachability. It is
/// useful only as a may-have-returned transition after the platform previously
/// reported no available route.
final class LinuxConnectivityBridge implements ConnectivityPort {
  LinuxConnectivityBridge._({
    required LinuxConnectivitySource source,
    required ConnectivityHint initialHint,
  }) : _currentHint = initialHint {
    _subscription = source.changes.listen(
      _acceptResults,
      onError: _acceptError,
    );
  }

  static Future<LinuxConnectivityBridge> open({
    LinuxConnectivitySource? source,
  }) async {
    final selected = source ?? ConnectivityPlusLinuxSource();
    var initialHint = ConnectivityHint.unknown;
    try {
      final initial = await selected.checkConnectivity();
      initialHint = _hasInterface(initial)
          ? ConnectivityHint.unknown
          : ConnectivityHint.provenNoRoute;
    } on Object {
      // Unknown is the safe hint when the optional platform observation fails.
    }
    return LinuxConnectivityBridge._(
      source: selected,
      initialHint: initialHint,
    );
  }

  final StreamController<ConnectivityHint> _hints =
      StreamController<ConnectivityHint>.broadcast(sync: true);
  late final StreamSubscription<List<ConnectivityResult>> _subscription;
  ConnectivityHint _currentHint;
  bool _closed = false;

  @override
  ConnectivityHint get currentHint => _currentHint;

  @override
  Stream<ConnectivityHint> get hints => _hints.stream;

  void _acceptResults(List<ConnectivityResult> results) {
    if (_closed) return;
    final hasInterface = _hasInterface(results);
    final next = switch ((_currentHint, hasInterface)) {
      (_, false) => ConnectivityHint.provenNoRoute,
      (ConnectivityHint.provenNoRoute, true) =>
        ConnectivityHint.mayHaveReturned,
      (final current, true) => current,
    };
    _emitDistinct(next);
  }

  void _acceptError(Object _) {
    if (_closed) return;
    _emitDistinct(
      _currentHint == ConnectivityHint.provenNoRoute
          ? ConnectivityHint.mayHaveReturned
          : ConnectivityHint.unknown,
    );
  }

  void _emitDistinct(ConnectivityHint hint) {
    if (_currentHint == hint) return;
    _currentHint = hint;
    _hints.add(hint);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _hints.close();
  }
}

bool _hasInterface(List<ConnectivityResult> results) =>
    results.any((result) => result != ConnectivityResult.none);
