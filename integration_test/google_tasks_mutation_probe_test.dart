import 'package:axiotask/main_google_tasks_mutation_probe.dart' as probe;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Google passes isolated optional-clear and stale-source DELETE probes',
    (tester) async {
      await tester.pumpWidget(
        probe.GoogleTasksMutationProbeApp(
          configuration: probe.configurationFromEnvironment(),
        ),
      );
      expect(
        find.byKey(const Key('google-mutation-probe-pending')),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(
        find.byKey(const Key('google-mutation-probe-passed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('google-mutation-probe-failed')),
        findsNothing,
      );
      expect(find.text('notesNullClearing=true'), findsOneWidget);
      expect(find.text('dueNullClearing=true'), findsOneWidget);
      expect(find.text('cleanupZeroMatchesVerified=true'), findsOneWidget);
      expect(find.text('credentialCleanupVerified=true'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
