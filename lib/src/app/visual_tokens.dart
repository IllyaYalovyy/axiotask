import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../domain/model/preferences.dart';

final class AxiotaskVisualTokens extends ThemeExtension<AxiotaskVisualTokens> {
  const AxiotaskVisualTokens({
    required this.headerHeight,
    required this.horizontalInset,
    required this.sectionGap,
  });

  final double headerHeight;
  final double horizontalInset;
  final double sectionGap;

  static AxiotaskVisualTokens fromDensity(DensityPreference density) =>
      switch (density) {
        DensityPreference.standard => const AxiotaskVisualTokens(
          headerHeight: 64,
          horizontalInset: 20,
          sectionGap: 16,
        ),
        DensityPreference.compact => const AxiotaskVisualTokens(
          headerHeight: 56,
          horizontalInset: 16,
          sectionGap: 12,
        ),
      };

  @override
  AxiotaskVisualTokens copyWith({
    double? headerHeight,
    double? horizontalInset,
    double? sectionGap,
  }) => AxiotaskVisualTokens(
    headerHeight: headerHeight ?? this.headerHeight,
    horizontalInset: horizontalInset ?? this.horizontalInset,
    sectionGap: sectionGap ?? this.sectionGap,
  );

  @override
  AxiotaskVisualTokens lerp(AxiotaskVisualTokens? other, double t) {
    if (other == null) return this;
    return AxiotaskVisualTokens(
      headerHeight: lerpDouble(headerHeight, other.headerHeight, t)!,
      horizontalInset: lerpDouble(horizontalInset, other.horizontalInset, t)!,
      sectionGap: lerpDouble(sectionGap, other.sectionGap, t)!,
    );
  }
}

ThemeData axiotaskTheme(
  Brightness brightness,
  DensityPreference density, {
  String? fontFamily,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff315da8),
    brightness: brightness,
  );
  return ThemeData(
    brightness: brightness,
    fontFamily: fontFamily,
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: switch (density) {
      DensityPreference.standard => VisualDensity.standard,
      DensityPreference.compact => VisualDensity.compact,
    },
    extensions: <ThemeExtension<dynamic>>[
      AxiotaskVisualTokens.fromDensity(density),
    ],
  );
}

extension AxiotaskThemeData on ThemeData {
  AxiotaskVisualTokens get axiotaskTokens =>
      extension<AxiotaskVisualTokens>() ??
      AxiotaskVisualTokens.fromDensity(DensityPreference.standard);
}
