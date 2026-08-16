import '../../domain/model/tasks.dart';

final class RetryEpisode {
  const RetryEpisode({
    required this.startedAt,
    required this.deadlineAt,
    required this.lastObservedAt,
    required this.attemptCount,
    this.nextAttemptAt,
    this.serverNotBeforeAt,
    this.automaticRetryExhausted = false,
  }) : assert(attemptCount >= 0);

  final DateTime startedAt;
  final DateTime deadlineAt;
  final DateTime lastObservedAt;
  final DateTime? nextAttemptAt;
  final DateTime? serverNotBeforeAt;
  final int attemptCount;
  final bool automaticRetryExhausted;

  bool get retryWaiting => nextAttemptAt != null && !automaticRetryExhausted;

  RetryEpisode copyWith({
    DateTime? startedAt,
    DateTime? deadlineAt,
    DateTime? lastObservedAt,
    DateTime? nextAttemptAt,
    bool clearNextAttempt = false,
    DateTime? serverNotBeforeAt,
    bool clearServerNotBefore = false,
    int? attemptCount,
    bool? automaticRetryExhausted,
  }) => RetryEpisode(
    startedAt: startedAt ?? this.startedAt,
    deadlineAt: deadlineAt ?? this.deadlineAt,
    lastObservedAt: lastObservedAt ?? this.lastObservedAt,
    nextAttemptAt: clearNextAttempt
        ? null
        : nextAttemptAt ?? this.nextAttemptAt,
    serverNotBeforeAt: clearServerNotBefore
        ? null
        : serverNotBeforeAt ?? this.serverNotBeforeAt,
    attemptCount: attemptCount ?? this.attemptCount,
    automaticRetryExhausted:
        automaticRetryExhausted ?? this.automaticRetryExhausted,
  );
}

abstract interface class SyncRetryEpisodeStore {
  Future<RetryEpisode?> readRetryEpisode(AccountId accountId);

  Future<void> writeRetryEpisode(AccountId accountId, RetryEpisode episode);

  Future<void> clearRetryEpisode(AccountId accountId);
}
