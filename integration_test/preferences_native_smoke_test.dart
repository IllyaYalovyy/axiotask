import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('namespaced device preferences persist through native adapter', (
    _,
  ) async {
    const namespace = 'axiotask-isolated-s22a-native-smoke';
    final backend = SharedPreferencesAsyncBackend();
    final keys = <String>[
      '$namespace.theme',
      '$namespace.density',
      '$namespace.onboarding_dismissed',
    ];
    Future<void> cleanUp() async {
      for (final key in keys) {
        await backend.remove(key);
      }
    }

    await cleanUp();
    addTearDown(cleanUp);
    final diagnostics = ProductionDiagnosticSink(InMemoryDiagnosticHistory());
    var adapter = DevicePreferencesAdapter(
      backend: backend,
      namespace: namespace,
      diagnostics: diagnostics,
    );
    expect(await adapter.watch().first, const DevicePreferences.defaults());
    expect(await adapter.setTheme(ThemePreference.dark), isA<Success<void>>());
    expect(
      await adapter.setDensity(DensityPreference.compact),
      isA<Success<void>>(),
    );
    expect(await adapter.setOnboardingDismissed(true), isA<Success<void>>());
    await adapter.close();

    adapter = DevicePreferencesAdapter(
      backend: SharedPreferencesAsyncBackend(),
      namespace: namespace,
      diagnostics: diagnostics,
    );
    addTearDown(adapter.close);

    expect(
      await adapter.watch().first,
      const DevicePreferences(
        theme: ThemePreference.dark,
        density: DensityPreference.compact,
        onboardingDismissed: true,
      ),
    );
  });
}
