import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PAR-UX-001 theme variants retain accessible foreground contrast', () {
    for (final brightness in Brightness.values) {
      final theme = axiotaskTheme(brightness, DensityPreference.standard);
      final scheme = theme.colorScheme;
      expect(
        _contrast(scheme.onSurface, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.onError, scheme.error),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.onSurfaceVariant, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('desktop density drives the documented compact control scale', () {
    final standard = axiotaskTheme(
      Brightness.light,
      DensityPreference.standard,
      platform: TargetPlatform.linux,
    );
    final compact = axiotaskTheme(
      Brightness.light,
      DensityPreference.compact,
      platform: TargetPlatform.linux,
    );

    expect(standard.axiotaskTokens.headerHeight, 48);
    expect(compact.axiotaskTokens.headerHeight, 44);
    expect(standard.axiotaskTokens.controlHeight, 40);
    expect(compact.axiotaskTokens.controlHeight, 36);
    expect(standard.axiotaskTokens.iconSize, 20);
    expect(compact.axiotaskTokens.iconSize, 20);
    expect(standard.axiotaskTokens.horizontalInset, 16);
    expect(compact.axiotaskTokens.horizontalInset, 12);
    expect(standard.axiotaskTokens.sectionGap, 12);
    expect(compact.axiotaskTokens.sectionGap, 8);
    expect(standard.axiotaskTokens.controlRadius, 8);
    expect(compact.axiotaskTokens.controlRadius, 8);
    expect(standard.visualDensity, VisualDensity.standard);
    expect(compact.visualDensity, VisualDensity.compact);
  });

  test(
    'desktop interaction states remain visible in light and dark themes',
    () {
      for (final brightness in Brightness.values) {
        final tokens = axiotaskTheme(
          brightness,
          DensityPreference.standard,
          platform: TargetPlatform.linux,
        ).axiotaskTokens;
        final style = axiotaskTheme(
          brightness,
          DensityPreference.standard,
          platform: TargetPlatform.linux,
        ).iconButtonTheme.style!;
        expect(tokens.hoverColor.a, greaterThan(0));
        expect(tokens.focusColor.a, greaterThan(0));
        expect(tokens.hoverColor, isNot(tokens.focusColor));
        expect(
          style.overlayColor!.resolve(<WidgetState>{WidgetState.hovered}),
          tokens.hoverColor,
        );
        expect(
          style.overlayColor!.resolve(<WidgetState>{WidgetState.focused}),
          tokens.focusColor,
        );
      }
    },
  );
}

double _contrast(Color foreground, Color background) {
  final light = foreground.computeLuminance();
  final dark = background.computeLuminance();
  return (light > dark ? light + .05 : dark + .05) /
      (light > dark ? dark + .05 : light + .05);
}
