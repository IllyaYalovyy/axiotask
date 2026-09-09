// Packaging layer — the Debian/Ubuntu half of the release (#300).
//
// The RPM (tool/build_rpm.sh) covers Fedora. Everyone else installs a .deb, and
// a .deb is not a tarball with a different suffix: dpkg refuses or mis-installs
// a package whose control metadata is wrong, and apt refuses one whose Depends
// cannot be satisfied. This suite builds a REAL package with the REAL dpkg-deb
// from a stand-in bundle and reads the result back with dpkg-deb, so every
// assertion below is about a package a user could actually install.
//
// What this protects (and the failures it prevents):
//   - VERSION DRIFT: the control Version is derived from pubspec. A package
//     that lies about its version upgrades wrongly (dpkg compares versions) and
//     sends every bug report to the wrong build.
//   - LAYOUT SKEW BETWEEN THE TWO PACKAGES: the .deb must install what the RPM
//     installs, at the same paths — the desktop entry, every hicolor size and
//     the AppStream metainfo included. The %files list of the RPM is read here
//     and demanded of the .deb, so the two distributions cannot drift into
//     different apps (a missing metainfo means an unnamed entry in the software
//     centre; a missing icon size means a blurry menu icon; a missing launcher
//     means nothing to run).
//   - UNSATISFIABLE OR UNDECLARED DEPENDENCIES: the bundle dynamically links
//     GTK3, GLib and libstdc++ (ldd-verified). Undeclared, the package installs
//     and then dies on a minimal host; declared under a name that does not
//     exist on the target release (Ubuntu's t64 rename), apt refuses to install
//     it at all. Depends must name both spellings and pin the build baseline.
//   - A PACKAGE dpkg CANNOT VERIFY: without DEBIAN/md5sums `dpkg -V` reports
//     nothing and lintian errors; with a STALE md5sums it reports corruption on
//     a perfectly good install.
//   - SILENT LINTIAN SUPPRESSION: overrides are how a package tells lintian
//     "this is deliberate". An override with no reason next to it is how a real
//     defect gets hidden, so every shipped override must carry a comment.
//
// Deterministic: no clock, no network, no flutter build — a stand-in bundle in
// a temp dir plus the real dpkg-deb.
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'elf_fixture.dart';

const _appId = 'io.github.illyayalovyy.axiotask';
const _appName = 'axiotask';
const _hicolorSizes = <int>[16, 24, 32, 48, 64, 128, 256, 512];

/// `X.Y.Z` and the `+B` build number of pubspec, read independently so the
/// TEST, not the script, defines what the package version has to be.
({String version, String build}) _pubspecVersion() {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
  final raw = line.substring('version:'.length).trim();
  return (version: raw.split('+').first, build: raw.split('+').last);
}

ProcessResult _runScript(List<String> args) =>
    Process.runSync('bash', ['tool/build_deb.sh', ...args]);

/// The build-tree RUNPATH the Flutter toolchain links into every plugin
/// library — an absolute path to the directory the plugin was COMPILED in,
/// which means nothing on the machine the package is installed on (#301).
const _buildTreeRunpath = '/nonexistent/axiotask/linux/flutter/ephemeral';

/// A stand-in for `flutter build linux --release` output: the binary the
/// launcher points at plus the bundled shared objects.
///
/// `libfake_plugin.so` is a REAL linked shared object carrying a build-tree
/// RUNPATH, so the packager's rewrite is exercised on the same kind of file it
/// meets in a release bundle; `libapp.so` is deliberately NOT an ELF file, so
/// the rewrite has to walk past what it cannot parse instead of failing.
Directory _makeBundle() {
  final d = Directory.systemTemp.createTempSync('axiotask_debbundle_');
  File('${d.path}/$_appName').writeAsStringSync('#!/bin/sh\ntrue\n');
  Process.runSync('chmod', ['+x', '${d.path}/$_appName']);
  Directory('${d.path}/lib').createSync();
  File('${d.path}/lib/libapp.so').writeAsStringSync('so');
  linkSharedObject(
    path: '${d.path}/lib/libfake_plugin.so',
    runpath: _buildTreeRunpath,
  );
  Directory('${d.path}/data/flutter_assets').createSync(recursive: true);
  File(
    '${d.path}/data/flutter_assets/AssetManifest.json',
  ).writeAsStringSync('{}');
  return d;
}

