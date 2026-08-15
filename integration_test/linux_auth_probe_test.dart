import 'package:axiotask/main_linux_auth_probe.dart' as probe;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Google passes isolated Linux PKCE, DPoP, refresh, and Tasks proof',
    (tester) async {
      await tester.pumpWidget(
        probe.LinuxAuthProbeApp(
          configuration: probe.configurationFromEnvironment(),
        ),
      );
      expect(find.byKey(const Key('linux-auth-probe-pending')), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.byKey(const Key('linux-auth-probe-passed')), findsOneWidget);
      expect(find.byKey(const Key('linux-auth-probe-failed')), findsNothing);
      expect(find.text('pkceExchangeVerified=true'), findsOneWidget);
      expect(find.text('dpopNonceVerified=true'), findsOneWidget);
      expect(find.text('restartRestoreVerified=true'), findsOneWidget);
      expect(find.text('taskListsCallVerified=true'), findsOneWidget);
      expect(find.text('credentialCleanupVerified=true'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
