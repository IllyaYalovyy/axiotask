import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/features/diagnostics/development_diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(_loadFlutterRoboto);

  for (final scenario in <({bool development, Brightness brightness})>[
    (development: false, brightness: Brightness.light),
    (development: true, brightness: Brightness.dark),
  ]) {
    final product = scenario.development ? 'development' : 'release';
    testWidgets('$product diagnostics desktop', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final history = InMemoryDiagnosticHistory(maxRecords: 10);
      final viewModel = DiagnosticsViewModel(
        history: history,
        clipboard: const _Clipboard(),
        exporter: const _Exporter(),
      );
      addTearDown(viewModel.dispose);
      addTearDown(history.close);
      _populate(history, development: scenario.development);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: scenario.brightness,
            colorSchemeSeed: const Color(0xff315da8),
            fontFamily: 'GoldenRoboto',
            useMaterial3: true,
          ),
          home: scenario.development
              ? DevelopmentDiagnosticsView(viewModel: viewModel)
              : ReleaseDiagnosticsView(viewModel: viewModel),
        ),
      );

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('../../goldens/linux/diagnostics_$product.png'),
      );
    });
  }
}

void _populate(InMemoryDiagnosticHistory history, {required bool development}) {
  final clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
  final sink = development
      ? SensitiveDevelopmentDiagnosticSink(history, clock: clock)
      : ProductionDiagnosticSink(history, clock: clock);
  sink.record(
    DiagnosticEvent(
      subsystem: DiagnosticSubsystem.sync,
      kind: DiagnosticEventKind.resolution,
      code: 'sync.automatic_resolution_summary',
      operation: 'reconcile',
      fields: <DiagnosticField>[
        const DiagnosticField.safe('google_won', 4),
        const DiagnosticField.safe('local_won', 2),
        if (development)
          const DiagnosticField.private(
            'task_title',
            'Synthetic quarterly review',
          ),
      ],
    ),
  );
  sink.record(
    DiagnosticEvent(
      subsystem: DiagnosticSubsystem.api,
      kind: DiagnosticEventKind.failure,
      code: 'api.unsupported_remote_shape',
      operation: 'decode_task_page',
      fields: <DiagnosticField>[
        const DiagnosticField.safe('status_class', 'success_invalid'),
        if (development)
          const DiagnosticField.private(
            'decoded_payload',
            '{"title":"Synthetic private task","depth":3}',
          ),
      ],
    ),
  );
  sink.record(
    const DiagnosticEvent(
      subsystem: DiagnosticSubsystem.storage,
      kind: DiagnosticEventKind.transition,
      code: 'storage.transaction_rolled_back',
      operation: 'persist_remote_page',
      fields: <DiagnosticField>[DiagnosticField.safe('affected_rows', 8)],
    ),
  );
}

final class _Clipboard implements DiagnosticClipboardPort {
  const _Clipboard();

  @override
  Future<void> writeText(String value) async {}
}

final class _Exporter implements DiagnosticExportPort {
  const _Exporter();

  @override
  Future<DiagnosticExportReceipt> export(
    List<DiagnosticRecord> records,
  ) async => const DiagnosticExportReceipt(fileName: 'synthetic.json');
}

Future<void> _loadFlutterRoboto() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document = jsonDecode(await packageConfig.readAsString());
  final packages =
      (document as Map<String, Object?>)['packages']! as List<Object?>;
  final flutter = packages.cast<Map<String, Object?>>().singleWhere(
    (value) => value['name'] == 'flutter',
  );
  final configUri = packageConfig.absolute.uri;
  final flutterPackage = Directory.fromUri(
    configUri.resolve(flutter['rootUri']! as String),
  );
  final flutterRoot = flutterPackage.parent.parent;
  final fontFile = File(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError('The locked Flutter SDK Roboto font is unavailable.');
  }
  final bytes = await fontFile.readAsBytes();
  await (FontLoader('GoldenRoboto')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}
