import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/auth/linux/linux_auth_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'probe failure keeps useful development evidence and redacts secrets',
    () {
      const canary = 'refresh_token=credential-canary-probe';
      final history = InMemoryDiagnosticHistory();
      final sink = SensitiveDevelopmentDiagnosticSink(history);
      sink.record(
        const DiagnosticEvent(
          code: 'auth.token_response_invalid',
          operation: 'linux-authorization',
          fields: <DiagnosticField>[
            DiagnosticField.safe('phase', 'token-exchange'),
            DiagnosticField.private('responseClass', 'malformed-json'),
            DiagnosticField.credential('credential', canary),
          ],
        ),
      );

      final rendered = LinuxAuthProbeException(
        primary: StateError('exchange failed: $canary'),
        cleanup: StateError('cleanup failed: $canary'),
        diagnostics: history.records,
      ).toString();

      expect(rendered, contains('exchange failed'));
      expect(rendered, contains('Cleanup also failed'));
      expect(rendered, contains('auth.token_response_invalid'));
      expect(rendered, contains('phase=token-exchange'));
      expect(rendered, contains('responseClass=malformed-json'));
      expect(rendered, isNot(contains('credential-canary-probe')));
      expect(rendered, contains('[REDACTED]'));
    },
  );
}
