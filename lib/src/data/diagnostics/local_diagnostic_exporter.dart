import 'dart:convert';
import 'dart:io';

import '../../core/clock.dart';
import '../../core/diagnostics/diagnostics.dart';

final class LocalDiagnosticExporter implements DiagnosticExportPort {
  LocalDiagnosticExporter(
    this._directory, {
    required this.product,
    Clock? clock,
  }) : _clock = clock ?? SystemClock();

  final Directory _directory;
  final DiagnosticProduct product;
  final Clock _clock;

  @override
  Future<DiagnosticExportReceipt> export(List<DiagnosticRecord> records) async {
    await _directory.create(recursive: true);
    final exportedAt = _clock.now().toUtc();
    final timestamp = _fileTimestamp(exportedAt);
    final suffix = records.isEmpty ? 0 : records.last.sequence;
    final fileName =
        'axiotask-diagnostics-${product.name}-$timestamp-$suffix.json';
    final file = File('${_directory.path}${Platform.pathSeparator}$fileName');
    final temporary = File('${file.path}.next');
    final document = <String, Object>{
      'schemaVersion': diagnosticPersistenceSchemaVersion,
      'product': product.name,
      'exportedAt': exportedAt.toIso8601String(),
      'records': records.map(_safeJson).toList(growable: false),
    };
    await temporary.writeAsString(jsonEncode(document), flush: true);
    await temporary.rename(file.path);
    return DiagnosticExportReceipt(fileName: fileName);
  }
}

Map<String, Object> _safeJson(DiagnosticRecord record) {
  const redactor = CredentialRedactor();
  return <String, Object>{
    'sequence': record.sequence,
    'recordedAt': record.recordedAt.toUtc().toIso8601String(),
    'subsystem': record.subsystem.name,
    'kind': record.kind.name,
    'code': redactor.redact(record.code),
    'operation': redactor.redact(record.operation),
    'fields': <String, String>{
      for (final entry in record.fields.entries)
        redactor.redact(entry.key): redactor.redact(entry.value),
    },
  };
}

String _fileTimestamp(DateTime value) =>
    value.toIso8601String().replaceAll(RegExp(r'[-:]'), '').replaceAll('.', '');
