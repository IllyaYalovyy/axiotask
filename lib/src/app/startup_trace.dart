// Cold-start tracing (T2.5 / RESEARCH §"Startup": measure release-build cold
// start against the 2s budget).
//
// The app normally launches SILENTLY. When AXIOTASK_STARTUP_TRACE=1 is set,
// main.dart prints a single marker line to stdout on the first rendered frame.
// The measurement harness (tool/measure_cold_start.sh) times process-spawn →
// that marker against an already-running display, which is the true cold start
// (process creation + engine init + Dart bootstrap + first frame).
//
// The marker's EXACT shape is a contract between the app and the script: the
// script greps [firstFrameMarker] to know the frame landed and parses
// `main_to_first_frame_ms=<n>` for the Dart-side portion. It is pinned by
// startup_trace_test.dart so a rename can never silently break (or falsify) the
// measurement. Nothing here reads wall time — the timing comes from a
// [Stopwatch] (monotonic; the DateTime.now/Timer ban does not apply) in main
// and from the harness's own clock — so this stays a pure, testable helper.

/// Env var that turns cold-start tracing on. Off (silent) unless set to `'1'`.
const startupTraceEnv = 'AXIOTASK_STARTUP_TRACE';

/// The token the measurement script greps stdout for to detect the first frame.
const firstFrameMarker = 'AXIOTASK_FIRST_FRAME';

/// Whether cold-start tracing is enabled for this launch. Strictly `'1'` — any
/// other value (absent, empty, `'true'`) leaves the app in its silent default,
/// so tracing is never turned on by accident.
bool startupTraceEnabled(Map<String, String> env) =>
    env[startupTraceEnv] == '1';

/// The single-line first-frame marker the app prints when tracing is on.
/// [sinceMain] is the Dart-side `main()` → first-frame span (a lower bound on
/// cold start; the harness measures the authoritative spawn → frame externally).
String firstFrameLine(Duration sinceMain) =>
    '$firstFrameMarker main_to_first_frame_ms=${sinceMain.inMilliseconds}';
