import 'dart:convert';
import 'dart:io';

import '../clock.dart';

const int diagnosticPersistenceSchemaVersion = 1;
const int defaultReleaseDiagnosticRecordLimit = 500;
const int defaultDevelopmentDiagnosticRecordLimit = 1000;
const int maxDiagnosticFields = 32;
const int maxDiagnosticValueCharacters = 4096;
const String diagnosticTruncationMarker = '[TRUNCATED]';
const int maxPersistedDiagnosticValueCharacters =
    maxDiagnosticValueCharacters + diagnosticTruncationMarker.length;

enum DiagnosticProduct { releaseSafe, sensitiveDevelopment }

enum DiagnosticSubsystem {
  sync,
  api,
  storage,
  ui,
  authorization,
  repository,
  application,
}

enum DiagnosticEventKind { failure, transition, resolution }

enum DiagnosticFieldPrivacy { safe, privateContent, credential }

final class DiagnosticField {
  const DiagnosticField._(this.name, this.value, this.privacy);

  const DiagnosticField.safe(String name, Object? value)
    : this._(name, value, DiagnosticFieldPrivacy.safe);

  const DiagnosticField.private(String name, Object? value)
    : this._(name, value, DiagnosticFieldPrivacy.privateContent);

  const DiagnosticField.credential(String name, Object? value)
    : this._(name, value, DiagnosticFieldPrivacy.credential);

  final String name;
  final Object? value;
  final DiagnosticFieldPrivacy privacy;
}

final class DiagnosticEvent {
  const DiagnosticEvent({
    required this.subsystem,
    required this.kind,
    required this.code,
    required this.operation,
    this.fields = const <DiagnosticField>[],
  });

  final DiagnosticSubsystem subsystem;
  final DiagnosticEventKind kind;
  final String code;
  final String operation;
  final List<DiagnosticField> fields;
}

abstract interface class DiagnosticSink {
  void record(DiagnosticEvent event);
}

final class DiagnosticRecord {
  DiagnosticRecord({
    required this.sequence,
    required this.recordedAt,
    required this.subsystem,
    required this.kind,
    required this.code,
    required this.operation,
    required Map<String, String> fields,
  }) : fields = Map<String, String>.unmodifiable(fields);

  final int sequence;
  final DateTime recordedAt;
  final DiagnosticSubsystem subsystem;
  final DiagnosticEventKind kind;
  final String code;
  final String operation;
  final Map<String, String> fields;

  String get renderedText {
    final renderedFields = fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    return '${recordedAt.toIso8601String()} ${subsystem.name} ${kind.name} '
            '$code operation=$operation $renderedFields'
        .trimRight();
  }

  DiagnosticRecord withSequence(int value) => DiagnosticRecord(
    sequence: value,
    recordedAt: recordedAt,
    subsystem: subsystem,
    kind: kind,
    code: code,
    operation: operation,
    fields: fields,
  );

  Map<String, Object> toJson() => <String, Object>{
    'sequence': sequence,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'subsystem': subsystem.name,
    'kind': kind.name,
    'code': code,
    'operation': operation,
    'fields': fields,
  };

  static DiagnosticRecord fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const DiagnosticPersistenceException('record_not_an_object');
    }
    final sequence = value['sequence'];
    final recordedAtValue = value['recordedAt'];
    final subsystemValue = value['subsystem'];
    final kindValue = value['kind'];
    final code = value['code'];
    final operation = value['operation'];
    final rawFields = value['fields'];
    if (sequence is! int ||
        sequence <= 0 ||
        recordedAtValue is! String ||
        subsystemValue is! String ||
        kindValue is! String ||
        code is! String ||
        operation is! String ||
        rawFields is! Map<String, Object?>) {
      throw const DiagnosticPersistenceException('record_shape_invalid');
    }
    if (code.length > maxPersistedDiagnosticValueCharacters ||
        operation.length > maxPersistedDiagnosticValueCharacters ||
        rawFields.length > maxDiagnosticFields) {
      throw const DiagnosticPersistenceException('record_bound_invalid');
    }
    final recordedAt = DateTime.tryParse(recordedAtValue)?.toUtc();
    final subsystem = _enumByName(DiagnosticSubsystem.values, subsystemValue);
    final kind = _enumByName(DiagnosticEventKind.values, kindValue);
    if (recordedAt == null || subsystem == null || kind == null) {
      throw const DiagnosticPersistenceException('record_value_invalid');
    }
    final fields = <String, String>{};
    for (final entry in rawFields.entries) {
      if (entry.value is! String ||
          entry.key.length > maxPersistedDiagnosticValueCharacters ||
          (entry.value! as String).length >
              maxPersistedDiagnosticValueCharacters) {
        throw const DiagnosticPersistenceException('field_value_invalid');
      }
      fields[entry.key] = entry.value! as String;
    }
    return DiagnosticRecord(
      sequence: sequence,
      recordedAt: recordedAt,
      subsystem: subsystem,
      kind: kind,
      code: code,
      operation: operation,
      fields: fields,
    );
  }
}

