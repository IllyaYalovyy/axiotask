// Packaging layer — the RPM build config must stay coherent with the app.
//
// What this protects (and the failures it prevents):
//   - VERSION DRIFT: the RPM's `Version:` is derived from pubspec.yaml. If the
//     render logic breaks or pubspec bumps without the spec following, users get
//     an RPM that lies about its version (bad upgrades, wrong bug reports).
//   - MISSING INSTALL PIECES: an RPM that forgets the launcher, desktop entry,
//     or icon installs a binary nobody can launch from the app menu. %files must
//     list all four install paths.
//   - UNDECLARED RUNTIME DEP: the release bundle dynamically links GTK3/GLib
//     (verified with ldd). Omitting the Requires ships an RPM that installs but
//     segfaults on a minimal host.
//   - METADATA SKEW: the fastforge maker config and the standalone build script
//     are two renderers of ONE package; they must agree on name and deps.
//
// The build script's `--print-spec` / `--dry-run` modes are pure (no flutter
// build, no rpmbuild, no clock, no network), so this is deterministic.
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Version that the RPM SHOULD carry: the `X.Y.Z` before the `+build` in
/// pubspec. Read independently here so the test, not the script, defines truth.
String _pubspecVersion() {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
  final raw = line.substring('version:'.length).trim();
  return raw.split('+').first;
}

ProcessResult _runScript(List<String> args) =>
    Process.runSync('bash', ['tool/build_rpm.sh', ...args]);

void main() {
  group('RPM spec render (tool/build_rpm.sh --print-spec)', () {
    late String spec;

    setUpAll(() {
      final r = _runScript(['--print-spec']);
      expect(
        r.exitCode,
        0,
        reason: '--print-spec must succeed offline: ${r.stderr}',
      );
      spec = r.stdout as String;
    });

    test('Version tracks pubspec.yaml (drift guard)', () {
      final version = _pubspecVersion();
      expect(
        spec,
        contains('Version:        $version'),
        reason: 'RPM Version must equal pubspec version $version',
      );
    });

    test('Name is the axiotask package', () {
      expect(spec, contains('Name:           axiotask'));
    });

    test(
      '%files installs launcher, desktop entry and icon (menu-launchable)',
      () {
        expect(spec, contains('/usr/bin/axiotask'));
        expect(spec, contains('/usr/share/applications/axiotask.desktop'));
        expect(
          spec,
          contains('/usr/share/icons/hicolor/512x512/apps/axiotask.png'),
        );
        expect(spec, contains('/usr/lib/axiotask'));
      },
    );

    test('declares the GTK3/GLib runtime dependency (ldd-verified)', () {
      expect(spec, contains('Requires:       gtk3'));
      expect(spec, contains('Requires:       glib2'));
    });

    test('GPLv3 license, matching the repo LICENSE', () {
      expect(spec, contains('License:        GPLv3'));
    });
  });

  test('spec metadata agrees with the fastforge make_config.yaml', () {
    final spec = _runScript(['--print-spec']).stdout as String;
    final cfg = File('linux/packaging/rpm/make_config.yaml').readAsStringSync();

    expect(cfg, contains('package_name: axiotask'));
    expect(spec, contains('Name:           axiotask'));

    // Every dependency the maker config declares must appear as a spec Requires.
    final depsBlock = cfg.split('dependencies:').last;
    for (final dep in ['gtk3', 'glib2']) {
      expect(
        depsBlock,
        contains('- $dep'),
        reason: 'make_config.yaml must list "$dep" as a dependency',
      );
      expect(
        spec,
        contains('Requires:       $dep'),
        reason: 'make_config dependency "$dep" must appear as a spec Requires',
      );
    }
  });

  // Non-happy path: the dry-run gate must degrade gracefully when the packaging
  // toolchain (rpmbuild) and the release bundle are absent — it validates and
  // reports, but never fails or invokes rpmbuild. This is what makes it usable
  // as a cheap gate check on a machine without rpm-build installed.
  test('--dry-run exits 0 and reports toolchain state without building', () {
    final r = _runScript(['--dry-run']);
    expect(
      r.exitCode,
      0,
      reason: 'dry-run must not require rpmbuild/bundle: ${r.stderr}',
    );
    final err = r.stderr as String;
    expect(err, contains('DRY RUN OK'));
    expect(err, contains('rpmbuild'));
  });

  test('unknown argument is rejected', () {
    final r = _runScript(['--bogus']);
    expect(r.exitCode, isNot(0));
    expect(r.stderr as String, contains('unknown argument'));
  });

  // The desktop launcher must invoke the same name the RPM symlinks into PATH,
  // or the app-menu entry points at nothing.
  test('desktop entry Exec matches the /usr/bin launcher name', () {
    final desktop = File('linux/packaging/axiotask.desktop').readAsStringSync();
    expect(desktop, contains('Exec=axiotask'));
    expect(desktop, contains('Icon=axiotask'));
  });
}
