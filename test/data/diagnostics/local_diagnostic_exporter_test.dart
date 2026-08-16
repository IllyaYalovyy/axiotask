import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/data/diagnostics/local_diagnostic_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskCanary = 'SYNTHETIC_PRIVATE_TASK_EXPORT_6d2f';
  const credentialCanary =
      'Bearer '
      'credential-export-canary-0123456789';

  test('HLT-010 release export contains safe summaries only', () async {
    final directory = Directory.systemTemp.createTempSync(
      'axiotask-release-export-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final history = InMemoryDiagnosticHistory(maxRecords: 10);
    addTearDown(history.close);
    ProductionDiagnosticSink(history, clock: _clock).record(
      const DiagnosticEvent(
        subsystem: DiagnosticSubsystem.sync,
        kind: DiagnosticEventKind.failure,
        code: 'sync.synthetic_failure',
        operation: 'reconcile',
        fields: <DiagnosticField>[
          DiagnosticField.safe('failed_count', 2),
          DiagnosticField.private('task_title', taskCanary),
          DiagnosticField.safe('mistagged', credentialCanary),
        ],
      ),
    );
    final exporter = LocalDiagnosticExporter(
      directory,
      product: DiagnosticProduct.releaseSafe,
      clock: _clock,
    );

    final receipt = await exporter.export(history.records);
    final output = File(
      '${directory.path}/${receipt.fileName}',
    ).readAsStringSync();

    expect(output, contains('sync.synthetic_failure'));
    expect(output, contains('failed_count'));
    expect(output, isNot(contains(taskCanary)));
    expect(output, isNot(contains('credential-export-canary')));
    expect(output, contains('[REDACTED]'));
  });

  test(
    'development export retains allowed context but rescrubs credentials',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'axiotask-development-export-test-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final history = InMemoryDiagnosticHistory(maxRecords: 10);
      addTearDown(history.close);
      SensitiveDevelopmentDiagnosticSink(history, clock: _clock).record(
        const DiagnosticEvent(
          subsystem: DiagnosticSubsystem.api,
          kind: DiagnosticEventKind.failure,
          code: 'api.synthetic_failure',
          operation: 'decode',
          fields: <DiagnosticField>[
            DiagnosticField.private('decoded_task', taskCanary),
            DiagnosticField.safe('mistagged', credentialCanary),
          ],
        ),
      );
      final exporter = LocalDiagnosticExporter(
        directory,
        product: DiagnosticProduct.sensitiveDevelopment,
        clock: _clock,
      );

      final receipt = await exporter.export(history.records);
      final output = File(
        '${directory.path}/${receipt.fileName}',
      ).readAsStringSync();

      expect(output, contains(taskCanary));
      expect(output, isNot(contains('credential-export-canary')));
      expect(output, contains('[REDACTED]'));
    },
  );
}

final _clock = ManualClock(DateTime.utc(2026, 8, 16, 12));
