// Distribution layer — what a Linux user actually receives (#226).
//
// What this protects (and the failures it prevents):
//   - NO APPSTREAM METADATA: without a metainfo file GNOME Software / KDE
//     Discover show the app as an unnamed, undescribed binary (or not at all).
//     The file must be VALID (appstreamcli), its filename must match the
//     component id, and its <release> version must track pubspec — a stale
//     release entry advertises the wrong version in every software centre.
//   - WINDOW/ICON DIVORCE: the runner calls g_set_prgname(APPLICATION_ID), so
//     the window's WM_CLASS / Wayland app_id is the CMake APPLICATION_ID, not
//     the binary name. A .desktop whose StartupWMClass says otherwise leaves
//     the running window with a generic icon in the dash and alt-tab.
//   - MENU DUPLICATES: two main freedesktop categories can list the app twice.
//     desktop-file-validate must be clean of errors, warnings AND hints.
//   - NOTHING TO RUN FOR A NON-RPM INSTALL: tool/install.sh is the user-local
//     path. It must lay out bundle/launcher/desktop/icons/metainfo so the entry
//     resolves, upgrade in place on re-run, reverse itself on --uninstall, and
//     — the part that would be unforgivable — NEVER touch the user's data dirs
//     (`~/.local/share/axiotask*`, `~/.config/axiotask*`), which live next door
//     to the install locations.
//
// Everything here is checked-in state plus a script run against a THROWAWAY
// $HOME (HOME/XDG_* are overridden for every child process), so no clock, no
// network, and no real home directory is ever touched.
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:axiotask/src/ui/views.dart';
import 'package:flutter_test/flutter_test.dart';

/// The AppStream component id. rDNS over the project's real home,
/// github.com/IllyaYalovyy/axiotask → io.github.illyayalovyy.axiotask.
const _appId = 'io.github.illyayalovyy.axiotask';
const _metainfoPath = 'linux/packaging/$_appId.metainfo.xml';
const _desktopPath = 'linux/packaging/axiotask.desktop';
const _hicolorSizes = <int>[16, 24, 32, 48, 64, 128, 256, 512];