abstract interface class DiagnosticHistory {
  List<DiagnosticRecord> get records;

  void append(DiagnosticRecord record);

  void clear();

  void close();
}

final class InMemoryDiagnosticHistory implements DiagnosticHistory {
  InMemoryDiagnosticHistory({
    this.maxRecords = defaultReleaseDiagnosticRecordLimit,
  }) {
    if (maxRecords <= 0) {
      throw ArgumentError.value(maxRecords, 'maxRecords', 'must be positive');
    }
  }

  final int maxRecords;
  final List<DiagnosticRecord> _records = <DiagnosticRecord>[];
  var _nextSequence = 1;

  @override
  List<DiagnosticRecord> get records =>
      List<DiagnosticRecord>.unmodifiable(_records);

  @override
  void append(DiagnosticRecord record) {
    _records.add(record.withSequence(_nextSequence));
    _nextSequence += 1;
    _trimToBound(_records, maxRecords);
  }

  @override
  void clear() {
    _records.clear();
  }

  @override
  void close() {}
}

final class PersistentDiagnosticHistory implements DiagnosticHistory {
  PersistentDiagnosticHistory._({
    required this._file,
    required this.product,
    required this.maxRecords,
    required List<DiagnosticRecord> records,
  }) : _records = records,
       _nextSequence = records.isEmpty ? 1 : records.last.sequence + 1;

  factory PersistentDiagnosticHistory.open(
    File file, {
    DiagnosticProduct product = DiagnosticProduct.releaseSafe,
    required int maxRecords,
  }) {
    if (maxRecords <= 0) {
      throw ArgumentError.value(maxRecords, 'maxRecords', 'must be positive');
    }
    final parent = file.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final temporary = File('${file.path}.next');
    if (temporary.existsSync()) temporary.deleteSync();
    final records = file.existsSync()
        ? _decodeDocument(file.readAsStringSync(), expectedProduct: product)
        : <DiagnosticRecord>[];
    for (var index = 0; index < records.length; index += 1) {
      records[index] = _scrubPersistedRecord(records[index]);
    }
    _trimToBound(records, maxRecords);
    final history = PersistentDiagnosticHistory._(
      file: file,
      product: product,
      maxRecords: maxRecords,
      records: records,
    );
    if (!file.existsSync() || records.isNotEmpty) {
      history._persist();
    }
    return history;
  }

  final File _file;
  final DiagnosticProduct product;
  final int maxRecords;
  final List<DiagnosticRecord> _records;
  int _nextSequence;
  var _closed = false;

  @override
  List<DiagnosticRecord> get records =>
      List<DiagnosticRecord>.unmodifiable(_records);

  @override
  void append(DiagnosticRecord record) {
    _requireOpen();
    _records.add(record.withSequence(_nextSequence));
    _nextSequence += 1;
    _trimToBound(_records, maxRecords);
    _persist();
  }

  @override
  void clear() {
    _requireOpen();
    _records.clear();
    _persist();
  }

  @override
  void close() {
    _closed = true;
  }

  void _persist() {
    final document = jsonEncode(<String, Object>{
      'schemaVersion': diagnosticPersistenceSchemaVersion,
      'product': product.name,
      'records': _records.map((record) => record.toJson()).toList(),
    });
    final temporary = File('${_file.path}.next');
    temporary.writeAsStringSync(document, flush: true);
    temporary.renameSync(_file.path);
  }

  void _requireOpen() {
    if (_closed) throw StateError('Diagnostic history is closed.');
  }

  static List<DiagnosticRecord> _decodeDocument(
    String source, {
    required DiagnosticProduct expectedProduct,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const DiagnosticPersistenceException('document_malformed');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['schemaVersion'] != diagnosticPersistenceSchemaVersion ||
        decoded['product'] != expectedProduct.name ||
        decoded['records'] is! List<Object?>) {
      throw const DiagnosticPersistenceException('schema_mismatch');
    }
    final records = (decoded['records']! as List<Object?>)
        .map(DiagnosticRecord.fromJson)
        .toList(growable: true);
    for (var index = 1; index < records.length; index += 1) {
      if (records[index].sequence <= records[index - 1].sequence) {
        throw const DiagnosticPersistenceException('sequence_invalid');
      }
    }
    return records;
  }
}

