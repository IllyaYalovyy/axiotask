// One golden variant, not two (#275).
//
// alchemist ships two golden flavours per scenario: `goldens/<platform>/`, which
// renders real glyphs through the real theme, and `goldens/ci/`, which obscures
// every run of text into a solid block and drops shadows. Both were committed
// and both ran on every machine — 23 PNGs each. The `ci` set carries no signal
// this project can act on: the suite has one host platform, so the only thing
// the second set added was a second baseline to regenerate on every engine bump
// (#230) — and a blocked-text image cannot show a typography or layout
// regression in the first place.
//
// What this protects: the `ci` variant stays OFF and its baselines stay
// deleted, so a later `flutter test --update-goldens` cannot quietly resurrect
// the doubled set.
import 'dart:io';

import 'package:alchemist/alchemist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Read at DECLARATION time, not inside a test body: `flutter_test_config.dart`
  // installs the config as a zone value, and package:test runs each test body in
  // its own zone where that value is no longer visible. Declaration time is also
  // exactly when alchemist's `goldenTest` reads it (golden_test.dart:163), so
  // this is the same value every golden in the suite is built from.
  final config = AlchemistConfig.current();

  test('the suite renders exactly one golden variant: platform, not ci', () {
    expect(
      config.platformGoldensConfig.enabled,
      isTrue,
      reason:
          'the platform variant is the one with signal — it renders real '
          'glyphs and shadows',
    );
    expect(
      config.ciGoldensConfig.enabled,
      isFalse,
      reason:
          'the ci variant obscures text into blocks; it doubles the '
          'regeneration cost for no signal (#275)',
    );
  });

  test('no goldens/ci baseline survives anywhere under test/', () {
    final leftovers = Directory('test')
        .listSync(recursive: true, followLinks: false)
        .whereType<Directory>()
        .map((d) => d.path.replaceAll(r'\', '/'))
        .where((path) => path.endsWith('/goldens/ci'))
        .toList();

    expect(
      leftovers,
      isEmpty,
      reason:
          'the ci golden set was deleted in #275; these directories mean a '
          '--update-goldens run brought it back',
    );
  });
}
