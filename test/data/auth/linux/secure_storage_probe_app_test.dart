import 'dart:async';

import 'package:axiotask/main_secure_storage_probe.dart';
import 'package:axiotask/src/data/auth/linux/secure_storage_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rebuilds never repeat the mutating secure-storage probe', (
    tester,
  ) async {
    var calls = 0;
    final result = Completer<LinuxSecureStorageProbeResult>();
    Future<LinuxSecureStorageProbeResult> run(String instanceName) {
      calls += 1;
      expect(instanceName, 'synthetic-instance');
      return result.future;
    }

    final app = SecureStorageProbeApp(
      instanceName: 'synthetic-instance',
      runner: run,
    );
    await tester.pumpWidget(app);
    await tester.pumpWidget(app);
    await tester.pump();

    expect(calls, 1);
  });
}
