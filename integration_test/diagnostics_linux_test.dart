import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/diagnostics/local_diagnostic_exporter.dart';
import 'package:axiotask/src/features/diagnostics/development_diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view_model.dart';
import 'package:axiotask/src/features/tasks/widgets/sync_health_header.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sensitive diagnostics are reachable and explicitly exportable', (
    tester,
  ) async {
    const taskCanary = 'SYNTHETIC_NATIVE_DIAGNOSTIC_TASK_9a71';
    const credentialCanary =
        'Bearer '
        'native-credential-canary-0123456789';
    final directory = Directory.systemTemp.createTempSync(
      'axiotask-native-diagnostic-export-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final history = InMemoryDiagnosticHistory(maxRecords: 10);
    final clipboard = _Clipboard();
    final model = DiagnosticsViewModel(
      history: history,
      clipboard: clipboard,
      exporter: LocalDiagnosticExporter(
        directory,
        product: DiagnosticProduct.sensitiveDevelopment,
        clock: ManualClock(DateTime.utc(2026, 8, 16, 12)),
      ),
    );
    addTearDown(model.dispose);
    addTearDown(history.close);
    SensitiveDevelopmentDiagnosticSink(history).record(
      const DiagnosticEvent(
        subsystem: DiagnosticSubsystem.api,
        kind: DiagnosticEventKind.failure,
        code: 'api.native_synthetic_failure',
        operation: 'decode',
        fields: <DiagnosticField>[
          DiagnosticField.private('task_title', taskCanary),
          DiagnosticField.safe('mistagged', credentialCanary),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncHealthHeader(
            health: _failedHealth(),
            diagnosticsBuilder: (_) =>
                DevelopmentDiagnosticsView(viewModel: model),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Sync details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private test-account data'), findsOneWidget);
    expect(find.textContaining(taskCanary), findsOneWidget);
    expect(find.textContaining('native-credential-canary'), findsNothing);

    await tester.tap(find.byTooltip('Copy visible diagnostics'));
    await tester.pump();
    expect(clipboard.value, contains(taskCanary));
    expect(clipboard.value, isNot(contains('native-credential-canary')));

    await tester.tap(find.byTooltip('Export visible diagnostics'));
    await tester.pumpAndSettle();
    final exported = directory
        .listSync()
        .whereType<File>()
        .single
        .readAsStringSync();
    expect(exported, contains(taskCanary));
    expect(exported, isNot(contains('native-credential-canary')));

    await tester.tap(find.byTooltip('Clear diagnostics'));
    await tester.pump();
    expect(find.text('No diagnostics recorded'), findsOneWidget);
  });
}

SyncHealth _failedHealth() => SyncHealth(
  outcome: SyncHealthOutcome.failed,
  failureReason: SyncFailureReason.applicationFailure,
  counts: const SyncWorkCounts(failed: 1),
  lastSuccessfulSyncAt: null,
  evaluatedAt: DateTime.utc(2026, 8, 16, 12),
);

final class _Clipboard implements DiagnosticClipboardPort {
  String? value;

  @override
  Future<void> writeText(String value) async => this.value = value;
}
