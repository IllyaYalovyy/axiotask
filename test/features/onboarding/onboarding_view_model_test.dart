import 'dart:async';

import 'package:axiotask/src/core/diagnostics/diagnostics.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/features/onboarding/onboarding_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PAR-UX-002 default onboarding is visible and persists dismissal',
    () async {
      final preferences = _Preferences();
      final viewModel = OnboardingViewModel(preferences);
      addTearDown(viewModel.dispose);

      viewModel.start();
      await _settle();
      expect(viewModel.state.preferences, const DevicePreferences.defaults());
      expect(viewModel.state.isVisible, isTrue);

      await viewModel.dismiss();

      expect(preferences.current.onboardingDismissed, isTrue);
      expect(viewModel.state.isVisible, isFalse);
      expect(viewModel.state.failureMessage, isNull);
    },
  );

  test(
    'dismissal failure closes for this process and is safe and observable',
    () async {
      final diagnostics = InMemoryDiagnosticHistory();
      final preferences = _Preferences()..failDismissal = true;
      final viewModel = OnboardingViewModel(
        preferences,
        diagnostics: ProductionDiagnosticSink(diagnostics),
      );
      addTearDown(viewModel.dispose);

      viewModel.start();
      await _settle();
      await viewModel.dismiss();

      expect(preferences.current.onboardingDismissed, isFalse);
      expect(viewModel.state.preferences.onboardingDismissed, isFalse);
      expect(viewModel.state.isVisible, isFalse);
      expect(
        viewModel.state.failureMessage,
        contains('may appear again next time'),
      );
      expect(diagnostics.records, hasLength(1));
      expect(
        diagnostics.records.single.code,
        'onboarding.dismissal_write_failed',
      );
      expect(diagnostics.records.single.fields, <String, String>{
        'failure_code': 'synthetic.write_failed',
      });

      preferences.emitCurrent();
      await _settle();
      expect(viewModel.state.isVisible, isFalse);

      final nextLaunch = OnboardingViewModel(preferences)..start();
      addTearDown(nextLaunch.dispose);
      await _settle();
      expect(nextLaunch.state.isVisible, isTrue);
    },
  );

  test('diagnostic failure cannot prevent process-local dismissal', () async {
    final preferences = _Preferences()..failDismissal = true;
    final viewModel = OnboardingViewModel(
      preferences,
      diagnostics: const _ThrowingDiagnosticSink(),
    );
    addTearDown(viewModel.dispose);

    viewModel.start();
    await _settle();
    await expectLater(viewModel.dismiss(), completes);

    expect(viewModel.state.isVisible, isFalse);
    expect(viewModel.state.failureMessage, isNotNull);
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _Preferences implements PreferencesRepository {
  final StreamController<DevicePreferences> _device =
      StreamController<DevicePreferences>.broadcast();
  var current = const DevicePreferences.defaults();
  var failDismissal = false;

  void emitCurrent() => _device.add(current);

  @override
  Stream<DevicePreferences> watchDevicePreferences() async* {
    yield current;
    yield* _device.stream;
  }

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async {
    if (failDismissal) {
      return const Outcome<void>.failure(_writeFailure);
    }
    current = current.copyWith(onboardingDismissed: dismissed);
    _device.add(current);
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async =>
      const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async => const Outcome<void>.success(null);

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async => const Outcome<void>.success(null);

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) => const Stream<Map<TaskListId, ListPreferences>>.empty();

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) => const Stream<Map<ViewKey, ViewPreferences>>.empty();

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => const Stream<ListPreferences>.empty();

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) => const Stream<ViewPreferences>.empty();
}

final class _ThrowingDiagnosticSink implements DiagnosticSink {
  const _ThrowingDiagnosticSink();

  @override
  void record(DiagnosticEvent event) => throw StateError('diagnostics failed');
}

const Failure _writeFailure = Failure(
  code: 'synthetic.write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'Synthetic preference failure.',
  safeSummary: 'Synthetic preference failure.',
);
