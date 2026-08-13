import 'package:axiotask/src/app/composition/development_composition.dart';
import 'package:axiotask/src/app/composition/release_composition.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskCanary = 'PRIVATE_TASK_CANARY_RELEASE_84a1';
  const credentialCanary =
      'Bearer '
      'credential-canary-release-0123456789';

  test(
    'release composition has a fixed production-safe diagnostic product',
    () {
      final composition = ReleaseComposition.create();

      expect(composition.diagnostics, isA<ProductionDiagnosticSink>());
      expect(
        composition.diagnostics,
        isNot(isA<SensitiveDevelopmentDiagnosticSink>()),
      );

      composition.diagnostics.record(
        const DiagnosticEvent(
          code: 'release.canary',
          operation: 'verify',
          fields: <DiagnosticField>[
            DiagnosticField.private('task', taskCanary),
            DiagnosticField.safe('authorization', credentialCanary),
          ],
        ),
      );

      final output = composition.diagnosticHistory.records.single.renderedText;
      expect(output, isNot(contains(taskCanary)));
      expect(output, isNot(contains('credential-canary')));
    },
  );

  test(
    'only the development entry-point composition has sensitive diagnostics',
    () {
      final development = DevelopmentComposition.create(
        expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
      );
      final synthetic = TestComposition.create(instanceId: 'composition-test');

      expect(
        development.diagnostics,
        isA<SensitiveDevelopmentDiagnosticSink>(),
      );
      expect(synthetic.diagnostics, isA<ProductionDiagnosticSink>());

      development.diagnostics.record(
        const DiagnosticEvent(
          code: 'development.canary',
          operation: 'verify',
          fields: <DiagnosticField>[
            DiagnosticField.private('task', taskCanary),
            DiagnosticField.safe('authorization', credentialCanary),
            DiagnosticField.credential('refresh', 'credential-canary-refresh'),
          ],
        ),
      );
      final output = development.diagnosticHistory.records.single.renderedText;
      expect(output, contains(taskCanary));
      expect(output, isNot(contains('credential-canary')));
    },
  );
}
