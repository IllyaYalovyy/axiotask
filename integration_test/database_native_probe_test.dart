import 'package:axiotask/main_database_probe.dart' as probe;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('production native database passes the platform probe', (
    tester,
  ) async {
    await tester.pumpWidget(
      const probe.DatabaseProbeApp(instanceName: 'automated-s02'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('database-probe-passed')), findsOneWidget);
    expect(find.byKey(const Key('database-probe-failed')), findsNothing);
    expect(find.text('schemaVersion=1'), findsOneWidget);
    expect(find.text('accountCount=1'), findsOneWidget);
    expect(find.text('journalMode=wal'), findsOneWidget);
    expect(find.text('foreignKeys=true'), findsOneWidget);
    expect(find.text('synchronous=full'), findsOneWidget);
    expect(find.text('busyTimeoutMs=5000'), findsOneWidget);
    expect(find.text('walAutoCheckpointPages=1000'), findsOneWidget);
    expect(find.text('sqliteVersion=3.53.4'), findsOneWidget);
  });
}
