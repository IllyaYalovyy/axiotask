// Minimal structured logging — the Dart stand-in for the reference's `tracing`
// subscriber (`init_tracing`). No logging package is pulled in for this; a
// single facade routes records to a sink so startup/sync code can log without
// each call site deciding where output goes.
//
// The default sink writes through `dart:developer`'s `log` (visible in an
// attached debugger and in logcat on Android) AND, on desktop, mirrors
// info/warn/error to stderr. The stderr half is load-bearing (#206):
// `dart:developer` records are invisible in a standalone desktop launch and
// even under `flutter run` on Linux, which once made a repeatedly failing
// sign-in indistinguishable from a dead button. Tests install a recording
// sink instead.

import 'dart:developer' as developer;
import 'dart:io' show Platform, stderr;

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

  /// Install the production default: `dart:developer` everywhere, plus the
  /// stderr console sink on desktop (#206). Idempotent.
  static void initLogging() {
    final onDesktop =
        Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    if (!onDesktop) {
      _sink = _developerSink;
      return;
    }
    final console = consoleSink(stderr);
    _sink = (level, message) {
      _developerSink(level, message);
      console(level, message);
    };
  }

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

/// A sink writing info/warn/error records to [out] as
/// `axiotask [level] message` lines; debug records stay off the console.
/// Production passes `stderr`; tests pass a buffer.
LogSink consoleSink(StringSink out) => (level, message) {
  if (level == LogLevel.debug) return;
  out.writeln('axiotask [${level.name}] $message');
};
