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

  test('device density drives shared header tokens and Material density', () {
    final standard = axiotaskTheme(
      Brightness.light,
      DensityPreference.standard,
    );
    final compact = axiotaskTheme(Brightness.light, DensityPreference.compact);

    expect(standard.axiotaskTokens.headerHeight, 64);
    expect(compact.axiotaskTokens.headerHeight, 56);
    expect(standard.visualDensity, VisualDensity.standard);
    expect(compact.visualDensity, VisualDensity.compact);
  });
}

double _contrast(Color foreground, Color background) {
  final light = foreground.computeLuminance();
  final dark = background.computeLuminance();
  return (light > dark ? light + .05 : dark + .05) /
      (light > dark ? dark + .05 : light + .05);
}
