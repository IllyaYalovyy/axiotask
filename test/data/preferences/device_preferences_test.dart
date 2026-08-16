import 'dart:async';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/preferences/device_preferences.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device adapter supplies typed defaults and reactive updates', () async {
    final backend = InMemoryDevicePreferencesBackend();
    final diagnostics = InMemoryDiagnosticHistory();
    final adapter = DevicePreferencesAdapter(
      backend: backend,
      namespace: 'synthetic-device',
      diagnostics: ProductionDiagnosticSink(diagnostics),
    );
    addTearDown(adapter.close);
    final values = StreamIterator<DevicePreferences>(adapter.watch());
    addTearDown(values.cancel);

    expect(await values.moveNext(), isTrue);
    expect(values.current, const DevicePreferences.defaults());

    expect(await adapter.setTheme(ThemePreference.dark), isA<Success<void>>());
    expect(await values.moveNext(), isTrue);
    expect(values.current.theme, ThemePreference.dark);

    expect(
      await adapter.setDensity(DensityPreference.compact),
      isA<Success<void>>(),
    );
    expect(await values.moveNext(), isTrue);
    expect(values.current.density, DensityPreference.compact);

    expect(await adapter.setOnboardingDismissed(true), isA<Success<void>>());
    expect(await values.moveNext(), isTrue);
    expect(values.current.onboardingDismissed, isTrue);
    expect(
      await adapter.watch().first,
      const DevicePreferences(
        theme: ThemePreference.dark,
        density: DensityPreference.compact,
        onboardingDismissed: true,
      ),
    );
    expect(diagnostics.records, isEmpty);
  });

  test(
    'device values survive adapter restart within their namespace',
    () async {
      final backend = InMemoryDevicePreferencesBackend();
      final diagnostics = ProductionDiagnosticSink(InMemoryDiagnosticHistory());
      var adapter = DevicePreferencesAdapter(
        backend: backend,
        namespace: 'isolated-synthetic',
        diagnostics: diagnostics,
      );
      await adapter.setTheme(ThemePreference.light);
      await adapter.setDensity(DensityPreference.compact);
      await adapter.setOnboardingDismissed(true);
      await adapter.close();

      adapter = DevicePreferencesAdapter(
        backend: backend,
        namespace: 'isolated-synthetic',
        diagnostics: diagnostics,
      );
      addTearDown(adapter.close);

      expect(
        await adapter.watch().first,
        const DevicePreferences(
          theme: ThemePreference.light,
          density: DensityPreference.compact,
          onboardingDismissed: true,
        ),
      );
      final otherNamespace = DevicePreferencesAdapter(
        backend: backend,
        namespace: 'normal-instance',
        diagnostics: diagnostics,
      );
      addTearDown(otherNamespace.close);
      expect(
        await otherNamespace.watch().first,
        const DevicePreferences.defaults(),
      );
    },
  );

  test(
    'malformed values are removed, defaulted, and diagnosed safely',
    () async {
      final backend = InMemoryDevicePreferencesBackend(
        initialValues: <String, Object>{
          'synthetic-malformed.theme': 'sepia',
          'synthetic-malformed.density': 42,
          'synthetic-malformed.onboarding_dismissed': 'yes',
        },
      );
      final history = InMemoryDiagnosticHistory();
      final adapter = DevicePreferencesAdapter(
        backend: backend,
        namespace: 'synthetic-malformed',
        diagnostics: ProductionDiagnosticSink(history),
      );
      addTearDown(adapter.close);

      expect(await adapter.watch().first, const DevicePreferences.defaults());
      expect(backend.values, isEmpty);
      expect(history.records, hasLength(3));
      for (final record in history.records) {
        expect(record.code, 'preferences.device_value_defaulted');
        expect(
          record.fields.keys,
          containsAll(<String>['preference', 'reason']),
        );
        expect(record.renderedText, isNot(contains('sepia')));
        expect(record.renderedText, isNot(contains('42')));
        expect(record.renderedText, isNot(contains('yes')));
      }
    },
  );

  test('write failure preserves the prior value and emits no update', () async {
    final backend = InMemoryDevicePreferencesBackend();
    final history = InMemoryDiagnosticHistory();
    final adapter = DevicePreferencesAdapter(
      backend: backend,
      namespace: 'synthetic-write-failure',
      diagnostics: ProductionDiagnosticSink(history),
    );
    addTearDown(adapter.close);
    expect(await adapter.watch().first, const DevicePreferences.defaults());
    backend.failWrites = true;

    final result = await adapter.setTheme(ThemePreference.dark);

    expect(result, isA<Failed<void>>());
    expect(await adapter.watch().first, const DevicePreferences.defaults());
    expect(history.records.single.code, 'preferences.device_write_failed');
  });

  test('device namespace must be explicit', () {
    expect(
      () => DevicePreferencesAdapter(
        backend: InMemoryDevicePreferencesBackend(),
        namespace: '',
        diagnostics: ProductionDiagnosticSink(InMemoryDiagnosticHistory()),
      ),
      throwsArgumentError,
    );
  });
}
