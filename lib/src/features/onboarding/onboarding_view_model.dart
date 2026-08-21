import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';
import '../../domain/repository/preferences_repository.dart';

final class OnboardingViewState {
  const OnboardingViewState({
    required this.preferences,
    this.isSaving = false,
    this.failureMessage,
  });

  final DevicePreferences preferences;
  final bool isSaving;
  final String? failureMessage;

  bool get isVisible => !preferences.onboardingDismissed;

  OnboardingViewState copyWith({
    DevicePreferences? preferences,
    bool? isSaving,
    Object? failureMessage = _notProvided,
  }) => OnboardingViewState(
    preferences: preferences ?? this.preferences,
    isSaving: isSaving ?? this.isSaving,
    failureMessage: identical(failureMessage, _notProvided)
        ? this.failureMessage
        : failureMessage as String?,
  );
}

const Object _notProvided = Object();

final class OnboardingViewModel extends ChangeNotifier {
  OnboardingViewModel(this._preferences);

  final PreferencesRepository _preferences;
  StreamSubscription<DevicePreferences>? _subscription;
  var _started = false;
  var _state = const OnboardingViewState(
    preferences: DevicePreferences.defaults(),
  );

  OnboardingViewState get state => _state;

  void start() {
    if (_started) return;
    _started = true;
    _subscription = _preferences.watchDevicePreferences().listen(
      (preferences) => _replace(_state.copyWith(preferences: preferences)),
      onError: (_) {},
    );
  }

  Future<void> dismiss() async {
    if (_state.isSaving || !_state.isVisible) return;
    _replace(_state.copyWith(isSaving: true, failureMessage: null));
    final result = await _preferences.setOnboardingDismissed(true);
    if (result is Success<void>) {
      _replace(
        _state.copyWith(
          preferences: _state.preferences.copyWith(onboardingDismissed: true),
          isSaving: false,
        ),
      );
      return;
    }
    _replace(
      _state.copyWith(
        isSaving: false,
        failureMessage: 'Could not save onboarding dismissal. Try again.',
      ),
    );
  }

  void _replace(OnboardingViewState next) {
    if (_state.preferences == next.preferences &&
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
