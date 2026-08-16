import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/diagnostics/diagnostics.dart';

final class DiagnosticsViewState {
  const DiagnosticsViewState({
    required this.records,
    required this.query,
    this.notice,
    this.error,
    this.loadError,
    this.isWorking = false,
  });

  final List<DiagnosticRecord> records;
  final String query;
  final String? notice;
  final String? error;
  final String? loadError;
  final bool isWorking;

  List<DiagnosticRecord> get visibleRecords {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return records;
    return records
        .where(
          (record) => record.renderedText.toLowerCase().contains(normalized),
        )
        .toList(growable: false);
  }

  bool get isEmpty => records.isEmpty;

  DiagnosticsViewState copyWith({
    List<DiagnosticRecord>? records,
    String? query,
    String? notice,
    bool clearNotice = false,
    String? error,
    bool clearError = false,
    String? loadError,
    bool? isWorking,
  }) => DiagnosticsViewState(
    records: records ?? this.records,
    query: query ?? this.query,
    notice: clearNotice ? null : notice ?? this.notice,
    error: clearError ? null : error ?? this.error,
    loadError: loadError ?? this.loadError,
    isWorking: isWorking ?? this.isWorking,
  );
}

final class DiagnosticsViewModel extends ChangeNotifier {
  DiagnosticsViewModel({
    required DiagnosticHistory history,
    required this.clipboard,
    required this.exporter,
  }) : _history = history,
       _state = DiagnosticsViewState(records: history.records, query: '') {
    _subscription = history.watchRecords().listen(
      _recordsChanged,
      onError: _recordsFailed,
    );
  }

  final DiagnosticHistory _history;
  final DiagnosticClipboardPort clipboard;
  final DiagnosticExportPort exporter;
  late final StreamSubscription<List<DiagnosticRecord>> _subscription;
  DiagnosticsViewState _state;

  DiagnosticsViewState get state => _state;

  void setQuery(String value) {
    _state = _state.copyWith(query: value, clearNotice: true, clearError: true);
    notifyListeners();
  }

  Future<void> copyVisible() async {
    final records = _state.visibleRecords;
    if (records.isEmpty) {
      _setNotice('There are no diagnostics to copy.');
      return;
    }
    await _perform(
      () => clipboard.writeText(_render(records)),
      success:
          'Copied ${records.length} diagnostic '
          '${records.length == 1 ? 'record' : 'records'}.',
      failure: 'Could not copy diagnostics.',
    );
  }

  Future<void> exportVisible() async {
    final records = _state.visibleRecords;
    if (records.isEmpty) {
      _setNotice('There are no diagnostics to export.');
      return;
    }
    _setWorking();
    try {
      final receipt = await exporter.export(records);
      _state = _state.copyWith(
        notice: 'Exported ${receipt.fileName}',
        clearError: true,
        isWorking: false,
      );
    } on Object {
      _state = _state.copyWith(
        error: 'Could not export diagnostics.',
        clearNotice: true,
        isWorking: false,
      );
    }
    notifyListeners();
  }

  Future<void> clear() async {
    _setWorking();
    try {
      _history.clear();
      _state = _state.copyWith(
        notice: 'Diagnostics cleared.',
        clearError: true,
        isWorking: false,
      );
    } on Object {
      _state = _state.copyWith(
        error: 'Could not clear diagnostics.',
        clearNotice: true,
        isWorking: false,
      );
    }
    notifyListeners();
  }

  Future<void> _perform(
    Future<void> Function() operation, {
    required String success,
    required String failure,
  }) async {
    _setWorking();
    try {
      await operation();
      _state = _state.copyWith(
        notice: success,
        clearError: true,
        isWorking: false,
      );
    } on Object {
      _state = _state.copyWith(
        error: failure,
        clearNotice: true,
        isWorking: false,
      );
    }
    notifyListeners();
  }

  void _setWorking() {
    _state = _state.copyWith(
      clearNotice: true,
      clearError: true,
      isWorking: true,
    );
    notifyListeners();
  }

  void _setNotice(String value) {
    _state = _state.copyWith(notice: value, clearError: true, isWorking: false);
    notifyListeners();
  }

  void _recordsChanged(List<DiagnosticRecord> records) {
    _state = _state.copyWith(records: records, loadError: null);
    notifyListeners();
  }

  void _recordsFailed(Object _) {
    _state = _state.copyWith(loadError: 'Diagnostics are unavailable.');
    notifyListeners();
  }

  static String _render(List<DiagnosticRecord> records) =>
      records.map((record) => record.renderedText).join('\n');

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
