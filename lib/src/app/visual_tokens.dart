import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../domain/model/preferences.dart';

final class AxiotaskVisualTokens extends ThemeExtension<AxiotaskVisualTokens> {
  const AxiotaskVisualTokens({
    required this.headerHeight,
    required this.controlHeight,
    required this.iconSize,
    required this.controlRadius,
    required this.horizontalInset,
    required this.sectionGap,
    required this.hoverColor,
    required this.focusColor,
  });

  final double headerHeight;
  final double controlHeight;
  final double iconSize;
  final double controlRadius;
  final double horizontalInset;
  final double sectionGap;
  final Color hoverColor;
  final Color focusColor;

  /// The desktop rhythm is a 4dp scale: 4, 8, 12, 16, and 24.
  ///
  /// Standard is the normal desktop layout. Compact only tightens spacing and
  /// controls; it never reduces the readable body type scale. Mobile keeps
  /// Material touch targets regardless of the selected desktop density.
  static AxiotaskVisualTokens fromDensity(
    DensityPreference density, {
    required ColorScheme colors,
    required bool desktop,
  }) {
    final focus = colors.primary.withValues(alpha: 0.24);
    final hover = colors.onSurface.withValues(alpha: 0.08);
    if (!desktop) {
      return AxiotaskVisualTokens(
        headerHeight: 64,
        controlHeight: 48,
        iconSize: 24,
        controlRadius: 12,
        horizontalInset: 20,
        sectionGap: 16,
        hoverColor: hover,
        focusColor: focus,
      );
    }
    return switch (density) {
      DensityPreference.standard => AxiotaskVisualTokens(
        headerHeight: 48,
        controlHeight: 40,
        iconSize: 20,
        controlRadius: 8,
        horizontalInset: 16,
        sectionGap: 12,
        hoverColor: hover,
        focusColor: focus,
      ),
      DensityPreference.compact => AxiotaskVisualTokens(
        headerHeight: 44,
        controlHeight: 36,
        iconSize: 20,
        controlRadius: 8,
        horizontalInset: 12,
        sectionGap: 8,
        hoverColor: hover,
        focusColor: focus,
      ),
    };
  }

  @override
  AxiotaskVisualTokens copyWith({
    double? headerHeight,
    double? controlHeight,
    double? iconSize,
    double? controlRadius,
    double? horizontalInset,
    double? sectionGap,
    Color? hoverColor,
    Color? focusColor,
  }) => AxiotaskVisualTokens(
    headerHeight: headerHeight ?? this.headerHeight,
    controlHeight: controlHeight ?? this.controlHeight,
    iconSize: iconSize ?? this.iconSize,
    controlRadius: controlRadius ?? this.controlRadius,
    horizontalInset: horizontalInset ?? this.horizontalInset,
    sectionGap: sectionGap ?? this.sectionGap,
    hoverColor: hoverColor ?? this.hoverColor,
    focusColor: focusColor ?? this.focusColor,
  );

  @override
  AxiotaskVisualTokens lerp(AxiotaskVisualTokens? other, double t) {
    if (other == null) return this;
    return AxiotaskVisualTokens(
      headerHeight: lerpDouble(headerHeight, other.headerHeight, t)!,
      controlHeight: lerpDouble(controlHeight, other.controlHeight, t)!,
      iconSize: lerpDouble(iconSize, other.iconSize, t)!,
      controlRadius: lerpDouble(controlRadius, other.controlRadius, t)!,
      horizontalInset: lerpDouble(horizontalInset, other.horizontalInset, t)!,
      sectionGap: lerpDouble(sectionGap, other.sectionGap, t)!,
      hoverColor: Color.lerp(hoverColor, other.hoverColor, t)!,
      focusColor: Color.lerp(focusColor, other.focusColor, t)!,
    );
  }
}

ThemeData axiotaskTheme(
  Brightness brightness,
  DensityPreference density, {
  String? fontFamily,
  TargetPlatform? platform,
}) {
  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final desktop = resolvedPlatform == TargetPlatform.linux;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff315da8),
    brightness: brightness,
  );
  final tokens = AxiotaskVisualTokens.fromDensity(
    density,
    colors: scheme,
    desktop: desktop,
  );
  final controlStyle = _desktopControlStyle(tokens);
  return ThemeData(
    brightness: brightness,
    fontFamily: fontFamily,
    platform: resolvedPlatform,
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: desktop
        ? switch (density) {
            DensityPreference.standard => VisualDensity.standard,
            DensityPreference.compact => VisualDensity.compact,
          }
        : VisualDensity.standard,
    appBarTheme: AppBarTheme(
      toolbarHeight: tokens.headerHeight,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      space: 1,
      thickness: 1,
    ),
    iconButtonTheme: desktop ? IconButtonThemeData(style: controlStyle) : null,
    filledButtonTheme: desktop
        ? FilledButtonThemeData(style: controlStyle)
        : null,
    outlinedButtonTheme: desktop
        ? OutlinedButtonThemeData(style: controlStyle)
        : null,
    textButtonTheme: desktop ? TextButtonThemeData(style: controlStyle) : null,
    inputDecorationTheme: desktop
        ? InputDecorationTheme(
            isDense: true,
            constraints: BoxConstraints(minHeight: tokens.controlHeight),
            contentPadding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: density == DensityPreference.standard ? 10 : 8,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(tokens.controlRadius),
            ),
          )
        : null,
    extensions: <ThemeExtension<dynamic>>[tokens],
  );
}

ButtonStyle _desktopControlStyle(AxiotaskVisualTokens tokens) => ButtonStyle(
  minimumSize: WidgetStatePropertyAll<Size>(
    Size(tokens.controlHeight, tokens.controlHeight),
  ),
  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
    EdgeInsets.symmetric(horizontal: 12),
  ),
  iconSize: WidgetStatePropertyAll<double>(tokens.iconSize),
  shape: WidgetStatePropertyAll<OutlinedBorder>(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.controlRadius),
    ),
  ),
  overlayColor: WidgetStateProperty.resolveWith<Color?>((states) {
    if (states.contains(WidgetState.focused)) return tokens.focusColor;
    if (states.contains(WidgetState.hovered)) return tokens.hoverColor;
    return null;
  }),
);

extension AxiotaskThemeData on ThemeData {
  AxiotaskVisualTokens get axiotaskTokens =>
      extension<AxiotaskVisualTokens>() ??
      AxiotaskVisualTokens.fromDensity(
        DensityPreference.standard,
        colors: colorScheme,
        desktop: platform == TargetPlatform.linux,
      );
}
