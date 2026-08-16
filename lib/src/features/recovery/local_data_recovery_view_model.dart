import 'package:flutter/foundation.dart';

import '../../domain/model/tasks.dart';
import '../../domain/recovery/local_data_recovery.dart';
import '../../sync/health/sync_health.dart';
import '../../sync/health/sync_health_repository.dart';

enum LocalDataRecoveryOutcome { rebuilt, rebuildFailed, resetFailed }

final class LocalDataRecoveryViewState {
  const LocalDataRecoveryViewState({
    this.preview,
    this.isWorking = false,
    this.outcome,
  });

  final LocalDataResetPreview? preview;
  final bool isWorking;
  final LocalDataRecoveryOutcome? outcome;
}

final class LocalDataRecoveryViewModel extends ChangeNotifier {
  LocalDataRecoveryViewModel({
    required this.accountId,
    required this.recovery,
    required this.healthRepository,
  });

  final AccountId accountId;
  final LocalDataRecoveryService recovery;
  final SyncHealthRepository healthRepository;
  LocalDataRecoveryViewState _state = const LocalDataRecoveryViewState(
    isWorking: true,
  );

  LocalDataRecoveryViewState get state => _state;

  Future<void> loadPreview() async {
    if (_state.preview != null && !_state.isWorking) return;
    _state = const LocalDataRecoveryViewState(isWorking: true);
    notifyListeners();
    try {
      _state = LocalDataRecoveryViewState(
        preview: await recovery.preview(accountId),
      );
    } on Object {
      _state = const LocalDataRecoveryViewState(
        outcome: LocalDataRecoveryOutcome.resetFailed,
      );
    }
    notifyListeners();
  }

  Future<void> resetConfirmed(LocalDataResetPreview preview) async {
    if (_state.isWorking || preview.accountId != accountId) return;
    _state = LocalDataRecoveryViewState(preview: preview, isWorking: true);
    notifyListeners();
    try {
      await recovery.reset(
        confirmation: LocalDataResetConfirmation(
          accountId: accountId,
          preview: preview,
        ),
      );
      final health = await healthRepository.watchHealth(accountId).first;
      _state = LocalDataRecoveryViewState(
        preview: await recovery.preview(accountId),
        outcome: health.outcome == SyncHealthOutcome.good
            ? LocalDataRecoveryOutcome.rebuilt
            : LocalDataRecoveryOutcome.rebuildFailed,
      );
    } on Object {
      _state = LocalDataRecoveryViewState(
        preview: preview,
        outcome: LocalDataRecoveryOutcome.resetFailed,
      );
    }
    notifyListeners();
  }
}
