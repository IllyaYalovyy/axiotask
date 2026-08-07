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
}
