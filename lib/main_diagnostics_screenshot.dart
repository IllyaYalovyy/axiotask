import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'src/core/clock.dart';
import 'src/core/diagnostics/diagnostics.dart';
import 'src/features/diagnostics/development_diagnostics_view.dart';
import 'src/features/diagnostics/diagnostics_view.dart';
import 'src/features/diagnostics/diagnostics_view_model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _DiagnosticsScreenshotSequence());
}

final class _DiagnosticsScreenshotSequence extends StatefulWidget {
  const _DiagnosticsScreenshotSequence();

  @override
  State<_DiagnosticsScreenshotSequence> createState() =>
      _DiagnosticsScreenshotSequenceState();
}

final class _DiagnosticsScreenshotSequenceState
    extends State<_DiagnosticsScreenshotSequence> {
  final GlobalKey _boundaryKey = GlobalKey();
  final InMemoryDiagnosticHistory _history = InMemoryDiagnosticHistory(
    maxRecords: 10,
  );
  var _development = false;
  late final DiagnosticsViewModel _viewModel = DiagnosticsViewModel(
    history: _history,
    clipboard: const _Clipboard(),
    exporter: const _Exporter(),
  );

  @override
  void initState() {
    super.initState();
    _populate();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture() async {
    try {
      final output = Directory('screenshots/actual');
      await output.create(recursive: true);
      for (final development in <bool>[false, true]) {
        if (_development != development) {
          _history.clear();
          setState(() => _development = development);
          _populate();
        }
        await _settleFrames();
        final boundary =
            _boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes == null) throw StateError('PNG encoding failed.');
        final name = development
            ? 'diagnostics-development-dark.png'
            : 'diagnostics-release-light.png';
        await File('${output.path}/$name').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
      }
      exit(0);
    } on Object catch (error) {
      stderr.writeln('Synthetic diagnostics screenshot capture failed: $error');
      exit(1);
    }
  }

  void _populate() {
    final clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
    final sink = _development
        ? SensitiveDevelopmentDiagnosticSink(_history, clock: clock)
        : ProductionDiagnosticSink(_history, clock: clock);
    sink.record(
      DiagnosticEvent(
        subsystem: DiagnosticSubsystem.sync,
        kind: DiagnosticEventKind.resolution,
        code: 'sync.automatic_resolution_summary',
        operation: 'reconcile',
        fields: <DiagnosticField>[
          const DiagnosticField.safe('google_won', 4),
          const DiagnosticField.safe('local_won', 2),
          if (_development)
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
          if (_development)
            const DiagnosticField.private(
              'decoded_payload',
              '{"title":"Synthetic private task","depth":3}',
            ),
          const DiagnosticField.safe(
            'mistagged_authorization',
            'Bearer '
                'synthetic-credential-canary-0123456789',
          ),
        ],
      ),
    );
  }

  Future<void> _settleFrames() async {
    await Future<void>.delayed(Duration.zero);
    for (var count = 0; count < 3; count += 1) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      key: ValueKey<bool>(_development),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _development ? Brightness.dark : Brightness.light,
        colorSchemeSeed: const Color(0xff315da8),
        useMaterial3: true,
      ),
      home: _development
          ? DevelopmentDiagnosticsView(viewModel: _viewModel)
          : ReleaseDiagnosticsView(viewModel: _viewModel),
    ),
  );

  @override
  void dispose() {
    _viewModel.dispose();
    _history.close();
    super.dispose();
  }
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
