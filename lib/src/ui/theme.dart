// App theming — the Material 3 light/dark themes and the pref→ThemeMode map.
//
// The visual design is fresh (Q3 ruling): a Material 3 foundation seeded from
// one brand color, not a pixel port of the Tauri look. Both brightnesses are
// built from the SAME seed so light and dark stay in the same family. The
// `theme` pref ('system' | 'light' | 'dark') selects between them; an
// unrecognized value falls back to 'system' so a hand-edited or newer prefs
// file never leaves the app themeless.

import 'package:flutter/material.dart';

/// The brand seed color both themes are generated from.
const Color _seed = Colors.deepPurple;

/// The Material 3 light theme.
ThemeData buildLightTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _seed),
  useMaterial3: true,
);

/// The Material 3 dark theme (same seed, dark brightness).
ThemeData buildDarkTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
);

/// Map the persisted `theme` pref to a [ThemeMode]. Anything other than the two
/// explicit choices resolves to [ThemeMode.system] (the safe default that
/// follows the OS).
ThemeMode themeModeFromString(String theme) => switch (theme) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
