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
//
// Both are build-config invariants, not runtime behaviour: they are asserted by
// reading the checked-in config files directly. The device dlopen itself can
// only be confirmed by a one-launch on-device check (a human ask in the report).
@Tags(['packaging'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
