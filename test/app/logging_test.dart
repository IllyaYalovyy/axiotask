import 'package:axiotask/src/app/logging.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(Log.initLogging); // restore the default sink between tests.

  test('records route to the installed sink with their level', () {
    final records = <(LogLevel, String)>[];
    Log.useSink((level, message) => records.add((level, message)));

    Log.info('starting default instance');
    Log.warn('startup sync failed');
    Log.error('store failed to open');

    expect(records, [
      (LogLevel.info, 'starting default instance'),
      (LogLevel.warn, 'startup sync failed'),
      (LogLevel.error, 'store failed to open'),
    ]);
  });

  test('initLogging replaces a test sink with the default (no throw)', () {
    Log.useSink((_, _) => throw StateError('should be replaced'));
    Log.initLogging();
    // With the default sink reinstalled this must not reach the throwing spy.
    expect(() => Log.info('ok'), returnsNormally);
  });

  // The desktop console sink exists because dart:developer records are
  // invisible outside a debugger: a standalone bundle launch — and even
  // `flutter run` on desktop Linux — prints NOTHING, which made a repeatedly
  // failing sign-in look like a dead button (#206). Anything a user might
  // need to report must reach stderr.
  group('console sink (#206)', () {
    test(
      'info/warn/error reach the console line-formatted, debug stays out',
      () {
        final out = StringBuffer();
        final sink = consoleSink(out);

        sink(LogLevel.debug, 'per-cycle chatter');
        sink(LogLevel.info, 'starting default instance');
        sink(LogLevel.warn, 'sign-in failed: boom');
        sink(LogLevel.error, 'store failed to open');

        expect(out.toString(), '''
axiotask [info] starting default instance
axiotask [warn] sign-in failed: boom
axiotask [error] store failed to open
''');
      },
    );

    test('multi-line messages stay one record per line prefix', () {
      final out = StringBuffer();
      consoleSink(out)(LogLevel.warn, 'first\nsecond');
      // The prefix marks the record start; continuation lines pass through —
      // a console reader can still attribute them to the record above.
      expect(out.toString(), 'axiotask [warn] first\nsecond\n');
    });
  });
}
