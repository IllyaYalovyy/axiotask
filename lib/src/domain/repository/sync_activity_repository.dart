import '../model/tasks.dart';

/// How one recorded synchronization run ended.
enum SyncRunRecordState { inProgress, succeeded, failed, interrupted }

/// One synchronization run as the activity history shows it.
///
/// Only closed vocabularies leave storage: trigger names and a diagnostic
/// failure code. No request, response, task or account text is recorded.
final class SyncRunRecord {
  SyncRunRecord({
    required this.state,
    required List<String> triggers,
    required this.startedAt,
    this.finishedAt,
    this.failureCode,
  }) : triggers = List<String>.unmodifiable(triggers);

  final SyncRunRecordState state;

  /// Stable trigger names such as `startup`, `refresh` or `local_edit`.
  final List<String> triggers;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? failureCode;

  Duration? get duration => finishedAt?.difference(startedAt);
}

/// Read-only access to the per-run synchronization history.
abstract interface class SyncActivityRepository {
  /// The most recent runs for [accountId], newest first.
  Stream<List<SyncRunRecord>> watchRecentRuns(
    AccountId accountId, {
    int limit = 50,
  });
}
