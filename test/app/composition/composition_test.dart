import 'dart:io';

import 'package:axiotask/src/app/composition/development_composition.dart';
import 'package:axiotask/src/app/composition/linux_read_transport.dart';
import 'package:axiotask/src/app/composition/release_composition.dart';
import 'package:axiotask/src/app/composition/test_composition.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/auth/linux/linux_authorization.dart';
import 'package:axiotask/src/data/google_tasks/http_service.dart';
import 'package:axiotask/src/features/diagnostics/development_diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view.dart';
import 'package:flutter/material.dart';
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
          subsystem: DiagnosticSubsystem.application,
          kind: DiagnosticEventKind.failure,
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

  testWidgets(
    'release diagnostic construction exposes no development renderer or warning',
    (tester) async {
      final composition = ReleaseComposition.create(
        diagnosticExporter: const _DiagnosticExporter(),
      );
      addTearDown(composition.diagnosticHistory.close);

      await tester.pumpWidget(
        MaterialApp(
          home: ReleaseDiagnosticsHost(
            history: composition.diagnosticHistory,
            exporter: composition.diagnosticExporter,
          ),
        ),
      );

      expect(find.byType(ReleaseDiagnosticsView), findsOneWidget);
      expect(find.byType(DevelopmentDiagnosticsView), findsNothing);
      expect(find.textContaining('private test-account data'), findsNothing);
      expect(
        find.textContaining('Production-safe local history'),
        findsOneWidget,
      );
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
          subsystem: DiagnosticSubsystem.application,
          kind: DiagnosticEventKind.failure,
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

  test(
    'release and development compositions reopen separate histories',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'axiotask-composition-diagnostics-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final releaseFile = File('${directory.path}/release.json');
      final developmentFile = File('${directory.path}/development.json');

      var release = await ReleaseComposition.open(diagnosticFile: releaseFile);
      var development = await DevelopmentComposition.open(
        diagnosticFile: developmentFile,
        expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
      );
      release.diagnostics.record(
        const DiagnosticEvent(
          subsystem: DiagnosticSubsystem.ui,
          kind: DiagnosticEventKind.transition,
          code: 'ui.release_transition',
          operation: 'navigate',
          fields: <DiagnosticField>[
            DiagnosticField.private('task', taskCanary),
          ],
        ),
      );
      development.diagnostics.record(
        const DiagnosticEvent(
          subsystem: DiagnosticSubsystem.ui,
          kind: DiagnosticEventKind.transition,
          code: 'ui.development_transition',
          operation: 'navigate',
          fields: <DiagnosticField>[
            DiagnosticField.private('task', taskCanary),
          ],
        ),
      );
      release.diagnosticHistory.close();
      development.diagnosticHistory.close();

      release = await ReleaseComposition.open(diagnosticFile: releaseFile);
      development = await DevelopmentComposition.open(
        diagnosticFile: developmentFile,
        expectedDedicatedSubject: const AccountSubject('dedicated-subject'),
      );
      addTearDown(release.diagnosticHistory.close);
      addTearDown(development.diagnosticHistory.close);

      expect(
        release.diagnosticHistory.records.single.code,
        'ui.release_transition',
      );
      expect(
        release.diagnosticHistory.records.single.renderedText,
        isNot(contains(taskCanary)),
      );
      expect(
        development.diagnosticHistory.records.single.renderedText,
        contains(taskCanary),
      );
      expect(releaseFile.path, isNot(developmentFile.path));
    },
  );

  test(
    'production read transport wires Linux auth and strict Tasks HTTP ports',
    () async {
      final composition = ReleaseComposition.create(
        linuxReadConfiguration: const LinuxReadConfiguration(
          clientId: 'synthetic.apps.googleusercontent.com',
          clientSecret: 'synthetic-installed-client-value',
        ),
      );

      final transport = await composition.createReadTransport(
        const AccountSubject('configured-synthetic-subject'),
      );
      addTearDown(transport.close);

      expect(transport.authorization, isA<LinuxAuthorization>());
      expect(transport.googleTasks, isA<HttpGoogleTasksService>());
      expect(transport.authorization.currentState, isA<NoTasksAuthorization>());
    },
  );

  test(
    'missing production OAuth configuration fails closed without Google access',
    () async {
      final composition = ReleaseComposition.create();
      final transport = await composition.createReadTransport(
        const AccountSubject('configured-synthetic-subject'),
      );
      addTearDown(transport.close);

      expect(transport.authorization, isA<UnavailableAuthorization>());
      final restore = await transport.authorization.restoreTasksAuthorization();
      expect(restore, isA<Failed<AccountSubject>>());
    },
  );
}

final class _DiagnosticExporter implements DiagnosticExportPort {
  const _DiagnosticExporter();

  @override
  Future<DiagnosticExportReceipt> export(
    List<DiagnosticRecord> records,
  ) async => const DiagnosticExportReceipt(fileName: 'synthetic.json');
}
