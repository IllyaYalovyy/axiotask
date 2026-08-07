// The cold-start trace contract (T2.5). The release-build cold-start
// measurement (tool/measure_cold_start.sh) launches the app with
// AXIOTASK_STARTUP_TRACE=1 and greps stdout for a first-frame marker to know
// when the app became visible. These tests pin the two things the script and
// the app must agree on: WHEN tracing is on, and the EXACT shape of the marker
// line it parses. Drift either silently breaks the measurement (a marker the
// script can't find hangs it) or reports a wrong number — so the format is a
// contract, unit-tested here rather than discovered by a flaky external script.

import 'package:axiotask/src/app/startup_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('startupTraceEnabled', () {
    test('is on only when the env flag is exactly "1"', () {
      expect(startupTraceEnabled({startupTraceEnv: '1'}), isTrue);
    });

    test('is off when the flag is absent (the normal, silent launch)', () {
      expect(startupTraceEnabled(const {}), isFalse);
    });

    test('is off for any other value (never accidentally traced)', () {
      expect(startupTraceEnabled({startupTraceEnv: '0'}), isFalse);
      expect(startupTraceEnabled({startupTraceEnv: 'true'}), isFalse);
      expect(startupTraceEnabled({startupTraceEnv: ''}), isFalse);
    });
  });

  group('firstFrameLine', () {
    test('carries the marker and the elapsed ms the script greps for', () {
      final line = firstFrameLine(const Duration(milliseconds: 1234));
      // The script keys on this exact marker to detect the first frame …
      expect(line, startsWith(firstFrameMarker));
      // … and parses the milliseconds off this exact key=value token.
      expect(line, contains('main_to_first_frame_ms=1234'));
    });

    test('reports whole milliseconds, never fractional', () {
      final line = firstFrameLine(const Duration(microseconds: 4500));
      expect(line, contains('main_to_first_frame_ms=4'));
    });

    test('is a single line (the grep reads it as one record)', () {
      final line = firstFrameLine(const Duration(milliseconds: 10));
      expect(line, isNot(contains('\n')));
    });
  });
}
