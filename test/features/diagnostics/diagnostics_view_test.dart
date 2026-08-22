import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/features/diagnostics/development_diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view_model.dart';
import 'package:axiotask/src/features/tasks/widgets/sync_health_header.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('HLT-010 release view exposes safe empty and populated states', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ReleaseDiagnosticsView(viewModel: fixture.viewModel)),
    );

    expect(find.text('No diagnostics recorded'), findsOneWidget);
    fixture.add(code: 'sync.safe_summary', detail: 'google_won=4');
    await tester.pump();

    expect(find.text('sync.safe_summary'), findsOneWidget);
    expect(find.textContaining('google_won=4'), findsOneWidget);
    expect(find.textContaining('private test-account data'), findsNothing);
  });

  testWidgets('development view keeps its sensitive warning while searching', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.add(code: 'api.decoded', detail: 'Synthetic private task title');
    await tester.pumpWidget(
      MaterialApp(
        home: DevelopmentDiagnosticsView(viewModel: fixture.viewModel),
      ),
    );

    expect(find.textContaining('private test-account data'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('diagnostics-search')),
      'no match',
    );
    await tester.pump();

    expect(find.text('No diagnostics match this search'), findsOneWidget);
    expect(find.textContaining('private test-account data'), findsOneWidget);
  });

  testWidgets('development diagnostics are reachable from sync details', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncHealthHeader(
            health: _failedHealth(),
            diagnosticsBuilder: (_) =>
                DevelopmentDiagnosticsView(viewModel: fixture.viewModel),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Sync details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open diagnostics'));
    await tester.pumpAndSettle();

    expect(find.byType(DevelopmentDiagnosticsView), findsOneWidget);
    expect(find.text('Sensitive development diagnostics'), findsOneWidget);
  });
}

SyncHealth _failedHealth() => SyncHealth(
  outcome: SyncHealthOutcome.failed,
  failureReason: SyncFailureReason.applicationFailure,
  counts: const SyncWorkCounts(failed: 1),
  lastSuccessfulSyncAt: null,
  evaluatedAt: DateTime.utc(2026, 8, 16, 12),
);

final class _Fixture {
  _Fixture()
    : history = InMemoryDiagnosticHistory(maxRecords: 10),
      clipboard = _Clipboard(),
      exporter = _Exporter() {
    viewModel = DiagnosticsViewModel(
      history: history,
      clipboard: clipboard,
      exporter: exporter,
    );
  }

  final InMemoryDiagnosticHistory history;
  final _Clipboard clipboard;
  final _Exporter exporter;
  late final DiagnosticsViewModel viewModel;

  void add({required String code, required String detail}) {
    history.append(
      DiagnosticRecord(
        sequence: 0,
        recordedAt: DateTime.utc(2026, 8, 16, 12),
        subsystem: DiagnosticSubsystem.sync,
        kind: DiagnosticEventKind.failure,
        code: code,
        operation: 'inspect',
        fields: <String, String>{'detail': detail},
      ),
    );
  }

  void dispose() => viewModel.dispose();
}

final class _Clipboard implements DiagnosticClipboardPort {
  @override
  Future<void> writeText(String value) async {}
}

final class _Exporter implements DiagnosticExportPort {
  @override
  Future<DiagnosticExportReceipt> export(
    List<DiagnosticRecord> records,
  ) async => const DiagnosticExportReceipt(fileName: 'diagnostics.json');
}
