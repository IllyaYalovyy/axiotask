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
ThemeData buildLightTheme() =>
    _themeFrom(ColorScheme.fromSeed(seedColor: _seed));

/// The Material 3 dark theme (same seed, dark brightness).
ThemeData buildDarkTheme() => _themeFrom(
  ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
);

/// Both themes, from their scheme — including the component themes that carry
/// the app's CONTRAST contract (#247).
///
/// `ColorScheme.fromSeed` is generous with the `on*` text roles and careless
/// with everything else, so the two component defaults below are corrected
/// here rather than at each call site, and the third is pinned so a future
/// Material default cannot silently move it. Every value is measured against
/// the WCAG bar that applies to it by `test/ui/a11y_contrast_test.dart`.
ThemeData _themeFrom(ColorScheme scheme) => ThemeData(
  colorScheme: scheme,
  useMaterial3: true,
  // Dividers are STRUCTURE here, not decoration: the rule that fences the
  // detail overflow's Delete off from the safe actions (#246), the one between
  // the sidebar's smart views and its lists, the section rules in Properties.
  // M3 draws them in `outlineVariant` — 1.6:1 on the light page, 2.0:1 on the
  // dark one, a line a low-vision user does not see at all. `outline` is the
  // neighbouring role that clears 3:1 on every surface the app puts a divider
  // on. Set in both places because `Divider` reads the component theme while
  // older Material widgets still read [ThemeData.dividerColor].
  dividerColor: scheme.outline,
  dividerTheme: DividerThemeData(color: scheme.outline),
  // The phone's ONE creation affordance. M3 seeds the FAB `primaryContainer`,
  // which sits 1.2:1 from the light page: a 56dp shape with no discernible
  // edge, identifiable only by the glyph inside it. `primary` is the role that
  // says "the primary action" and clears 3:1 against the page in both themes.
  floatingActionButtonTheme: FloatingActionButtonThemeData(
    backgroundColor: scheme.primary,
    foregroundColor: scheme.onPrimary,
  ),
  checkboxTheme: CheckboxThemeData(side: _checkboxOutline(scheme)),
);

/// The outline of an UNCHECKED checkbox at rest — the only thing that says a
/// tickable box is there at all, and the app's densest control (every task row
/// carries one).
///
/// Same colour Material 3 resolves today (`onSurfaceVariant`, 8.9:1 / 10.9:1
/// on the page); pinning it makes the contrast this app's contract instead of
/// an unowned framework default that a future Material release can move under
/// us. Every other state resolves to `null` and therefore keeps the framework's
/// own value: the checked box is filled (no outline), and hover / focus /
/// press deliberately darken to `onSurface` — emphasis this must not flatten.
WidgetStateBorderSide _checkboxOutline(ColorScheme scheme) =>
    WidgetStateBorderSide.resolveWith((states) {
      const framework = {
        WidgetState.selected,
        WidgetState.disabled,
        WidgetState.error,
        WidgetState.hovered,
        WidgetState.focused,
        WidgetState.pressed,
      };
      if (states.any(framework.contains)) return null;
      return BorderSide(width: 2, color: scheme.onSurfaceVariant);
    });

/// The tone a COMPLETED task's title wears — in the list row and in the detail
/// panel's subtask list, so "done" looks the same in both places.
///
/// Quieter than an open task's title, but still READ. [ThemeData.disabledColor]
/// (`onSurface` at 38%) put it at 2.3:1 on the light page and 3.0:1 on the dark
/// one, under the 4.5:1 AA bar for body text — and a completed task is content
/// the user asked to see ("Show completed"), still tappable and still
/// un-completable, so 1.4.3's exemption for inactive controls does not cover
/// it. `onSurfaceVariant` is the M3 role for exactly this de-emphasis, and it
/// is what the search results already use for a completed hit.
Color completedTitleColor(ColorScheme scheme) => scheme.onSurfaceVariant;

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
