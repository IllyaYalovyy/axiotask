import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/diagnostics/diagnostics.dart';
import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';
import '../../domain/repository/preferences_repository.dart';

final class OnboardingViewState {
  const OnboardingViewState({
    required this.preferences,
    this.isSaving = false,
    this.dismissedForProcess = false,
    this.failureMessage,
  });

  final DevicePreferences preferences;
  final bool isSaving;
  final bool dismissedForProcess;
  final String? failureMessage;

  bool get isVisible =>
      !preferences.onboardingDismissed && !dismissedForProcess;

  OnboardingViewState copyWith({
    DevicePreferences? preferences,
    bool? isSaving,
    bool? dismissedForProcess,
    Object? failureMessage = _notProvided,
  }) => OnboardingViewState(
    preferences: preferences ?? this.preferences,
    isSaving: isSaving ?? this.isSaving,
    dismissedForProcess: dismissedForProcess ?? this.dismissedForProcess,
    failureMessage: identical(failureMessage, _notProvided)
        ? this.failureMessage
        : failureMessage as String?,
  );
}

const Object _notProvided = Object();

final class OnboardingViewModel extends ChangeNotifier {
  OnboardingViewModel(this._preferences, {this.diagnostics});

  final PreferencesRepository _preferences;
  final DiagnosticSink? diagnostics;
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
    late final Outcome<void> result;
    try {
      result = await _preferences.setOnboardingDismissed(true);
    } on Object {
      _finishAfterPersistenceFailure('unexpected_exception');
      return;
    }
    if (result is Success<void>) {
      _replace(
        _state.copyWith(
          preferences: _state.preferences.copyWith(onboardingDismissed: true),
          isSaving: false,
          dismissedForProcess: true,
        ),
      );
      return;
    }
    _finishAfterPersistenceFailure((result as Failed<void>).failure.code);
  }

  void clearFailure() => _replace(_state.copyWith(failureMessage: null));

  void _finishAfterPersistenceFailure(String failureCode) {
    _replace(
      _state.copyWith(
        isSaving: false,
        dismissedForProcess: true,
        failureMessage:
            'Axiotask is ready, but onboarding dismissal could not be saved. '
            'It may appear again next time.',
      ),
    );
    try {
      diagnostics?.record(
        DiagnosticEvent(
          subsystem: DiagnosticSubsystem.storage,
          kind: DiagnosticEventKind.failure,
          code: 'onboarding.dismissal_write_failed',
          operation: 'dismiss_onboarding',
          fields: <DiagnosticField>[
            DiagnosticField.safe('failure_code', failureCode),
          ],
        ),
      );
    } on Object {
      // Diagnostics are best-effort and must never restore a blocking overlay.
    }
  }

  void _replace(OnboardingViewState next) {
    if (_state.preferences == next.preferences &&
        _state.isSaving == next.isSaving &&
        _state.dismissedForProcess == next.dismissedForProcess &&
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
