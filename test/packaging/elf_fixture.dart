// Real ELF fixtures for the packaging suites (#301).
//
// The packagers rewrite the RUNPATH of every shared object they install, and
// the only honest way to check that is to hand them a REAL linker-produced
// shared object and read the result back with readelf. A text file named
// `*.so` would prove nothing: the rewrite would skip it and the assertion
// would pass on a packager that does not rewrite anything at all.
import 'dart:io';

/// True when [tool] is on PATH.
bool installed(String tool) => Process.runSync('which', [tool]).exitCode == 0;

/// Links a real ELF shared object at [path] whose DT_RUNPATH is [runpath].
///
/// `-Wl,-rpath` with the toolchain default (`--enable-new-dtags`) emits
/// DT_RUNPATH, which is exactly what the Flutter plugin libraries carry.
void linkSharedObject({required String path, required String runpath}) {
  final src = File('$path.c')
    ..writeAsStringSync('int axiotask_probe(void){return 0;}\n');
  final r = Process.runSync('cc', [
    '-shared',
    '-fPIC',
    '-o',
    path,
    '-Wl,-rpath,$runpath',
    src.path,
  ]);
  if (r.exitCode != 0) {
    throw StateError('cc failed to link $path:\n${r.stdout}${r.stderr}');
  }
  src.deleteSync();
}

/// The DT_RUNPATH/DT_RPATH string of the ELF file at [path], or null when it
/// declares neither. Anything readelf cannot parse as an ELF file is null too.
String? runpathOf(String path) {
  final r = Process.runSync('readelf', ['-d', path]);
  if (r.exitCode != 0) return null;
  final m = RegExp(
    r'Library (?:runpath|rpath): \[([^\]]*)\]',
  ).firstMatch(r.stdout as String);
  return m?.group(1);
}
