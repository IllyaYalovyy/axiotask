import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskCanary = 'PRIVATE_TASK_CANARY_72c6';
  const accountCanary = 'private.account@example.test';
  const remoteIdCanary = 'remote-id-private-77';
  const urlCanary =
      'https://tasks.example.test/private/path?task=PRIVATE_TASK_CANARY_72c6';
  const sqlCanary = "UPDATE tasks SET title='PRIVATE_TASK_CANARY_72c6'";
  const payloadCanary = '{"title":"PRIVATE_TASK_CANARY_72c6"}';
  const bearerCanary =
      'Bearer '
      'credential-canary-0123456789';
  const refreshCanary = 'refresh_token=credential-canary-refresh';
  const callbackCanary =
      'https://127.0.0.1/callback?code=credential-canary-code&state=safe';

  DiagnosticEvent canaryEvent(DiagnosticSubsystem subsystem) => DiagnosticEvent(
    subsystem: subsystem,
    kind: DiagnosticEventKind.failure,
    code: 'synthetic.failure',
    operation: 'authorize',
    fields: const <DiagnosticField>[
      DiagnosticField.safe('status', 'failed'),
      DiagnosticField.safe('mislabelledBearer', bearerCanary),
      DiagnosticField.private('taskTitle', taskCanary),
      DiagnosticField.private('account', accountCanary),
      DiagnosticField.private('remoteId', remoteIdCanary),
      DiagnosticField.private('requestUrl', urlCanary),
      DiagnosticField.private('sql', sqlCanary),
      DiagnosticField.private('payload', payloadCanary),
      DiagnosticField.private('oauthError', refreshCanary),
      DiagnosticField.private('callback', callbackCanary),
      DiagnosticField.credential('token', 'credential-canary-direct'),
    ],
  );

  test('HLT-010 release retains typed safe context only', () {
    final history = InMemoryDiagnosticHistory(maxRecords: 20);
    final sink = ProductionDiagnosticSink(history);

    for (final subsystem in DiagnosticSubsystem.values) {
      sink.record(canaryEvent(subsystem));
    }

    expect(history.records, hasLength(DiagnosticSubsystem.values.length));
    expect(
      history.records.map((record) => record.subsystem),
      DiagnosticSubsystem.values,
    );
    for (final record in history.records) {
      expect(record.kind, DiagnosticEventKind.failure);
      expect(record.renderedText, contains('status=failed'));
      expect(record.renderedText, isNot(contains(taskCanary)));
      expect(record.renderedText, isNot(contains(accountCanary)));
      expect(record.renderedText, isNot(contains(remoteIdCanary)));
      expect(record.renderedText, isNot(contains(urlCanary)));
      expect(record.renderedText, isNot(contains(sqlCanary)));
      expect(record.renderedText, isNot(contains('credential-canary')));
      expect(record.renderedText, contains('[REDACTED]'));
    }
  });

  test('HLT-010 development retains private context except credentials', () {
    final history = InMemoryDiagnosticHistory(maxRecords: 20);
    final sink = SensitiveDevelopmentDiagnosticSink(history);

    sink.record(canaryEvent(DiagnosticSubsystem.api));

    final output = history.records.single.renderedText;
    expect(output, contains(taskCanary));
    expect(output, contains(accountCanary));
    expect(output, contains(remoteIdCanary));
    expect(output, contains(urlCanary));
    expect(output, contains(sqlCanary));
    expect(output, contains(payloadCanary));
    expect(output, isNot(contains('credential-canary')));
    expect(output, isNot(contains('127.0.0.1/callback')));
    expect(output, contains('[REDACTED]'));
  });

  test('credential shapes are scrubbed even when fields are marked safe', () {
    final values = <String>[
      'Bearer '
          'credential-canary-bearer',
      'Authorization: Basic credential-canary-basic',
      'access_token=credential-canary-access',
      'refresh_token: credential-canary-refresh',
      'client_secret=credential-canary-client',
      'code_verifier=credential-canary-verifier',
      'authorization_code=credential-canary-code',
      'dpop_private_key=credential-canary-dpop',
      callbackCanary,
      'ya'
          '29.credential-canary-google-access',
      'GOC'
          'SPX-credential-canary-google-secret',
      'eyJhbGciOiJSUzI1NiJ9.credential-canary.jwt-signature',
      '-----BEGIN PRI'
          'VATE KEY-----\ncredential-canary-key\n'
          '-----END PRI'
          'VATE KEY-----',
    ];
    for (final sinkFactory in <DiagnosticSink Function(DiagnosticHistory)>[
      ProductionDiagnosticSink.new,
      SensitiveDevelopmentDiagnosticSink.new,
    ]) {
      final history = InMemoryDiagnosticHistory(maxRecords: values.length);
      final sink = sinkFactory(history);
      for (final value in values) {
        sink.record(
          DiagnosticEvent(
            subsystem: DiagnosticSubsystem.authorization,
            kind: DiagnosticEventKind.failure,
            code: 'credential.canary',
            operation: 'redact',
            fields: <DiagnosticField>[
              DiagnosticField.safe('mislabelled', value),
            ],
          ),
        );
      }
      final output = history.records
          .map((record) => record.renderedText)
          .join('\n');
      expect(output, isNot(contains('credential-canary')));
      expect(output, contains('[REDACTED]'));
    }
  });

  test('HLT-011 bounded history retains newest aggregate transitions', () {
    final history = InMemoryDiagnosticHistory(maxRecords: 3);
    final sink = ProductionDiagnosticSink(history);

    for (var index = 0; index < 5; index += 1) {
      sink.record(
        DiagnosticEvent(
          subsystem: DiagnosticSubsystem.sync,
          kind: DiagnosticEventKind.resolution,
          code: 'sync.automatic_resolution_summary',
          operation: 'reconcile',
          fields: <DiagnosticField>[
            DiagnosticField.safe('generation', index),
            DiagnosticField.safe('google_won', index + 1),
          ],
        ),
      );
    }

    expect(history.records, hasLength(3));
    expect(
      history.records.map((record) => record.fields['generation']),
      <String>['2', '3', '4'],
    );
    history.clear();
    expect(history.records, isEmpty);
  });

  test('persistent history survives restart and cleans up oldest records', () {
    final directory = Directory.systemTemp.createTempSync(
      'axiotask-diagnostics-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/safe-diagnostics.json');

    var history = PersistentDiagnosticHistory.open(file, maxRecords: 3);
    final sink = ProductionDiagnosticSink(history);
    for (var index = 0; index < 3; index += 1) {
      sink.record(
        DiagnosticEvent(
          subsystem: DiagnosticSubsystem.storage,
          kind: DiagnosticEventKind.transition,
          code: 'storage.transition.$index',
          operation: 'persist',
        ),
      );
    }
    history.close();

    history = PersistentDiagnosticHistory.open(file, maxRecords: 2);
    addTearDown(history.close);
    expect(history.records.map((record) => record.code), <String>[
      'storage.transition.1',
      'storage.transition.2',
    ]);
    expect(history.records.every((record) => record.sequence > 0), isTrue);
    expect(history.records.every((record) => record.recordedAt.isUtc), isTrue);

    history.clear();
    history.close();
    final reopened = PersistentDiagnosticHistory.open(file, maxRecords: 2);
    addTearDown(reopened.close);
    expect(reopened.records, isEmpty);
  });

  test('persistent schema rejects a different product or version', () {
    final directory = Directory.systemTemp.createTempSync(
      'axiotask-diagnostics-schema-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/diagnostics.json')
      ..writeAsStringSync(
        '{"schemaVersion":999,"product":"releaseSafe","records":[]}',
      );

    expect(
      () => PersistentDiagnosticHistory.open(file, maxRecords: 10),
      throwsA(isA<DiagnosticPersistenceException>()),
    );

    file.writeAsStringSync(
      '{"schemaVersion":1,"product":"sensitiveDevelopment","records":[]}',
    );
    expect(
      () => PersistentDiagnosticHistory.open(
        file,
        product: DiagnosticProduct.releaseSafe,
        maxRecords: 10,
      ),
      throwsA(isA<DiagnosticPersistenceException>()),
    );
  });

  test('restart scrubs credential material already present in storage', () {
    final directory = Directory.systemTemp.createTempSync(
      'axiotask-diagnostics-rescrub-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/diagnostics.json');
    final storedCredential =
        'Bearer '
        'credential-canary-stored-value';
    file.writeAsStringSync(
      jsonEncode(<String, Object>{
        'schemaVersion': 1,
        'product': 'sensitiveDevelopment',
        'records': <Object>[
          <String, Object>{
            'sequence': 1,
            'recordedAt': '2026-08-16T12:00:00.000Z',
            'subsystem': 'storage',
            'kind': 'failure',
            'code': 'storage.canary',
            'operation': 'reopen',
            'fields': <String, String>{'value': storedCredential},
          },
        ],
      }),
    );

    final history = PersistentDiagnosticHistory.open(
      file,
      product: DiagnosticProduct.sensitiveDevelopment,
      maxRecords: 10,
    );
    addTearDown(history.close);

    expect(
      history.records.single.renderedText,
      isNot(contains(storedCredential)),
    );
    expect(history.records.single.renderedText, contains('[REDACTED]'));
    expect(file.readAsStringSync(), isNot(contains(storedCredential)));
  });
}
