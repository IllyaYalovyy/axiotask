import 'dart:io';

import 'package:axiotask/src/app/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appVersion mirrors the pubspec release version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+\d+',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(declared, isNotNull, reason: 'pubspec.yaml must declare X.Y.Z+B');
    expect(
      appVersion,
      declared,
      reason:
          'lib/src/app/app_version.dart must be bumped together with '
          'pubspec.yaml as part of the same release bump — the About tab '
          'shows appVersion, while releases tag the pubspec version',
    );
  });
}
