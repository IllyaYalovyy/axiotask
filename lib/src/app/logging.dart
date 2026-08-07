// Minimal structured logging — the Dart stand-in for the reference's `tracing`
// subscriber (`init_tracing`). No logging package is pulled in for this; a
// single facade routes records to a sink so startup/sync code can log without
// each call site deciding where output goes.
//
// The default sink writes through `dart:developer`'s `log`, which surfaces in
// `flutter logs` / logcat on device and the debug console on desktop — the
// cross-platform equivalent of the reference pointing desktop at stdout and
// Android at logcat. Tests install a recording sink instead.

import 'dart:developer' as developer;

/// Severity levels, mirroring `tracing`'s info/warn/error usage in the app.
enum LogLevel { debug, info, warn, error }

/// A destination for log records.
typedef LogSink = void Function(LogLevel level, String message);

/// The process-wide logging facade.
class Log {
  Log._();

  static LogSink _sink = _developerSink;

  /// Install a sink (startup wiring, or a test spy). Returns nothing; call
  /// [initLogging] for the production default.
  static void useSink(LogSink sink) => _sink = sink;

  /// Route the default sink to `dart:developer`. Idempotent.
  static void initLogging() => _sink = _developerSink;

  static void debug(String m) => _sink(LogLevel.debug, m);
  static void info(String m) => _sink(LogLevel.info, m);
  static void warn(String m) => _sink(LogLevel.warn, m);
  static void error(String m) => _sink(LogLevel.error, m);

  static void _developerSink(LogLevel level, String message) {
    developer.log(message, name: 'axiotask', level: _levelValue(level));
  }

  // dart:developer log levels loosely follow package:logging's numeric scale.
  static int _levelValue(LogLevel level) => switch (level) {
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warn => 900,
    LogLevel.error => 1000,
  };
}
