import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskCanary = 'PRIVATE_TASK_CANARY_72c6';
  const bearerCanary =
      'Bearer '
      'credential-canary-0123456789';
  const refreshCanary = 'refresh_token=credential-canary-refresh';
  const callbackCanary =
      'https://127.0.0.1/callback?code=credential-canary-code&state=safe';

  DiagnosticEvent canaryEvent() => const DiagnosticEvent(
    code: 'synthetic.failure',
    operation: 'authorize',
    fields: <DiagnosticField>[
      DiagnosticField.safe('status', 'failed'),
      DiagnosticField.safe('mislabelledBearer', bearerCanary),
      DiagnosticField.private('taskTitle', taskCanary),
      DiagnosticField.private('oauthError', refreshCanary),
      DiagnosticField.private('callback', callbackCanary),
      DiagnosticField.credential('token', 'credential-canary-direct'),
    ],
  );

  test('production diagnostics retain only redacted safe fields', () {
    final history = InMemoryDiagnosticHistory();
    final sink = ProductionDiagnosticSink(history);

    sink.record(canaryEvent());

    final output = history.records.single.renderedText;
    expect(output, contains('status=failed'));
    expect(output, isNot(contains(taskCanary)));
    expect(output, isNot(contains('credential-canary')));
    expect(output, contains('[REDACTED]'));
  });

  test(
    'development diagnostics retain private context but redact credentials',
    () {
      final history = InMemoryDiagnosticHistory();
      final sink = SensitiveDevelopmentDiagnosticSink(history);

      sink.record(canaryEvent());

      final output = history.records.single.renderedText;
      expect(output, contains(taskCanary));
      expect(output, isNot(contains('credential-canary')));
      expect(output, isNot(contains('127.0.0.1/callback')));
      expect(output, contains('[REDACTED]'));
    },
  );
}