String _pubspecVersion() {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

/// Value of a `Key=Value` line in the desktop entry.
String? _desktopValue(String key) {
  for (final l in File(_desktopPath).readAsLinesSync()) {
    if (l.startsWith('$key=')) return l.substring(key.length + 1).trim();
  }
  return null;
}

void main() {
  group('AppStream metainfo', () {
    late String xml;

    setUpAll(() {
      xml = File(_metainfoPath).readAsStringSync();
    });

    test('component id matches the file name (software centres key on it)', () {
      expect(File(_metainfoPath).existsSync(), isTrue);
      expect(xml, contains('<id>$_appId</id>'));
    });

    test('appstreamcli validate passes', () {
      if (Process.runSync('which', ['appstreamcli']).exitCode != 0) {
        markTestSkipped(
          'appstreamcli missing on this host — OPERATOR CHECK REQUIRED: '
          'run `appstreamcli validate --no-net $_metainfoPath`',
        );
        return;
      }
      final r = Process.runSync('appstreamcli', [
        'validate',
        '--no-net',
        _metainfoPath,
      ]);
      expect(
        r.exitCode,
        0,
        reason: 'appstreamcli validate failed:\n${r.stdout}\n${r.stderr}',
      );
    });

    test('<release> version tracks pubspec (no stale advertised version)', () {
      expect(xml, contains('version="${_pubspecVersion()}"'));
    });

    test('launchable points at the shipped desktop entry', () {
      expect(
        xml,
        contains('<launchable type="desktop-id">axiotask.desktop</launchable>'),
      );
      expect(File(_desktopPath).existsSync(), isTrue);
    });

    // A software-centre listing that advertises features under names the app
    // does not use sends the user hunting for a "Today" view that is called
    // Focus. Renaming a smart view must break this test.
    test('the listing names the app\'s real smart views', () {
      for (final v in SmartView.values.where((v) => v != SmartView.all)) {
        expect(
          xml,
          contains(v.label),
          reason: 'the description must name the ${v.id} view as "${v.label}"',
        );
      }
    });

    test('declares the repository license and project home', () {
      expect(xml, contains('<project_license>GPL-3.0-or-later'));
      expect(xml, contains('https://github.com/IllyaYalovyy/axiotask'));
    });
  });

  group('.desktop hygiene', () {
    test('desktop-file-validate is clean (no errors, warnings or hints)', () {
      if (Process.runSync('which', ['desktop-file-validate']).exitCode != 0) {
        markTestSkipped(
          'desktop-file-validate missing — OPERATOR CHECK REQUIRED: '
          'run `desktop-file-validate $_desktopPath`',
        );
        return;
      }
      final r = Process.runSync('desktop-file-validate', [_desktopPath]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        '${r.stdout}${r.stderr}'.trim(),
        isEmpty,
        reason: 'validator emitted diagnostics: ${r.stdout}${r.stderr}',
      );
    });

    test('StartupWMClass equals the GTK application id the runner sets', () {
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();
      final appId = RegExp(
        r'set\(APPLICATION_ID "([^"]+)"\)',
      ).firstMatch(cmake)!.group(1);
      expect(
        _desktopValue('StartupWMClass'),
        appId,
        reason:
            'my_application.cc calls g_set_prgname(APPLICATION_ID); the window '
            'app_id is $appId, so StartupWMClass must be that or the running '
            'window shows a generic icon',
      );
    });

    test('Icon name resolves to a shipped hicolor icon', () {
      final icon = _desktopValue('Icon');
      expect(icon, 'axiotask');
      expect(
        File(
          'linux/packaging/icons/hicolor/128x128/apps/$icon.png',
        ).existsSync(),
        isTrue,
      );
    });
  });

  group('tool/install.sh (user-local, no sudo)', () {
    late Directory home;
    late Directory bundle;

    /// A throwaway $HOME plus the XDG roots that MUST be overridden as well —
    /// an inherited XDG_DATA_HOME would otherwise send the install into the
    /// operator's real home.
    Map<String, String> envFor(Directory h) => {
      'HOME': h.path,
      'XDG_DATA_HOME': '${h.path}/.local/share',
      'XDG_CONFIG_HOME': '${h.path}/.config',
    };

    /// Minimal stand-in for `flutter build linux --release` output.
    Directory makeBundle(String marker) {
      final d = Directory.systemTemp.createTempSync('axiotask_bundle_');
      File('${d.path}/axiotask')
        ..writeAsStringSync('#!/bin/sh\necho $marker\n')
        ..setLastModifiedSync(DateTime(2024));
      Process.runSync('chmod', ['+x', '${d.path}/axiotask']);
      Directory('${d.path}/lib').createSync();
      File('${d.path}/lib/libapp.so').writeAsStringSync(marker);
      Directory('${d.path}/data/flutter_assets').createSync(recursive: true);
      File(
        '${d.path}/data/flutter_assets/AssetManifest.json',
      ).writeAsStringSync('{}');
      return d;
    }

    ProcessResult run(List<String> args, {Directory? h}) => Process.runSync(
      'bash',
      ['tool/install.sh', ...args],
      environment: envFor(h ?? home),
    );

    setUp(() {
      home = Directory.systemTemp.createTempSync('axiotask_home_');
      bundle = makeBundle('v1');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
      if (bundle.existsSync()) bundle.deleteSync(recursive: true);
    });

    test('installs a launchable layout under the user home', () {
      final r = run(['--bundle', bundle.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      final exe = File('${home.path}/.local/lib/axiotask/axiotask');
      expect(exe.existsSync(), isTrue, reason: 'bundle binary not installed');
      expect(
        File('${home.path}/.local/lib/axiotask/lib/libapp.so').existsSync(),
        isTrue,
        reason: 'the whole bundle tree must be installed, not just the binary',
      );

      final link = Link('${home.path}/.local/bin/axiotask');
      expect(
        link.existsSync(),
        isTrue,
        reason: '~/.local/bin launcher missing',
      );
      expect(File(link.resolveSymbolicLinksSync()).path, exe.path);

      final desktop = File(
        '${home.path}/.local/share/applications/axiotask.desktop',
      );
      expect(desktop.existsSync(), isTrue);
      final lines = desktop.readAsLinesSync();
      final exec = lines
          .firstWhere((l) => l.startsWith('Exec='))
          .substring(5)
          .split(' ')
          .first;
      expect(
        File(exec).existsSync() || Link(exec).existsSync(),
        isTrue,
        reason: 'Exec=$exec does not resolve to an installed file',
      );
      expect(
        lines.any((l) => l == 'Icon=axiotask'),
        isTrue,
        reason:
            'Icon= must stay a theme name so the installed hicolor tree wins',
      );

      for (final s in _hicolorSizes) {
        expect(
          File(
            '${home.path}/.local/share/icons/hicolor/${s}x$s/apps/axiotask.png',
          ).existsSync(),
          isTrue,
          reason: 'hicolor ${s}x$s icon missing',
        );
      }
      expect(
        File(
          '${home.path}/.local/share/icons/hicolor/scalable/apps/axiotask.svg',
        ).existsSync(),
        isTrue,
      );
      final metainfo = File(
        '${home.path}/.local/share/metainfo/$_appId.metainfo.xml',
      );
      expect(
        metainfo.existsSync(),
        isTrue,
        reason: 'AppStream metainfo must be installed for software centres',
      );

      // The installed entry is not the repo file: install.sh rewrites Exec= to
      // the absolute launcher path. Re-validate what actually landed.
      if (Process.runSync('which', ['desktop-file-validate']).exitCode == 0) {
        final v = Process.runSync('desktop-file-validate', [desktop.path]);
        expect(v.exitCode, 0, reason: '${v.stdout}${v.stderr}');
        expect('${v.stdout}${v.stderr}'.trim(), isEmpty);
      }
      if (Process.runSync('which', ['appstreamcli']).exitCode == 0) {
        final v = Process.runSync('appstreamcli', [
          'validate',
          '--no-net',
          metainfo.path,
        ]);
        expect(v.exitCode, 0, reason: '${v.stdout}${v.stderr}');
      }
    });

    test('re-run upgrades in place and drops files the new bundle lost', () {
      expect(run(['--bundle', bundle.path]).exitCode, 0);
      final installed = File('${home.path}/.local/lib/axiotask/lib/libapp.so');
      expect(installed.readAsStringSync(), 'v1');
      // A plugin library only the OLD bundle had: after the upgrade it must be
      // gone, not left behind next to the new one.
      final orphan = File('${home.path}/.local/lib/axiotask/lib/libgone.so')
        ..writeAsStringSync('old plugin');

      final next = makeBundle('v2');
      final r = run(['--bundle', next.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(
        installed.readAsStringSync(),
        'v2',
        reason: 'upgrade left old bytes in place',
      );
      expect(
        orphan.existsSync(),
        isFalse,
        reason: 'upgrade must replace the program directory wholesale',
      );
      expect(
        File(
          '${home.path}/.local/lib/axiotask/data/flutter_assets/AssetManifest.json',
        ).existsSync(),
        isTrue,
      );
      expect(
        Link('${home.path}/.local/bin/axiotask').existsSync(),
        isTrue,
        reason: 'the launcher symlink must survive an upgrade',
      );
      next.deleteSync(recursive: true);
    });

    test('--uninstall removes everything it installed', () {
      expect(run(['--bundle', bundle.path]).exitCode, 0);
      final r = run(['--uninstall']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      expect(
        Directory('${home.path}/.local/lib/axiotask').existsSync(),
        isFalse,
      );
      expect(Link('${home.path}/.local/bin/axiotask').existsSync(), isFalse);
      expect(
        File(
          '${home.path}/.local/share/applications/axiotask.desktop',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${home.path}/.local/share/metainfo/$_appId.metainfo.xml',
        ).existsSync(),
        isFalse,
      );
      for (final s in _hicolorSizes) {
        expect(
          File(
            '${home.path}/.local/share/icons/hicolor/${s}x$s/apps/axiotask.png',
          ).existsSync(),
          isFalse,
          reason: 'hicolor ${s}x$s icon left behind',
        );
      }
    });

    // The unforgivable failure: the install/uninstall paths sit right next to
    // the app's XDG data dirs. Neither may ever touch user data.
    test('install and uninstall never touch axiotask data/config dirs', () {
      final data = Directory('${home.path}/.local/share/axiotask')
        ..createSync(recursive: true);
      final devData = Directory('${home.path}/.local/share/axiotask-dev')
        ..createSync(recursive: true);
      final config = Directory('${home.path}/.config/axiotask')
        ..createSync(recursive: true);
      final db = File('${data.path}/axiotask.sqlite')..writeAsStringSync('DB');
      final tokens = File('${data.path}/tokens.json')
        ..writeAsStringSync('{"refresh":"secret"}');
      final devDb = File('${devData.path}/axiotask.sqlite')
        ..writeAsStringSync('DEVDB');
      final cfg = File('${config.path}/config.json')..writeAsStringSync('{}');

      expect(run(['--bundle', bundle.path]).exitCode, 0);
      expect(db.readAsStringSync(), 'DB');
      expect(tokens.readAsStringSync(), '{"refresh":"secret"}');

      expect(run(['--uninstall']).exitCode, 0);
      expect(db.existsSync(), isTrue, reason: 'uninstall deleted the database');
      expect(db.readAsStringSync(), 'DB');
      expect(tokens.readAsStringSync(), '{"refresh":"secret"}');
      expect(devDb.readAsStringSync(), 'DEVDB');
      expect(cfg.existsSync(), isTrue, reason: 'uninstall deleted the config');
      expect(
        data.existsSync() && devData.existsSync() && config.existsSync(),
        isTrue,
      );
    });

    test('--uninstall on a clean home succeeds (idempotent)', () {
      final r = run(['--uninstall']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });

    test('a missing bundle fails loudly instead of installing junk', () {
      final r = run(['--bundle', '${home.path}/nope']);
      expect(r.exitCode, isNot(0));
      expect('${r.stdout}${r.stderr}', contains('bundle'));
      expect(
        Directory('${home.path}/.local/lib/axiotask').existsSync(),
        isFalse,
        reason: 'a failed install must leave nothing behind',
      );
    });

    test('unknown argument is rejected', () {
      final r = run(['--bogus']);
      expect(r.exitCode, isNot(0));
      expect('${r.stdout}${r.stderr}', contains('unknown argument'));
    });
  });
}
