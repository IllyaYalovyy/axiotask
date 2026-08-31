// App theming — the Material 3 light/dark themes and the pref→ThemeMode map.
//
// The visual design is fresh (Q3 ruling): a Material 3 foundation seeded from
// one brand color, not a pixel port of the Tauri look. Both brightnesses are
// built from the SAME seed so light and dark stay in the same family. The
// `theme` pref ('system' | 'light' | 'dark') selects between them; an
// unrecognized value falls back to 'system' so a hand-edited or newer prefs
// file never leaves the app themeless.

import 'package:flutter/material.dart';

import 'date_format.dart';

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

/// The ONE urgency palette for a due date — the single place a [DueUrgency]
/// becomes a colour, shared by the task row's due badge, the Focus view's
/// "Overdue (N)" heading and the detail panel's Due field (#242). Three
/// surfaces, one vocabulary: a colour only ever means what it means here.
///
///   • overdue → [ColorScheme.error]: the only alarm tone in the app,
///   • today   → [ColorScheme.primary]: attention, NOT alarm. It has to be
///     told apart from `error` at a glance in BOTH brightnesses, which rules
///     out `tertiary` — with the deepPurple seed that role generates a
///     salmon/rose the dark scheme renders a hair from `error` (ΔE ≈ 15) and
///     the light scheme renders as a soft red, i.e. as a mild warning,
///   • future / no date → [ColorScheme.onSurfaceVariant]: muted. Nothing that
///     is not overdue ever carries a red tint.
///
/// Every colour here is asserted legible (≥ 4.5:1 on `surface`) and mutually
/// distinguishable (ΔE ≥ 25) in both themes by `test/ui/due_color_test.dart`.
Color dueColor(DueUrgency urgency, ColorScheme scheme) => switch (urgency) {
  DueUrgency.overdue => scheme.error,
  DueUrgency.today => scheme.primary,
  DueUrgency.none => scheme.onSurfaceVariant,
};

/// Whether [platform] is a touch-primary platform — a coarse pointer with no
/// hover and no secondary-tap (Android/iOS/Fuchsia). There the right-click
/// context menu is unreachable, so touch-only affordances render — the list
/// toolbar's "Select tasks" entry (#245), the swipe quick actions — while a
/// mouse platform (Linux/macOS/Windows) reaches the same functions by
/// right-click. It also picks the quick-date presentation: a bottom sheet under
/// a finger, an anchored menu on a mouse (#243). The choice is by pointer
/// capability, never window width — width only picks the layout (F16 #194).
/// Read from `Theme.of(context).platform` so it is overridable in tests and
/// follows the running platform in production.
bool coarsePointerPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => true,
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => false,
};
