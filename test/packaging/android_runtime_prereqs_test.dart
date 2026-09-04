// Android runtime prerequisites — the release APK must carry the two things a
// device needs that a green Dart gate can never prove (F2, #178/#179).
//
// What this protects (and the failures it prevents):
//   - NO NATIVE SQLITE: drift's NativeDatabase dlopen()s a libsqlite3 at
//     runtime. Android has no usable system sqlite for the plugin to load on
//     API 24+, so without `sqlite3_flutter_libs` bundling a copy the store
//     cannot open and the app dies on first launch. It must be a real runtime
//     dependency (not dev_dependencies), so it ships in the APK.
//   - NO NETWORK IN RELEASE: the INTERNET permission lives ONLY in the debug/
//     profile manifest overlays that Flutter ships by default. A release APK
//     merges only the main manifest — so without INTERNET declared there, sync
//     silently fails on a real (release) install while working in debug.
//   - AN EOL SQLITE PLUGIN: `sqlite3_flutter_libs` 0.6.0+eol is a tombstone
//     release that ships lib/ and nothing else — no android/ plugin, no native
//     .so. A routine `pub upgrade --major-versions` would take it, keep every
//     Dart test green (host tests link the system sqlite) and break the store
//     on device. The version is therefore pinned EXACTLY (#275).
//   - THE OS RESTORING A STALE DB: Android auto-backup would copy the SQLite
//     store off the device and replay it onto another one, resurrecting rows
//     the user deleted and etags/sync cursors that belong to a different
//     device's history (the failure #272 fixed by hand). Google is the source
//     of truth; the local store is a cache and must never be restored out of
//     band (#275).
//
// All four are build-config invariants, not runtime behaviour: they are asserted
// by reading the checked-in config files directly. The device dlopen itself can
// only be confirmed by a one-launch on-device check (a human ask in the report).
@Tags(['packaging'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sqlite3_flutter_libs runtime dependency (drift dlopen on device)', () {
    late List<String> pubspecLines;

    setUpAll(() {
      pubspecLines = File('pubspec.yaml').readAsLinesSync();
    });

    test('declared under dependencies:, not dev_dependencies:', () {
      // Find the section boundaries so we assert the dep is in the SHIPPED set.
      final depsStart = pubspecLines.indexWhere(
        (l) => l.trimRight() == 'dependencies:',
      );
      final devDepsStart = pubspecLines.indexWhere(
        (l) => l.trimRight() == 'dev_dependencies:',
      );
      expect(depsStart, isNonNegative, reason: 'dependencies: section missing');
      expect(
        devDepsStart,
        greaterThan(depsStart),
        reason: 'dev_dependencies: expected after dependencies:',
      );

      final declaration = pubspecLines.indexWhere(
        (l) => l.trimLeft().startsWith('sqlite3_flutter_libs:'),
      );
      expect(
        declaration,
        isNonNegative,
        reason: 'sqlite3_flutter_libs not declared in pubspec.yaml',
      );
      expect(
        declaration,
        inInclusiveRange(depsStart + 1, devDepsStart - 1),
        reason:
            'sqlite3_flutter_libs must be a runtime dep so it ships in the '
            'APK — declaring it under dev_dependencies would not.',
      );
    });

    test('resolves to a concrete version in pubspec.lock', () {
      final lock = File('pubspec.lock').readAsStringSync();
      expect(
        lock,
        contains('sqlite3_flutter_libs'),
        reason: 'run `flutter pub get` so the dependency is locked',
      );
    });

    test('is pinned to an exact version, not a caret/range constraint', () {
      final constraint = _declaredConstraint(pubspecLines);
      expect(
        constraint,
        matches(RegExp(r'^\d+\.\d+\.\d+$')),
        reason:
            'a caret range lets `pub upgrade` slide onto 0.6.0+eol, which '
            'ships no android/ plugin at all — pin the exact version and '
            'move it deliberately (#275).',
      );
    });

    test('the pinned version is not the +eol tombstone release', () {
      expect(
        _lockedVersion(),
        isNot(contains('+eol')),
        reason:
            'sqlite3_flutter_libs 0.6.0+eol is "not used anymore" upstream: '
            'it removes the native libraries the app dlopen()s on device.',
      );
    });

    // Non-happy path in substance: this is the assertion that actually fires if
    // the pin is ever moved onto a release that dropped the native plugin. The
    // constraint text alone would not — 0.6.0+eol is a perfectly well-formed
    // exact version; what makes it fatal is the missing android/ directory.
    test('the resolved package still ships the native android/ plugin', () {
      final root = _resolvedPackageRoot('sqlite3_flutter_libs');
      expect(
        Directory(p.join(root, 'android')).existsSync(),
        isTrue,
        reason:
            'the resolved sqlite3_flutter_libs at $root has no android/ '
            'directory, so no libsqlite3.so is packaged into the APK and '
            "drift's NativeDatabase cannot open the store on device.",
      );
    });
  });

  group('INTERNET permission in the release (main) manifest', () {
    test('android/app/src/main/AndroidManifest.xml declares it', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.INTERNET"/>',
        ),
        reason:
            'release APKs merge only the main manifest; INTERNET only in '
            'the debug/profile overlays means no network in release.',
      );
    });
  });

  group('the local store is never carried between devices by the OS (#275)', () {
    late String manifest;

    setUpAll(() {
      manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
    });

    test('auto-backup is off', () {
      expect(
        manifest,
        contains('android:allowBackup="false"'),
        reason:
            'with the platform default (true) Android copies the SQLite store '
            'to the cloud and replays it onto the next device, restoring rows '
            'the user deleted and sync state from another device (#272).',
      );
    });

    test('device-to-device transfer is refused too', () {
      // allowBackup="false" alone does NOT stop Android 12+ device-to-device
      // transfer: that path is governed by dataExtractionRules, and its default
      // is to include everything.
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
        reason:
            'allowBackup only governs cloud backup; D2D transfer on Android '
            '12+ needs an explicit dataExtractionRules resource.',
      );
    });

    test('the rules resource exists and excludes every app data root', () {
      final rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      );
      expect(
        rules.existsSync(),
        isTrue,
        reason:
            'the manifest points at @xml/data_extraction_rules; a missing '
            'resource fails the Android build, not the Dart gate.',
      );
      final xml = rules.readAsStringSync();
      for (final domain in ['file', 'database', 'sharedpref', 'external']) {
        expect(
          xml,
          contains('domain="$domain"'),
          reason:
              'every data domain must be excluded from both cloud-backup and '
              'device-transfer; $domain is not.',
        );
      }
      expect(xml, contains('<cloud-backup>'));
      expect(xml, contains('<device-transfer>'));
    });
  });
}

