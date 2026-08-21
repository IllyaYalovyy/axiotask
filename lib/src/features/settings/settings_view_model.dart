import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/diagnostics/diagnostics.dart';
import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';
import '../../domain/repository/preferences_repository.dart';

final class SettingsViewState {
  const SettingsViewState({
    required this.preferences,
    this.isLoading = true,
    this.isSaving = false,
    this.failureMessage,
  });

  final DevicePreferences preferences;
  final bool isLoading;
  final bool isSaving;
  final String? failureMessage;

  SettingsViewState copyWith({
    DevicePreferences? preferences,
    bool? isLoading,
    bool? isSaving,
    Object? failureMessage = _notProvided,
  }) => SettingsViewState(
    preferences: preferences ?? this.preferences,
    isLoading: isLoading ?? this.isLoading,
    isSaving: isSaving ?? this.isSaving,
    failureMessage: identical(failureMessage, _notProvided)
        ? this.failureMessage
        : failureMessage as String?,
  );
}

const Object _notProvided = Object();

final class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._preferences, {this.diagnostics});

  final PreferencesRepository _preferences;
  final DiagnosticSink? diagnostics;
  StreamSubscription<DevicePreferences>? _subscription;
  var _started = false;
  var _state = const SettingsViewState(
    preferences: DevicePreferences.defaults(),
  );

  SettingsViewState get state => _state;

  void start() {
    if (_started) return;
    _started = true;
    _subscription = _preferences.watchDevicePreferences().listen(
      (preferences) =>
          _replace(_state.copyWith(preferences: preferences, isLoading: false)),
      onError: (_) => _replace(
        _state.copyWith(
          isLoading: false,
          failureMessage:
              'Appearance settings could not be loaded. Defaults are shown.',
        ),
      ),
    );
  }

  Future<void> setTheme(ThemePreference theme) async {
    if (_state.isSaving || theme == _state.preferences.theme) return;
    await _persist(
      preference: 'theme',
      write: () => _preferences.setTheme(theme),
      apply: () => _state.preferences.copyWith(theme: theme),
    );
  }

  Future<void> setDensity(DensityPreference density) async {
    if (_state.isSaving || density == _state.preferences.density) return;
    await _persist(
      preference: 'density',
      write: () => _preferences.setDensity(density),
      apply: () => _state.preferences.copyWith(density: density),
    );
  }

  void clearFailure() => _replace(_state.copyWith(failureMessage: null));

  Future<void> _persist({
    required String preference,
    required Future<Outcome<void>> Function() write,
    required DevicePreferences Function() apply,
  }) async {
    _replace(_state.copyWith(isSaving: true, failureMessage: null));
    late final Outcome<void> result;
    try {
      result = await write();
    } on Object {
      _finishFailure(preference, 'unexpected_exception');
      return;
    }
    switch (result) {
      case Success<void>():
        _replace(
          _state.copyWith(
            preferences: apply(),
            isSaving: false,
            failureMessage: null,
          ),
        );
      case Failed<void>(:final failure):
        _finishFailure(preference, failure.code);
    }
  }

  void _finishFailure(String preference, String failureCode) {
    final label = preference == 'theme' ? 'Theme' : 'Density';
    _replace(
      _state.copyWith(
        isSaving: false,
        failureMessage:
            '$label preference could not be saved. '
            'Your previous choice is still active.',
      ),
    );
    try {
      diagnostics?.record(
        DiagnosticEvent(
          subsystem: DiagnosticSubsystem.ui,
          kind: DiagnosticEventKind.failure,
          code: 'settings.preference_write_failed',
          operation: 'save_appearance_preference',
          fields: <DiagnosticField>[
            DiagnosticField.safe('preference', preference),
            DiagnosticField.safe('failure_code', failureCode),
          ],
        ),
      );
    } on Object {
      // Diagnostics cannot turn a nonblocking preference error into a crash.
    }
  }

  void _replace(SettingsViewState next) {
    if (_state.preferences == next.preferences &&
        _state.isLoading == next.isLoading &&
        _state.isSaving == next.isSaving &&
        _state.failureMessage == next.failureMessage) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
