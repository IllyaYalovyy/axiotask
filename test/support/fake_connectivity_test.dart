import 'package:axiotask/src/data/connectivity/connectivity.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_connectivity.dart';

void main() {
  group('FakeConnectivity qualification', () {
    test('emits hints through the production port and coalesces repeats', () {
      final ConnectivityPort connectivity = FakeConnectivity();
      final fake = connectivity as FakeConnectivity;
      addTearDown(fake.close);
      final hints = <ConnectivityHint>[];
      connectivity.hints.listen(hints.add);

      expect(fake.emit(ConnectivityHint.provenNoRoute), isTrue);
      expect(fake.emit(ConnectivityHint.provenNoRoute), isFalse);
      expect(fake.emit(ConnectivityHint.mayHaveReturned), isTrue);
      expect(fake.emit(ConnectivityHint.mayHaveReturned), isFalse);
      expect(fake.emit(ConnectivityHint.unknown), isTrue);
      expect(fake.emit(ConnectivityHint.unknown), isFalse);

      expect(hints, <ConnectivityHint>[
        ConnectivityHint.provenNoRoute,
        ConnectivityHint.mayHaveReturned,
        ConnectivityHint.unknown,
      ]);
      expect(connectivity.currentHint, ConnectivityHint.unknown);
    });

    test('a positive hint does not claim reachability or remote success', () {
      final fake = FakeConnectivity();
      addTearDown(fake.close);

      fake.emit(ConnectivityHint.mayHaveReturned);

      expect(fake.currentHint, ConnectivityHint.mayHaveReturned);
      expect(fake.emissionLedger, <ConnectivityHint>[
        ConnectivityHint.mayHaveReturned,
      ]);
    });

    test('fails itself when driven after close', () async {
      final fake = FakeConnectivity();
      await fake.close();

      expect(() => fake.emit(ConnectivityHint.provenNoRoute), throwsStateError);
    });
  });
}