void main() {
  // Same ruling as the freedesktop validators in linux_distribution_test (#275):
  // the package here is built and read back by the REAL dpkg-deb. Without it
  // this suite would either skip silently or degrade into string matching on a
  // file this repository wrote itself.
  test('dpkg-deb is installed (prerequisite, never a silent skip)', () {
    expect(
      installed('dpkg-deb'),
      isTrue,
      reason:
          'dpkg-deb is missing — the .deb suite builds a real package with it.\n'
          '  Fedora: sudo dnf install dpkg\n'
          '  Debian/Ubuntu: it is part of the base system (dpkg)',
    );
  });

  // Same ruling, for the RUNPATH check (#301): the fixture is a real linked
  // shared object and the assertion is what readelf reads back out of the
  // packaged file. Without these two the RUNPATH group would silently degrade
  // into inspecting a text file the test wrote itself.
  test('cc and readelf are installed (prerequisite, never a silent skip)', () {
    expect(
      installed('cc'),
      isTrue,
      reason:
          'no C compiler — the RUNPATH assertions link a real shared object.\n'
          '  Fedora: sudo dnf install gcc\n'
          '  Debian/Ubuntu: sudo apt install build-essential',
    );
    expect(
      installed('readelf'),
      isTrue,
      reason:
          'readelf is missing — it is what reads the packaged RUNPATH back.\n'
          '  Fedora: sudo dnf install binutils\n'
          '  Debian/Ubuntu: sudo apt install binutils',
    );
  });

  group('control render (tool/build_deb.sh --print-control)', () {
    late String control;

    setUpAll(() {
      final r = _runScript(['--print-control']);
      expect(
        r.exitCode,
        0,
        reason: '--print-control must succeed offline: ${r.stderr}',
      );
      control = r.stdout as String;
    });

    String field(String name) => control
        .split('\n')
        .firstWhere(
          (l) => l.startsWith('$name:'),
          orElse: () => fail('control has no $name field:\n$control'),
        )
        .substring(name.length + 1)
        .trim();

    test(
      'Version is the pubspec version with the build number as revision',
      () {
        final v = _pubspecVersion();
        expect(
          field('Version'),
          '${v.version}-${v.build}',
          reason:
              'dpkg upgrades by comparing this string; it must track '
              'pubspec ${v.version}+${v.build}',
        );
      },
    );

    test('Package, Architecture and Priority are what dpkg expects', () {
      expect(field('Package'), _appName);
      expect(
        field('Architecture'),
        'amd64',
        reason: 'the bundle is a prebuilt x86_64 tree, not "all"',
      );
      expect(field('Priority'), 'optional');
      expect(field('Section'), isNotEmpty);
      expect(field('Maintainer'), contains('<'));
      expect(field('Homepage'), 'https://github.com/IllyaYalovyy/axiotask');
    });

    test('Depends names both GTK/GLib spellings and pins the baseline', () {
      final depends = field('Depends');
      // Ubuntu 24.04 and Debian 13 renamed these in the 64-bit time_t
      // transition. A package that names only one spelling is uninstallable on
      // half the target distributions.
      expect(
        depends,
        contains('libgtk-3-0t64'),
        reason: 'the t64 name is what Ubuntu 24.04 / Debian 13 ship',
      );
      expect(
        depends,
        contains('libgtk-3-0 '),
        reason: 'the pre-t64 alternative keeps older releases installable',
      );
      expect(depends, contains('libglib2.0-0t64'));
      expect(depends, contains('libstdc++6'));
      expect(
        depends,
        contains('libc6 (>='),
        reason:
            'the binary is built against the release runner glibc; an '
            'unversioned libc6 lets apt install it onto a host too old to run it',
      );
    });

    test('the extended description is more than the one-line Summary', () {
      final lines = control.split('\n');
      final i = lines.indexWhere((l) => l.startsWith('Description:'));
      expect(i, isNonNegative, reason: 'no Description field');
      expect(
        lines.skip(i + 1).takeWhile((l) => l.startsWith(' ')),
        isNotEmpty,
        reason:
            'apt show / software centres render the continuation lines; a '
            'one-line Description is a lintian error and an empty listing',
      );
    });
  });

  group('the built package (real dpkg-deb)', () {
    late Directory bundle;
    late Directory out;
    late File deb;
    late String contents;

    setUpAll(() {
      bundle = _makeBundle();
      out = Directory.systemTemp.createTempSync('axiotask_debout_');
      final r = _runScript(['--bundle', bundle.path, '--out', out.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final debs = out.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.deb'),
      );
      expect(
        debs,
        hasLength(1),
        reason: 'expected exactly one .deb in ${out.path}',
      );
      deb = debs.single;
      final c = Process.runSync('dpkg-deb', ['--contents', deb.path]);
      expect(c.exitCode, 0, reason: '${c.stdout}${c.stderr}');
      contents = c.stdout as String;
    });

    tearDownAll(() {
      bundle.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });

    /// Paths inside the package, normalised to absolute (`./usr/x` → `/usr/x`)
    /// and without the trailing slash dpkg prints on directories.
    Set<String> paths() => contents
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.split(' -> ').first.trim().split(RegExp(r'\s+')).last)
        .map((p) => p.replaceFirst('.', '').replaceAll(RegExp(r'/$'), ''))
        .toSet();

    test('the file name is what an apt/dpkg user expects', () {
      final v = _pubspecVersion();
      expect(
        deb.uri.pathSegments.last,
        '${_appName}_${v.version}-${v.build}_amd64.deb',
      );
    });

    test('installs everything the RPM installs, at the same paths', () {
      final spec =
          Process.runSync('bash', ['tool/build_rpm.sh', '--print-spec']).stdout
              as String;
      final rpmFiles = spec
          .split('%files')
          .last
          .split('%post')
          .first
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.startsWith('/'))
          .toList();
      expect(
        rpmFiles,
        isNotEmpty,
        reason: 'could not read the RPM %files list',
      );
      final inDeb = paths();
      for (final f in rpmFiles) {
        expect(
          inDeb.contains(f) || inDeb.any((p) => p.startsWith('$f/')),
          isTrue,
          reason:
              'the RPM installs $f and the .deb does not — the two packages '
              'would be different apps',
        );
      }
    });

    test('the launcher, desktop entry, icons and metainfo are all in it', () {
      final inDeb = paths();
      expect(inDeb, contains('/usr/bin/$_appName'));
      expect(inDeb, contains('/usr/lib/$_appName/$_appName'));
      expect(inDeb, contains('/usr/share/applications/$_appId.desktop'));
      expect(inDeb, contains('/usr/share/metainfo/$_appId.metainfo.xml'));
      for (final s in _hicolorSizes) {
        expect(
          inDeb,
          contains('/usr/share/icons/hicolor/${s}x$s/apps/$_appName.png'),
          reason: 'hicolor ${s}px icon is not packaged',
        );
      }
      expect(
        inDeb,
        contains('/usr/share/icons/hicolor/scalable/apps/$_appName.svg'),
      );
    });

    test('/usr/bin launcher is a relative symlink into /usr/lib', () {
      final line = contents
          .split('\n')
          .firstWhere((l) => l.contains('./usr/bin/$_appName'));
      expect(
        line.trim(),
        startsWith('l'),
        reason: 'the launcher must be a symlink, not a copy of the binary',
      );
      final target = line.split(' -> ').last.trim();
      expect(
        target,
        isNot(startsWith('/')),
        reason:
            'Debian policy 10.5: a link within the same top-level directory '
            '(/usr) must be relative, or it breaks under a chroot/merged-usr '
            'unpack',
      );
      expect(target, endsWith('/$_appName'));
    });

    test('ships the documentation Debian requires (copyright + changelog)', () {
      final inDeb = paths();
      expect(
        inDeb,
        contains('/usr/share/doc/$_appName/copyright'),
        reason: 'a package without a copyright file is a lintian ERROR',
      );
      expect(
        inDeb,
        contains('/usr/share/doc/$_appName/changelog.Debian.gz'),
        reason: 'a versioned (non-native) package must ship a Debian changelog',
      );
    });

    test('the copyright file states the project license', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_debx_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        Process.runSync('dpkg-deb', ['--extract', deb.path, tmp.path]).exitCode,
        0,
      );
      final copyright = File(
        '${tmp.path}/usr/share/doc/$_appName/copyright',
      ).readAsStringSync();
      expect(
        copyright,
        contains('GPL-3.0-or-later'),
        reason:
            'the metainfo declares GPL-3.0-or-later; the copyright file is the '
            'same claim to a Debian user and must not contradict it',
      );
      expect(
        copyright,
        contains('/usr/share/common-licenses/GPL-3'),
        reason: 'Debian policy 12.5: refer to the common license file',
      );
    });

    test('dpkg can verify the install (md5sums present and correct)', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_debmd5_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        Process.runSync('dpkg-deb', ['--extract', deb.path, tmp.path]).exitCode,
        0,
      );
      expect(
        Process.runSync('dpkg-deb', [
          '--control',
          deb.path,
          '${tmp.path}/DEBIAN',
        ]).exitCode,
        0,
      );
      final md5sums = File('${tmp.path}/DEBIAN/md5sums');
      expect(
        md5sums.existsSync(),
        isTrue,
        reason: 'no DEBIAN/md5sums — dpkg -V can verify nothing',
      );
      final lines = md5sums
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, isNotEmpty);
      for (final l in lines) {
        final parts = l.split(RegExp(r'\s+'));
        final recorded = parts.first;
        final path = '${tmp.path}/${parts.last}';
        expect(
          File(path).existsSync(),
          isTrue,
          reason: 'md5sums lists ${parts.last}, which is not in the package',
        );
        final actual = (Process.runSync('md5sum', [path]).stdout as String)
            .split(' ')
            .first;
        expect(
          actual,
          recorded,
          reason:
              'md5sums is stale for ${parts.last} — dpkg -V would report a '
              'clean install as corrupt',
        );
      }
      // The symlink and the DEBIAN control files are deliberately not listed.
      expect(
        lines.any((l) => l.endsWith('usr/bin/$_appName')),
        isFalse,
        reason: 'md5sums must not list the launcher symlink',
      );
    });

    test('the maintainer scripts refresh the icon and desktop caches', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_debctl_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/DEBIAN').createSync();
      expect(
        Process.runSync('dpkg-deb', [
          '--control',
          deb.path,
          '${tmp.path}/DEBIAN',
        ]).exitCode,
        0,
      );
      for (final name in ['postinst', 'postrm']) {
        final f = File('${tmp.path}/DEBIAN/$name');
        expect(f.existsSync(), isTrue, reason: 'DEBIAN/$name missing');
        expect(
          f.statSync().mode & 0x49, // any execute bit
          isNot(0),
          reason: 'dpkg refuses to run a non-executable $name',
        );
        final body = f.readAsStringSync();
        expect(
          body,
          contains('gtk-update-icon-cache'),
          reason:
              'without a cache refresh the freshly installed icon does not '
              'appear until the next login',
        );
        expect(body, contains('update-desktop-database'));
        expect(
          body,
          contains('set -e'),
          reason:
              'a maintainer script that ignores errors hides a broken '
              'install from dpkg',
        );
      }
    });

    test(
      'everything is owned by root (no builder uid leaks into the package)',
      () {
        final owners = contents
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) => l.split(RegExp(r'\s+'))[1])
            .toSet();
        expect(
          owners,
          {'root/root'},
          reason:
              'dpkg-deb --root-owner-group is what keeps the builder\'s uid out '
              'of the package; files owned by uid 1000 install unusably',
        );
      },
    );

    // #301. A plugin library keeps the RUNPATH of the directory it was BUILT
    // in, so a locally built package embeds the builder's home directory and a
    // released one points every shipped .so at a path that exists on no user's
    // machine. Both packagers rewrite it to $ORIGIN — the directory the library
    // is installed in, which is where the engine and the other plugins really
    // are — and this is the assertion that the shipped bytes say so.
    test('no packaged shared object searches outside its own directory', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_debrpath_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        Process.runSync('dpkg-deb', ['--extract', deb.path, tmp.path]).exitCode,
        0,
      );
      final elves = Directory('${tmp.path}/usr/lib/$_appName')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => runpathOf(f.path) != null)
          .toList();
      expect(
        elves,
        isNotEmpty,
        reason: 'the fixture bundle ships a shared object with a RUNPATH',
      );
      for (final f in elves) {
        final rpath = runpathOf(f.path)!;
        for (final entry in rpath.split(':')) {
          expect(
            entry,
            startsWith(r'$ORIGIN'),
            reason:
                '${f.path.substring(tmp.path.length)} is packaged with '
                'RUNPATH "$rpath" — a search path outside the installed '
                'bundle. lintian reports it as custom-library-search-path and '
                'a locally built package leaks the builder\'s directories.',
          );
        }
        expect(
          rpath,
          isNot(contains(_buildTreeRunpath)),
          reason: 'the build tree must not survive into the package',
        );
      }
    });

    test('lintian overrides ship, and every one carries its reason', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_deblint_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        Process.runSync('dpkg-deb', ['--extract', deb.path, tmp.path]).exitCode,
        0,
      );
      final overrides = File(
        '${tmp.path}/usr/share/lintian/overrides/$_appName',
      );
      expect(
        overrides.existsSync(),
        isTrue,
        reason:
            'the release workflow runs lintian with --fail-on; the tags that '
            'are inherent to a bundled Flutter app are answered by a shipped '
            'overrides file, not by dropping the check',
      );
      final lines = overrides.readAsLinesSync();
      final tags = lines.where(
        (l) => l.trim().isNotEmpty && !l.startsWith('#'),
      );
      expect(tags, isNotEmpty);
      for (final t in tags) {
        expect(
          t,
          startsWith('$_appName:'),
          reason: 'an override line must name the package: $t',
        );
      }
      // Each override is preceded by a comment explaining WHY.
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trim().isEmpty || l.startsWith('#')) continue;
        expect(
          i > 0 && lines[i - 1].trim().startsWith('#'),
          isTrue,
          reason:
              'override "$l" has no comment above it — an unexplained '
              'override is how a real packaging defect gets hidden',
        );
      }
    });

    // The other half of #301: once nothing searches outside $ORIGIN there is
    // nothing left to suppress, and a shipped override for a tag lintian no
    // longer emits is itself a lintian finding (unused-override) — as well as
    // a standing licence to reintroduce the defect unnoticed.
    test('custom-library-search-path is no longer suppressed', () {
      final tmp = Directory.systemTemp.createTempSync('axiotask_deblint2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(
        Process.runSync('dpkg-deb', ['--extract', deb.path, tmp.path]).exitCode,
        0,
      );
      final overrides = File(
        '${tmp.path}/usr/share/lintian/overrides/$_appName',
      ).readAsLinesSync().where((l) => !l.trim().startsWith('#'));
      expect(
        overrides.where((l) => l.contains('custom-library-search-path')),
        isEmpty,
        reason:
            'the RUNPATHs are rewritten to \$ORIGIN now, so this override '
            'suppresses a tag lintian does not emit (unused-override) and '
            'would hide the defect if it came back',
      );
    });
  });

  // Non-happy paths: the script must fail loudly rather than produce a package
  // that installs a broken app.
  group('failure modes', () {
    test('a bundle with no release binary is refused', () {
      final empty = Directory.systemTemp.createTempSync('axiotask_debempty_');
      final out = Directory.systemTemp.createTempSync('axiotask_debout2_');
      addTearDown(() {
        empty.deleteSync(recursive: true);
        out.deleteSync(recursive: true);
      });
      final r = _runScript(['--bundle', empty.path, '--out', out.path]);
      expect(r.exitCode, isNot(0));
      expect(r.stderr as String, contains('binary'));
      expect(
        out.listSync(),
        isEmpty,
        reason: 'a failed build must leave no half-written package behind',
      );
    });

    test('unknown argument is rejected', () {
      final r = _runScript(['--bogus']);
      expect(r.exitCode, isNot(0));
      expect(r.stderr as String, contains('unknown argument'));
    });

    test('--dry-run validates and reports without building', () {
      final out = Directory.systemTemp.createTempSync('axiotask_debdry_');
      addTearDown(() => out.deleteSync(recursive: true));
      final r = _runScript(['--dry-run', '--out', out.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stderr as String, contains('DRY RUN OK'));
      expect(
        out.listSync(),
        isEmpty,
        reason: 'a dry run must not write a package',
      );
    });
  });
}
