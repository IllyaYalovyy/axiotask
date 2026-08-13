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
    required this.code,
    required this.operation,
    this.fields = const <DiagnosticField>[],
  });

  final String code;
  final String operation;
  final List<DiagnosticField> fields;
}

abstract interface class DiagnosticSink {
  void record(DiagnosticEvent event);
}

final class DiagnosticRecord {
  DiagnosticRecord({
    required this.code,
    required this.operation,
    required Map<String, String> fields,
  }) : fields = Map<String, String>.unmodifiable(fields);

  final String code;
  final String operation;
  final Map<String, String> fields;

  String get renderedText {
    final renderedFields = fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    return '$code operation=$operation $renderedFields'.trimRight();
  }
}

abstract interface class DiagnosticHistory {
  void append(DiagnosticRecord record);
}

final class InMemoryDiagnosticHistory implements DiagnosticHistory {
  final List<DiagnosticRecord> _records = <DiagnosticRecord>[];

  List<DiagnosticRecord> get records =>
      List<DiagnosticRecord>.unmodifiable(_records);

  @override
  void append(DiagnosticRecord record) {
    _records.add(record);
  }

  void clear() {
    _records.clear();
  }
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
      r'(authorization\s*[:=]\s*)([^\s,;]+(?:\s+[^\s,;]+)?)',
      caseSensitive: false,
    ),
    RegExp(
      r'(access_token|refresh_token|id_token|client_secret|code_verifier|authorization_code|dpop_private_key)\s*[:=]\s*[^&\s,;]+',
      caseSensitive: false,
    ),
    RegExp(
      r'([?&](?:code|access_token|refresh_token|id_token)=)[^&\s]+',
      caseSensitive: false,
    ),
    RegExp(r'AIza[0-9A-Za-z_-]{20,}'),
    RegExp(r'ya29\.[0-9A-Za-z._~-]{10,}'),
    RegExp(r'GOCSPX-[0-9A-Za-z_-]{10,}'),
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
    this._history, [
    this._redactor = const CredentialRedactor(),
  ]);

  final DiagnosticHistory _history;
  final CredentialRedactor _redactor;

  @override
  void record(DiagnosticEvent event) {
    final fields = <String, String>{};
    for (final field in event.fields) {
      if (field.privacy == DiagnosticFieldPrivacy.safe) {
        fields[field.name] = _redactor.redact(field.value);
      }
    }
    _history.append(
      DiagnosticRecord(
        code: _redactor.redact(event.code),
        operation: _redactor.redact(event.operation),
        fields: fields,
      ),
    );
  }
}

final class SensitiveDevelopmentDiagnosticSink implements DiagnosticSink {
  SensitiveDevelopmentDiagnosticSink(
    this._history, [
    this._redactor = const CredentialRedactor(),
  ]);

  final DiagnosticHistory _history;
  final CredentialRedactor _redactor;

  @override
  void record(DiagnosticEvent event) {
    final fields = <String, String>{};
    for (final field in event.fields) {
      if (field.privacy != DiagnosticFieldPrivacy.credential) {
        fields[field.name] = _redactor.redact(field.value);
      }
    }
    _history.append(
      DiagnosticRecord(
        code: _redactor.redact(event.code),
        operation: _redactor.redact(event.operation),
        fields: fields,
      ),
    );
  }
}
