import 'dart:io';

import 'package:axiotask/src/app/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the About version is the pubspec version name', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .singleWhere((line) => line.startsWith('version:'));
    final name = line.substring('version:'.length).trim().split('+').first;
    expect(
      appVersion,
      name,
      reason:
          'Bump appVersion in lib/src/app/app_version.dart together with '
          'pubspec.yaml; the About screen shows it.',
    );
  });

  test('the support page is the project sponsorship page', () {
    expect(supportProjectUri.scheme, 'https');
    expect(supportProjectUri.host, 'github.com');
    expect(supportProjectUri.path, '/sponsors/IllyaYalovyy');
  });
}
