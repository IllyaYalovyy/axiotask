import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads every font declared in the app's `FontManifest.json` into the test
/// binding so widget and golden tests render real glyphs instead of the
/// default test font's uniform boxes.
///
/// Called once for the whole suite from `flutter_test_config.dart`. Returns the
/// set of font families that were registered, so a test can assert the harness
/// actually loaded them (an empty result means the manifest was missing or
/// unparsed — a silent regression that would otherwise only surface as ugly
/// goldens).
Future<Set<String>> loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manifestString = await rootBundle.loadString('FontManifest.json');
  final manifest = json.decode(manifestString) as List<dynamic>;

  final loaded = <String>{};
  for (final dynamic rawEntry in manifest) {
    final entry = rawEntry as Map<String, dynamic>;
    final family = entry['family'] as String;
    final fonts = entry['fonts'] as List<dynamic>;

    final loader = FontLoader(family);
    for (final dynamic rawFont in fonts) {
      final asset = (rawFont as Map<String, dynamic>)['asset'] as String;
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
    loaded.add(family);
  }
  return loaded;
}
