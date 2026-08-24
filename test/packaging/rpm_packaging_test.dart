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
//   - MENU-PLACEMENT SKEW: the RPM ships two declarations of where the app
//     belongs — the desktop entry (read by the app menu) and the AppStream
//     metainfo (read by software centres). Disagreement files the app under
//     different headings depending on where the user looks for it.
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

/// The one canonical application id (#227): the AppStream component id, the
/// metainfo file name, the desktop-entry basename and the GTK application id
/// are all THIS string. The RPM package and the binary keep the short name.
const _appId = 'io.github.illyayalovyy.axiotask';
const _appName = 'axiotask';
const _desktopSrc = 'linux/packaging/$_appId.desktop';
const _metainfoSrc = 'linux/packaging/$_appId.metainfo.xml';
const _hicolorSizes = <int>[16, 24, 32, 48, 64, 128, 256, 512];

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

    test('%files installs launcher, desktop entry, icon and metainfo '
        '(menu-launchable, listed in software centres)', () {
      expect(spec, contains('/usr/bin/axiotask'));
      expect(spec, contains('/usr/share/applications/$_appId.desktop'));
      // Every themed size, not just the big one: GNOME picks the 16px bitmap
      // for menu lists, and a lone 512px icon is scaled down to mush.
      for (final size in _hicolorSizes) {
        expect(
          spec,
          contains('/usr/share/icons/hicolor/${size}x$size/apps/axiotask.png'),
          reason: 'hicolor ${size}px icon is not packaged',
        );
      }
      expect(
        spec,
        contains('/usr/share/icons/hicolor/scalable/apps/axiotask.svg'),
      );
      expect(spec, contains('/usr/lib/axiotask'));
      expect(
        spec,
        contains('/usr/share/metainfo/$_appId.metainfo.xml'),
        reason:
            'without the AppStream metainfo GNOME Software shows the RPM as '
            'an unnamed binary',
      );
    });

    test('URL points at the real project home', () {
      expect(
        spec,
        contains('URL:            https://github.com/IllyaYalovyy/axiotask'),
      );
    });

    test('declares the GTK3/GLib runtime dependency (ldd-verified)', () {
      expect(spec, contains('Requires:       gtk3'));
      expect(spec, contains('Requires:       glib2'));
    });

    test('GPLv3 license, matching the repo LICENSE', () {
      expect(spec, contains('License:        GPLv3'));
    });
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

  // ONE RPM ROUTE (#231). tool/build_rpm.sh is the only path that produces an
  // axiotask RPM. A config-driven packager generates its own desktop entry,
  // named after the PACKAGE rather than the application id, and a window whose
  // Wayland app_id has no desktop file of that basename shows a blank icon in
  // the dash (#227) — a second route would ship that regression while every
  // assertion above, which only reads build_rpm.sh, stayed green.
  //
  // The bracketed letters keep the banned names out of this file's own text:
  // the regexes still match them, but a repo-wide grep for them stays clean.
  test('no second RPM packaging route exists in the tracked tree', () {
    const banned = r'fast[f]orge|flutter_[d]istributor|distribute_[o]ptions';
    final r = Process.runSync('git', ['grep', '-InIE', banned]);
    expect(
      r.exitCode,
      1, // git grep: 1 = no match, 0 = matched, >1 = the command itself failed
      reason:
          'tool/build_rpm.sh must be the single RPM route (#231), but the '
          'tracked tree still references a removed one:\n'
          '${r.stdout}${r.stderr}',
    );
  });

  test('unknown argument is rejected', () {
    final r = _runScript(['--bogus']);
    expect(r.exitCode, isNot(0));
    expect(r.stderr as String, contains('unknown argument'));
  });

  // The desktop launcher must invoke the same name the RPM symlinks into PATH,
  // or the app-menu entry points at nothing.
  test('desktop entry Exec matches the /usr/bin launcher name', () {
    final desktop = File(_desktopSrc).readAsStringSync();
    expect(desktop, contains('Exec=$_appName'));
    expect(desktop, contains('Icon=$_appName'));
  });

  // The RPM installs both the desktop entry and the AppStream metainfo; they
  // are two declarations of the same menu placement, and a category present in
  // one but not the other means the app menu and GNOME Software file the app
  // under different headings.
  test('AppStream categories agree with the desktop entry', () {
    final desktopCategories = File(_desktopSrc)
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('Categories='))
        .substring('Categories='.length)
        .split(';')
        .where((c) => c.isNotEmpty);
    final metainfoCategories = RegExp(
      r'<category>([^<]+)</category>',
    ).allMatches(File(_metainfoSrc).readAsStringSync()).map((m) => m.group(1)!);
    expect(metainfoCategories, unorderedEquals(desktopCategories.toList()));
  });

  // Spec/staging skew: a path listed in %files that nothing stages makes
  // rpmbuild fail at package time (found only by a full RPM build, which the
  // gate cannot run), and a staged file missing from %files is silently
  // dropped from the package. --stage renders the buildroot from a bundle
  // without flutter or rpmbuild, so both directions are checkable here.
  group('buildroot staging (tool/build_rpm.sh --stage)', () {
    late Directory root;
    late Directory bundle;

    setUp(() {
      root = Directory.systemTemp.createTempSync('axiotask_rpmroot_');
      bundle = Directory.systemTemp.createTempSync('axiotask_rpmbundle_');
      File('${bundle.path}/axiotask').writeAsStringSync('#!/bin/sh\ntrue\n');
      Process.runSync('chmod', ['+x', '${bundle.path}/axiotask']);
      Directory('${bundle.path}/lib').createSync();
      File('${bundle.path}/lib/libapp.so').writeAsStringSync('so');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
      bundle.deleteSync(recursive: true);
    });

    test('every %files path is actually staged', () {
      final r = Process.runSync('bash', [
        'tool/build_rpm.sh',
        '--stage',
        root.path,
        '--bundle',
        bundle.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      final spec = _runScript(['--print-spec']).stdout as String;
      final files = spec
          .split('%files')
          .last
          .split('%post')
          .first
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.startsWith('/'));
      expect(files, isNotEmpty);
      for (final f in files) {
        final staged = '${root.path}$f';
        expect(
          File(staged).existsSync() ||
              Directory(staged).existsSync() ||
              Link(staged).existsSync(),
          isTrue,
          reason: '%files lists $f but nothing stages it',
        );
      }
    });

    // Non-happy path: staging from a directory that holds no release binary
    // must fail loudly rather than produce an RPM full of nothing.
    test('staging refuses a bundle without the release binary', () {
      final empty = Directory.systemTemp.createTempSync('axiotask_empty_');
      final r = Process.runSync('bash', [
        'tool/build_rpm.sh',
        '--stage',
        root.path,
        '--bundle',
        empty.path,
      ]);
      expect(r.exitCode, isNot(0));
      expect(r.stderr as String, contains('binary'));
      empty.deleteSync(recursive: true);
    });
  });
}
