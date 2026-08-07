// Protects the theme-pref → ThemeMode mapping and the light/dark brightness of
// the two built themes. The non-happy path: an unrecognized theme string must
// resolve to system, not throw or blank the app.

import 'package:axiotask/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('themeModeFromString', () {
    test('maps the three explicit prefs', () {
      expect(themeModeFromString('light'), ThemeMode.light);
      expect(themeModeFromString('dark'), ThemeMode.dark);
      expect(themeModeFromString('system'), ThemeMode.system);
    });

    test('an unknown value falls back to system', () {
      // A hand-edited or newer prefs file must never leave the app themeless.
      expect(themeModeFromString('solarized'), ThemeMode.system);
      expect(themeModeFromString(''), ThemeMode.system);
    });
  });

  group('themes', () {
    test('light and dark carry the matching brightness', () {
      expect(buildLightTheme().brightness, Brightness.light);
      expect(buildDarkTheme().brightness, Brightness.dark);
    });

    test('both themes are Material 3', () {
      expect(buildLightTheme().useMaterial3, isTrue);
      expect(buildDarkTheme().useMaterial3, isTrue);
    });
  });
}
