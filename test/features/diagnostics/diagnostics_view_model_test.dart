import 'dart:async';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/features/diagnostics/diagnostics_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryDiagnosticHistory history;
  late _Clipboard clipboard;
  late _Exporter exporter;
  late DiagnosticsViewModel viewModel;

  setUp(() {
    history = InMemoryDiagnosticHistory(maxRecords: 10);
    clipboard = _Clipboard();
    exporter = _Exporter();
    viewModel = DiagnosticsViewModel(
      history: history,
      clipboard: clipboard,
      exporter: exporter,
    );
  });

  tearDown(() => viewModel.dispose());

  test(
    'HLT-010 live search, copy, export, and clear use visible records',
    () async {
      history.append(_record(1, code: 'sync.first', detail: 'Google won 3'));
      history.append(
        _record(2, code: 'storage.second', detail: 'database row'),
      );

      viewModel.setQuery('GOOGLE');
      expect(
        viewModel.state.visibleRecords.map((record) => record.code),
        <String>['sync.first'],
      );

      await viewModel.copyVisible();
      expect(clipboard.value, contains('sync.first'));
      expect(clipboard.value, isNot(contains('storage.second')));

      await viewModel.exportVisible();
      expect(exporter.records.map((record) => record.code), <String>[
        'sync.first',
      ]);
      expect(viewModel.state.notice, 'Exported diagnostics.json');

      await viewModel.clear();
      expect(history.records, isEmpty);
      expect(viewModel.state.visibleRecords, isEmpty);
    },
  );

  test('empty and operation errors are explicit', () async {
    expect(viewModel.state.isEmpty, isTrue);
    await viewModel.copyVisible();
    expect(viewModel.state.notice, 'There are no diagnostics to copy.');

    clipboard.error = StateError('synthetic clipboard failure');
    history.append(_record(1, code: 'ui.failure', detail: 'safe'));
    await viewModel.copyVisible();
    expect(viewModel.state.error, 'Could not copy diagnostics.');

    exporter.error = StateError('synthetic export failure');
    await viewModel.exportVisible();
    expect(viewModel.state.error, 'Could not export diagnostics.');
  });

  test(
    'history stream failure does not substitute an empty healthy state',
    () async {
      final failing = _FailingHistory();
      final model = DiagnosticsViewModel(
        history: failing,
        clipboard: clipboard,
        exporter: exporter,
      );
      addTearDown(model.dispose);

      failing.fail();
      await Future<void>.delayed(Duration.zero);

      expect(model.state.loadError, 'Diagnostics are unavailable.');
    },
  );
}

DiagnosticRecord _record(
  int sequence, {
  required String code,
  required String detail,
}) => DiagnosticRecord(
  sequence: sequence,
  recordedAt: DateTime.utc(2026, 8, 16, 12, sequence),
  subsystem: DiagnosticSubsystem.sync,
  kind: DiagnosticEventKind.resolution,
  code: code,
  operation: 'inspect',
  fields: <String, String>{'detail': detail},
);

final class _Clipboard implements DiagnosticClipboardPort {
  String? value;
  Object? error;

  @override
  Future<void> writeText(String value) async {
    if (error case final failure?) throw failure;
    this.value = value;
  }
}

final class _Exporter implements DiagnosticExportPort {
  List<DiagnosticRecord> records = <DiagnosticRecord>[];
  Object? error;

  @override
  Future<DiagnosticExportReceipt> export(List<DiagnosticRecord> records) async {
    if (error case final failure?) throw failure;
    this.records = records;
    return const DiagnosticExportReceipt(fileName: 'diagnostics.json');
  }
}

final class _FailingHistory implements DiagnosticHistory {
  final StreamController<List<DiagnosticRecord>> _controller =
      StreamController<List<DiagnosticRecord>>.broadcast();

  void fail() => _controller.addError(StateError('synthetic history failure'));

  @override
  List<DiagnosticRecord> get records => const <DiagnosticRecord>[];

  @override
  Stream<List<DiagnosticRecord>> watchRecords() => _controller.stream;

  @override
  void append(DiagnosticRecord record) {}

  @override
  void clear() {}

  @override
  void close() => _controller.close();
}
