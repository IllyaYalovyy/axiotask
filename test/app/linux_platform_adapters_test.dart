import 'dart:async';
import 'dart:ui';

import 'package:axiotask/src/app/connectivity.dart';
import 'package:axiotask/src/app/lifecycle.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Linux lifecycle reports focus and exit without losing eligibility',
    () async {
      final bridge = LinuxLifecycleBridge();
      addTearDown(bridge.close);
      final facts = <LifecycleFact>[];
      bridge.facts.listen(facts.add);

      bridge.didChangeViewFocus(
        const ViewFocusEvent(
          viewId: 0,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      bridge.didChangeAppLifecycleState(AppLifecycleState.hidden);
      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final response = await bridge.didRequestAppExit();

      expect(bridge.currentEligibility, LifecycleEligibility.foreground);
      expect(bridge.isWindowFocused, isFalse);
      expect(response, AppExitResponse.exit);
      expect(facts, <LifecycleFact>[
        const WindowFocusChanged(isFocused: false),
        const LifecycleForegrounded(),
        const ProcessExitRequested(),
      ]);
    },
  );

  test(
    'Linux connectivity maps only absence to no-route and recovery to hint',
    () async {
      final source = _ConnectivitySource(<ConnectivityResult>[
        ConnectivityResult.ethernet,
      ]);
      final bridge = await LinuxConnectivityBridge.open(source: source);
      addTearDown(bridge.close);
      final hints = <ConnectivityHint>[];
      bridge.hints.listen(hints.add);

      expect(bridge.currentHint, ConnectivityHint.unknown);
      source.emit(const <ConnectivityResult>[ConnectivityResult.none]);
      source.emit(const <ConnectivityResult>[ConnectivityResult.none]);
      source.emit(const <ConnectivityResult>[ConnectivityResult.wifi]);
      source.emit(const <ConnectivityResult>[ConnectivityResult.wifi]);

      expect(hints, <ConnectivityHint>[
        ConnectivityHint.provenNoRoute,
        ConnectivityHint.mayHaveReturned,
      ]);
    },
  );
}

final class _ConnectivitySource implements LinuxConnectivitySource {
  _ConnectivitySource(this.current);

  List<ConnectivityResult> current;
  final StreamController<List<ConnectivityResult>> _changes =
      StreamController<List<ConnectivityResult>>.broadcast(sync: true);

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get changes => _changes.stream;

  void emit(List<ConnectivityResult> results) {
    current = results;
    _changes.add(results);
  }
}