final class DiagnosticPersistenceException implements Exception {
  const DiagnosticPersistenceException(this.code);

  final String code;

  @override
  String toString() => 'DiagnosticPersistenceException($code)';
}

final class CredentialRedactor {
  const CredentialRedactor();

  static final List<RegExp>
  _credentialPatterns = List<RegExp>.unmodifiable(<RegExp>[
    RegExp(
      r'https?://[^\s]*[?&](?:code|access_token|refresh_token|id_token)=[^\s]*',
      caseSensitive: false,
    ),
    RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
    RegExp(
      r'(authorization\s*[:=]\s*)(?:Basic|Bearer)?\s*[^\s,;]+',
      caseSensitive: false,
    ),
    RegExp(
      r'(access_token|refresh_token|id_token|client_secret|code_verifier|authorization_code|dpop_private_key|secure_store_value)\s*[:=]\s*[^&\s,;]+',
      caseSensitive: false,
    ),
    RegExp(
      r'([?&](?:code|access_token|refresh_token|id_token)=)[^&\s]+',
      caseSensitive: false,
    ),
    RegExp(r'AIza[0-9A-Za-z_-]{20,}'),
    RegExp(r'ya29\.[0-9A-Za-z._~-]{10,}'),
    RegExp(r'GOCSPX-[0-9A-Za-z_-]{10,}'),
    RegExp(r'eyJ[0-9A-Za-z_-]+\.[0-9A-Za-z._-]+\.[0-9A-Za-z._-]+'),
    RegExp(
      r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    ),
  ]);

  String redact(Object? value) {
    var output = value?.toString() ?? 'null';
    for (final pattern in _credentialPatterns) {
      output = output.replaceAll(pattern, '[REDACTED]');
    }
    return output;
  }
}

final class ProductionDiagnosticSink implements DiagnosticSink {
  ProductionDiagnosticSink(
    this._history, {
    this._redactor = const CredentialRedactor(),
    Clock? clock,
  }) : _clock = clock ?? SystemClock();

  final DiagnosticHistory _history;
  final CredentialRedactor _redactor;
  final Clock _clock;

  @override
  void record(DiagnosticEvent event) {
    _history.append(_buildRecord(event, includePrivate: false));
  }

  DiagnosticRecord _buildRecord(
    DiagnosticEvent event, {
    required bool includePrivate,
  }) {
    final fields = <String, String>{};
    for (final field in event.fields.take(maxDiagnosticFields)) {
      if (field.privacy == DiagnosticFieldPrivacy.credential ||
          (!includePrivate &&
              field.privacy == DiagnosticFieldPrivacy.privateContent)) {
        continue;
      }
      fields[_bounded(_redactor.redact(field.name))] = _bounded(
        _redactor.redact(field.value),
      );
    }
    return DiagnosticRecord(
      sequence: 0,
      recordedAt: _clock.now().toUtc(),
      subsystem: event.subsystem,
      kind: event.kind,
      code: _bounded(_redactor.redact(event.code)),
      operation: _bounded(_redactor.redact(event.operation)),
      fields: fields,
    );
  }
}

final class SensitiveDevelopmentDiagnosticSink implements DiagnosticSink {
  SensitiveDevelopmentDiagnosticSink(
    this._history, {
    CredentialRedactor redactor = const CredentialRedactor(),
    Clock? clock,
  }) : _delegate = ProductionDiagnosticSink(
         _history,
         redactor: redactor,
         clock: clock,
       );

  final DiagnosticHistory _history;
  final ProductionDiagnosticSink _delegate;

  @override
  void record(DiagnosticEvent event) {
    _history.append(_delegate._buildRecord(event, includePrivate: true));
  }
}

T? _enumByName<T extends Enum>(Iterable<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

void _trimToBound(List<DiagnosticRecord> records, int maxRecords) {
  final overflow = records.length - maxRecords;
  if (overflow > 0) records.removeRange(0, overflow);
}

String _bounded(String value) {
  if (value.length <= maxDiagnosticValueCharacters) return value;
  return '${value.substring(0, maxDiagnosticValueCharacters)}'
      '$diagnosticTruncationMarker';
}

DiagnosticRecord _scrubPersistedRecord(DiagnosticRecord record) {
  const redactor = CredentialRedactor();
  return DiagnosticRecord(
    sequence: record.sequence,
    recordedAt: record.recordedAt,
    subsystem: record.subsystem,
    kind: record.kind,
    code: _bounded(redactor.redact(record.code)),
    operation: _bounded(redactor.redact(record.operation)),
    fields: <String, String>{
      for (final entry in record.fields.entries)
        _bounded(redactor.redact(entry.key)): _bounded(
          redactor.redact(entry.value),
        ),
    },
  );
}