/// The version constraint `pubspec.yaml` declares for sqlite3_flutter_libs.
String _declaredConstraint(List<String> pubspecLines) {
  final line = pubspecLines.firstWhere(
    (l) => l.trimLeft().startsWith('sqlite3_flutter_libs:'),
    orElse: () => '',
  );
  return line.split(':').skip(1).join(':').trim().replaceAll('"', '');
}

/// The version `pubspec.lock` actually resolved sqlite3_flutter_libs to.
String _lockedVersion() {
  final lines = File('pubspec.lock').readAsLinesSync();
  final start = lines.indexWhere(
    (l) => l.trimRight() == '  sqlite3_flutter_libs:',
  );
  expect(start, isNonNegative, reason: 'sqlite3_flutter_libs is not locked');
  final versionLine = lines
      .skip(start)
      .take(12)
      .firstWhere((l) => l.trimLeft().startsWith('version:'));
  return versionLine.split(':').last.trim().replaceAll('"', '');
}

/// Where `pub get` put a package on this machine — read from the resolution
/// pub itself wrote, so the assertion follows the pin rather than a guess at
/// the pub-cache layout.
String _resolvedPackageRoot(String name) {
  final config =
      json.decode(File('.dart_tool/package_config.json').readAsStringSync())
          as Map<String, dynamic>;
  final entry = (config['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .firstWhere(
        (p) => p['name'] == name,
        orElse: () => throw StateError('$name not in package_config.json'),
      );
  return File.fromUri(Uri.parse(entry['rootUri'] as String)).path;
}
