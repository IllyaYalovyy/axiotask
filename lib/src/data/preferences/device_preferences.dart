import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/diagnostics/diagnostics.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';

abstract interface class DevicePreferencesBackend {
  Future<String?> readString(String key);

  Future<bool?> readBool(String key);

  Future<void> writeString(String key, String value);

  Future<void> writeBool(String key, bool value);

  Future<void> remove(String key);
}

final class SharedPreferencesAsyncBackend implements DevicePreferencesBackend {
  SharedPreferencesAsyncBackend([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> readString(String key) => _preferences.getString(key);

  @override
  Future<bool?> readBool(String key) => _preferences.getBool(key);

  @override
  Future<void> writeString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> writeBool(String key, bool value) =>
      _preferences.setBool(key, value);

  @override
  Future<void> remove(String key) => _preferences.remove(key);
}

final class InMemoryDevicePreferencesBackend
    implements DevicePreferencesBackend {
  InMemoryDevicePreferencesBackend({Map<String, Object>? initialValues})
    : _values = Map<String, Object>.of(
        initialValues ?? const <String, Object>{},
      );

  final Map<String, Object> _values;
  bool failWrites = false;
  int writeAttempts = 0;

  Map<String, Object> get values => Map<String, Object>.unmodifiable(_values);

  @override
  Future<String?> readString(String key) async {
    final value = _values[key];
    if (value == null || value is String) return value as String?;
    throw const DevicePreferenceMalformedValue();
  }

  @override
  Future<bool?> readBool(String key) async {
    final value = _values[key];
    if (value == null || value is bool) return value as bool?;
    throw const DevicePreferenceMalformedValue();
  }

  @override
  Future<void> writeString(String key, String value) async {
    writeAttempts += 1;
    if (failWrites) throw const DevicePreferenceBackendFailure();
    _values[key] = value;
  }

  @override
  Future<void> writeBool(String key, bool value) async {
    writeAttempts += 1;
    if (failWrites) throw const DevicePreferenceBackendFailure();
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    if (failWrites) throw const DevicePreferenceBackendFailure();
    _values.remove(key);
  }
}

final class DevicePreferenceMalformedValue implements Exception {
  const DevicePreferenceMalformedValue();
}

final class DevicePreferenceBackendFailure implements Exception {
  const DevicePreferenceBackendFailure();
}

abstract interface class DevicePreferencesStore {
  Stream<DevicePreferences> watch();

  Future<Outcome<void>> setTheme(ThemePreference theme);

  Future<Outcome<void>> setDensity(DensityPreference density);

  Future<Outcome<void>> setOnboardingDismissed(bool dismissed);
}

final class DevicePreferencesAdapter implements DevicePreferencesStore {
  factory DevicePreferencesAdapter({
    required DevicePreferencesBackend backend,
    required String namespace,
    required DiagnosticSink diagnostics,
  }) {
    if (namespace.isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'must not be empty');
    }
    return DevicePreferencesAdapter._(backend, namespace, diagnostics);
  }

  DevicePreferencesAdapter._(this._backend, this._namespace, this._diagnostics);

  final DevicePreferencesBackend _backend;
  final String _namespace;
  final DiagnosticSink _diagnostics;
  final StreamController<DevicePreferences> _changes =
      StreamController<DevicePreferences>.broadcast();
  Future<DevicePreferences>? _initialization;
  DevicePreferences? _current;

  String get _themeKey => '$_namespace.theme';
  String get _densityKey => '$_namespace.density';
  String get _onboardingKey => '$_namespace.onboarding_dismissed';

  @override
  Stream<DevicePreferences> watch() {
    return Stream<DevicePreferences>.multi((controller) {
      var initialized = false;
      final pending = <DevicePreferences>[];
      final subscription = _changes.stream.listen(
        (value) {
          if (initialized) {
            controller.add(value);
          } else {
            pending.add(value);
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = subscription.cancel;
      _currentValue().then((value) {
        controller.add(value);
        initialized = true;
        for (final update in pending) {
          controller.add(update);
        }
      }, onError: controller.addError);
    });
  }

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async {
    await _initialize();
    final current = _current!;
    return _write(
      preference: 'theme',
      write: () => _backend.writeString(_themeKey, theme.name),
      next: current.copyWith(theme: theme),
    );
  }

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async {
    await _initialize();
    final current = _current!;
    return _write(
      preference: 'density',
      write: () => _backend.writeString(_densityKey, density.name),
      next: current.copyWith(density: density),
    );
  }

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async {
    await _initialize();
    final current = _current!;
    return _write(
      preference: 'onboarding_dismissed',
      write: () => _backend.writeBool(_onboardingKey, dismissed),
      next: current.copyWith(onboardingDismissed: dismissed),
    );
  }

  Future<void> close() => _changes.close();

  Future<DevicePreferences> _initialize() {
    return _initialization ??= _readAll().then((value) {
      _current = value;
      return value;
    });
  }

  Future<DevicePreferences> _currentValue() async {
    await _initialize();
    return _current!;
  }

  Future<DevicePreferences> _readAll() async {
    final theme = await _readEnum<ThemePreference>(
      preference: 'theme',
      key: _themeKey,
      read: () => _backend.readString(_themeKey),
      values: ThemePreference.values,
      fallback: ThemePreference.system,
    );
    final density = await _readEnum<DensityPreference>(
      preference: 'density',
      key: _densityKey,
      read: () => _backend.readString(_densityKey),
      values: DensityPreference.values,
      fallback: DensityPreference.standard,
    );
    final onboardingDismissed = await _readBool(
      preference: 'onboarding_dismissed',
      key: _onboardingKey,
      fallback: false,
    );
    return DevicePreferences(
      theme: theme,
      density: density,
      onboardingDismissed: onboardingDismissed,
    );
  }

  Future<T> _readEnum<T extends Enum>({
    required String preference,
    required String key,
    required Future<String?> Function() read,
    required List<T> values,
    required T fallback,
  }) async {
    try {
      final stored = await read();
      if (stored == null) return fallback;
      for (final value in values) {
        if (value.name == stored) return value;
      }
      throw const DevicePreferenceMalformedValue();
    } on DevicePreferenceMalformedValue {
      await _defaultMalformed(preference, key);
      return fallback;
    } on TypeError {
      await _defaultMalformed(preference, key);
      return fallback;
    } on Object {
      _recordDefault(preference, 'read_failed');
      return fallback;
    }
  }

  Future<bool> _readBool({
    required String preference,
    required String key,
    required bool fallback,
  }) async {
    try {
      return await _backend.readBool(key) ?? fallback;
    } on DevicePreferenceMalformedValue {
      await _defaultMalformed(preference, key);
      return fallback;
    } on TypeError {
      await _defaultMalformed(preference, key);
      return fallback;
    } on Object {
      _recordDefault(preference, 'read_failed');
      return fallback;
    }
  }

  Future<void> _defaultMalformed(String preference, String key) async {
    try {
      await _backend.remove(key);
      _recordDefault(preference, 'malformed_value_removed');
    } on Object {
      _recordDefault(preference, 'malformed_value_remove_failed');
    }
  }

  void _recordDefault(String preference, String reason) {
    _diagnostics.record(
      DiagnosticEvent(
        code: 'preferences.device_value_defaulted',
        operation: 'read_device_preferences',
        fields: <DiagnosticField>[
          DiagnosticField.safe('preference', preference),
          DiagnosticField.safe('reason', reason),
        ],
      ),
    );
  }

  Future<Outcome<void>> _write({
    required String preference,
    required Future<void> Function() write,
    required DevicePreferences next,
  }) async {
    try {
      await write();
      _current = next;
      _changes.add(next);
      return const Outcome<void>.success(null);
    } on Object {
      _diagnostics.record(
        DiagnosticEvent(
          code: 'preferences.device_write_failed',
          operation: 'write_device_preferences',
          fields: <DiagnosticField>[
            DiagnosticField.safe('preference', preference),
          ],
        ),
      );
      return const Outcome<void>.failure(_deviceWriteFailure);
    }
  }
}

const Failure _deviceWriteFailure = Failure(
  code: 'preferences.device_write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The device presentation preference was not saved.',
  safeSummary: 'The disposable device preference write failed.',
);
