import 'package:axiotask/main_secure_storage_probe.dart' as probe;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GNOME Secret Service passes the isolated credential probe', (
    tester,
  ) async {
    await tester.pumpWidget(
      const probe.SecureStorageProbeApp(instanceName: 'automated-s04'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('secure-storage-probe-passed')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('secure-storage-probe-failed')), findsNothing);
    expect(find.text('bundleSchemaVersion=1'), findsOneWidget);
    expect(find.text('operationsVerified=6'), findsOneWidget);
    expect(find.text('dedicatedNamespace=true'), findsOneWidget);
    expect(find.text('cleanupVerified=true'), findsOneWidget);
  });
}
