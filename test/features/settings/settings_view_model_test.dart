import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/features/settings/settings_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'settings_test_support.dart';

void main() {
  test('typed theme and density choices persist and survive restart', () async {
    final preferences = MemorySettingsPreferences(
      current: const DevicePreferences(
        theme: ThemePreference.dark,
        density: DensityPreference.compact,
        onboardingDismissed: true,
      ),
    );
    addTearDown(preferences.close);
    final viewModel = SettingsViewModel(preferences)..start();
    addTearDown(viewModel.dispose);
    await _settle();

    expect(viewModel.state.preferences.theme, ThemePreference.dark);
    expect(viewModel.state.preferences.density, DensityPreference.compact);

    await viewModel.setTheme(ThemePreference.light);
    await viewModel.setDensity(DensityPreference.standard);

    expect(preferences.themeWrites, <ThemePreference>[ThemePreference.light]);
    expect(preferences.densityWrites, <DensityPreference>[
      DensityPreference.standard,
    ]);
    expect(viewModel.state.preferences.theme, ThemePreference.light);
    expect(viewModel.state.preferences.density, DensityPreference.standard);

    final restarted = SettingsViewModel(preferences)..start();
    addTearDown(restarted.dispose);
    await _settle();
    expect(restarted.state.preferences.theme, ThemePreference.light);
    expect(restarted.state.preferences.density, DensityPreference.standard);
  });

  test(
    'failed write is safe, visible, logged, and does not block controls',
    () async {
      final history = InMemoryDiagnosticHistory();
      addTearDown(history.close);
      final preferences = MemorySettingsPreferences()
        ..failNextThemeWrite = true;
      addTearDown(preferences.close);
      final viewModel = SettingsViewModel(
        preferences,
        diagnostics: ProductionDiagnosticSink(history),
      )..start();
      addTearDown(viewModel.dispose);
      await _settle();

      await viewModel.setTheme(ThemePreference.dark);

      expect(viewModel.state.preferences.theme, ThemePreference.system);
      expect(viewModel.state.failureMessage, contains('could not be saved'));
      expect(viewModel.state.isSaving, isFalse);
      expect(history.records.single.code, 'settings.preference_write_failed');
      expect(history.records.single.fields, <String, String>{
        'preference': 'theme',
        'failure_code': 'synthetic.settings_write_failed',
      });

      await viewModel.setDensity(DensityPreference.compact);
      expect(viewModel.state.preferences.density, DensityPreference.compact);
      expect(viewModel.state.failureMessage, isNull);
    },
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
