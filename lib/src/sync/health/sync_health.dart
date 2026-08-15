enum SyncHealthOutcome { inactive, pending, failed, good }

enum SyncInactiveReason { syncStopped, noAuthorization }

enum SyncFailureReason {
  noConnection,
  remoteFailure,
  applicationFailure,
  stale,
}

enum SyncPendingReason {
  checkingAuthorization,
  verifying,
  retrying,
  localChanges,
}

enum SyncHealthAction { none, connect, reauthorize, resume, retry }

enum SyncAuthorization { unknown, usable, absent, refreshing }

enum SyncConnectivity { unknown, mayHaveReturned, provenNoRoute }

enum SyncActivity {
  idle,
  checkingAuthorization,
  verifying,
  retrying,
  debouncing,
}

final class SyncWorkCounts {
  const SyncWorkCounts({
    this.pending = 0,
    this.inFlight = 0,
    this.uncertain = 0,
    this.failed = 0,
  }) : assert(pending >= 0),
       assert(inFlight >= 0),
       assert(uncertain >= 0),
       assert(failed >= 0);

  final int pending;
  final int inFlight;
  final int uncertain;
  final int failed;

  int get total => pending + inFlight + uncertain + failed;

  int get pendingConfirmation => pending + inFlight + uncertain;

  @override
  bool operator ==(Object other) =>
      other is SyncWorkCounts &&
      pending == other.pending &&
      inFlight == other.inFlight &&
      uncertain == other.uncertain &&
      failed == other.failed;

  @override
  int get hashCode => Object.hash(pending, inFlight, uncertain, failed);
}

final class SyncFailureFact {
  const SyncFailureFact({
    required this.reason,
    required this.occurredAt,
    required this.diagnosticCode,
    this.action = SyncHealthAction.none,
  });

  final SyncFailureReason reason;
  final DateTime occurredAt;
  final String diagnosticCode;
  final SyncHealthAction action;

  @override
  bool operator ==(Object other) =>
      other is SyncFailureFact &&
      reason == other.reason &&
      occurredAt == other.occurredAt &&
      diagnosticCode == other.diagnosticCode &&
      action == other.action;

  @override
  int get hashCode => Object.hash(reason, occurredAt, diagnosticCode, action);
}

/// Durable, account-scoped evidence. Runtime connectivity and coordinator
/// activity deliberately do not enter this value.
final class PersistedSyncFacts {
  const PersistedSyncFacts({
    this.syncEnabled = true,
    this.reauthorizationRequired = false,
    this.lastSuccessfulSyncAt,
    this.latestFailure,
    this.counts = const SyncWorkCounts(),
    this.retryWaiting = false,
    this.automaticRetryExhausted = false,
    this.requiredScopeIncomplete = false,
    this.followUpRequired = false,
  });

  final bool syncEnabled;
  final bool reauthorizationRequired;
  final DateTime? lastSuccessfulSyncAt;
  final SyncFailureFact? latestFailure;
  final SyncWorkCounts counts;
  final bool retryWaiting;
  final bool automaticRetryExhausted;
  final bool requiredScopeIncomplete;
  final bool followUpRequired;

  @override
  bool operator ==(Object other) =>
      other is PersistedSyncFacts &&
      syncEnabled == other.syncEnabled &&
      reauthorizationRequired == other.reauthorizationRequired &&
      lastSuccessfulSyncAt == other.lastSuccessfulSyncAt &&
      latestFailure == other.latestFailure &&
      counts == other.counts &&
      retryWaiting == other.retryWaiting &&
      automaticRetryExhausted == other.automaticRetryExhausted &&
      requiredScopeIncomplete == other.requiredScopeIncomplete &&
      followUpRequired == other.followUpRequired;

  @override
  int get hashCode => Object.hash(
    syncEnabled,
    reauthorizationRequired,
    lastSuccessfulSyncAt,
    latestFailure,
    counts,
    retryWaiting,
    automaticRetryExhausted,
    requiredScopeIncomplete,
    followUpRequired,
  );
}

final class SyncRuntimeFacts {
  const SyncRuntimeFacts({
    this.authorization = SyncAuthorization.unknown,
    this.connectivity = SyncConnectivity.unknown,
    this.activity = SyncActivity.idle,
    this.verificationRequired = false,
    this.detectedFailureReason,
    this.diagnosticCode,
    this.failureAction = SyncHealthAction.none,
  });

  final SyncAuthorization authorization;
  final SyncConnectivity connectivity;
  final SyncActivity activity;
  final bool verificationRequired;
  final SyncFailureReason? detectedFailureReason;
  final String? diagnosticCode;
  final SyncHealthAction failureAction;
}

final class SyncHealth {
  const SyncHealth({
    required this.outcome,
    required this.counts,
    required this.lastSuccessfulSyncAt,
    required this.evaluatedAt,
    this.inactiveReason,
    this.failureReason,
    this.pendingReason,
    this.action = SyncHealthAction.none,
    this.diagnosticCode,
  });

  final SyncHealthOutcome outcome;
  final SyncInactiveReason? inactiveReason;
  final SyncFailureReason? failureReason;
  final SyncPendingReason? pendingReason;
  final SyncHealthAction action;
  final SyncWorkCounts counts;
  final DateTime? lastSuccessfulSyncAt;
  final DateTime evaluatedAt;
  final String? diagnosticCode;

  String get summary => switch (outcome) {
    SyncHealthOutcome.inactive => 'Inactive',
    SyncHealthOutcome.pending => 'Pending',
    SyncHealthOutcome.failed => 'Failed',
    SyncHealthOutcome.good => 'Synced',
  };

  String get reasonLabel => switch ((
    inactiveReason,
    failureReason,
    pendingReason,
  )) {
    (SyncInactiveReason.syncStopped, _, _) => 'Sync stopped',
    (SyncInactiveReason.noAuthorization, _, _) => 'No authorization',
    (_, SyncFailureReason.noConnection, _) => 'No connection',
    (_, SyncFailureReason.remoteFailure, _) => 'Google Tasks failed',
    (_, SyncFailureReason.applicationFailure, _) => 'Application failure',
    (_, SyncFailureReason.stale, _) => 'Cached data is stale',
    (_, _, SyncPendingReason.checkingAuthorization) => 'Checking authorization',
    (_, _, SyncPendingReason.verifying) => 'Verifying with Google',
    (_, _, SyncPendingReason.retrying) => 'Retrying synchronization',
    (_, _, SyncPendingReason.localChanges) => 'Changes awaiting Google',
    _ when outcome == SyncHealthOutcome.good => 'Synchronization completed',
    _ => 'Synchronization state unavailable',
  };

  String get lastSuccessLabel {
    final value = lastSuccessfulSyncAt;
    if (value == null) return 'Never';
    final utc = value.toUtc();
    final exact =
        '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')} '
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')} UTC';
    final age = evaluatedAt.toUtc().difference(utc);
    if (age.isNegative) return '$exact (clock changed; verification required)';
    if (age < const Duration(minutes: 1)) {
      return '$exact (less than a minute ago)';
    }
    if (age < const Duration(hours: 1)) {
      final minutes = age.inMinutes;
      return '$exact ($minutes ${minutes == 1 ? 'minute' : 'minutes'} ago)';
    }
    if (age < const Duration(days: 1)) {
      final hours = age.inHours;
      return '$exact ($hours ${hours == 1 ? 'hour' : 'hours'} ago)';
    }
    final days = age.inDays;
    return '$exact ($days ${days == 1 ? 'day' : 'days'} ago)';
  }
}

const Duration syncFreshnessWindow = Duration(minutes: 5);

SyncHealth projectSyncHealth({
  required PersistedSyncFacts facts,
  required SyncRuntimeFacts runtime,
  required DateTime now,
}) {
  SyncHealth result({
    required SyncHealthOutcome outcome,
    SyncInactiveReason? inactiveReason,
    SyncFailureReason? failureReason,
    SyncPendingReason? pendingReason,
    SyncHealthAction action = SyncHealthAction.none,
    String? diagnosticCode,
  }) => SyncHealth(
    outcome: outcome,
    inactiveReason: inactiveReason,
    failureReason: failureReason,
    pendingReason: pendingReason,
    action: action,
    counts: facts.counts,
    lastSuccessfulSyncAt: facts.lastSuccessfulSyncAt,
    evaluatedAt: now,
    diagnosticCode: diagnosticCode,
  );

  if (!facts.syncEnabled) {
    return result(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.syncStopped,
      action: SyncHealthAction.resume,
    );
  }
  if (facts.reauthorizationRequired ||
      runtime.authorization == SyncAuthorization.absent) {
    return result(
      outcome: SyncHealthOutcome.inactive,
      inactiveReason: SyncInactiveReason.noAuthorization,
      action: facts.reauthorizationRequired
          ? SyncHealthAction.reauthorize
          : SyncHealthAction.connect,
    );
  }

  // Executing retry is the sole Pending exception over an already detected
  // failure. A queued retry or backoff wait remains Failed.
  if (runtime.activity == SyncActivity.retrying) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.retrying,
    );
  }

  if (runtime.detectedFailureReason case final reason?) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: reason,
      action: runtime.failureAction,
      diagnosticCode: runtime.diagnosticCode,
    );
  }

  final latestFailure = facts.latestFailure;
  final success = facts.lastSuccessfulSyncAt;
  final failureIsCurrent =
      latestFailure != null &&
      (success == null || !latestFailure.occurredAt.isBefore(success));
  if (failureIsCurrent) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: latestFailure.reason,
      action: latestFailure.action,
      diagnosticCode: latestFailure.diagnosticCode,
    );
  }
  if (runtime.connectivity == SyncConnectivity.provenNoRoute) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.noConnection,
      action: SyncHealthAction.retry,
    );
  }
  if (facts.requiredScopeIncomplete || facts.counts.failed > 0) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.applicationFailure,
    );
  }
  if (facts.retryWaiting || facts.automaticRetryExhausted) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.remoteFailure,
      action: SyncHealthAction.retry,
    );
  }

  final isStale =
      success == null ||
      !now.toUtc().isBefore(success.toUtc().add(syncFreshnessWindow));
  if (success != null && now.toUtc().isBefore(success.toUtc())) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    );
  }
  final verificationActive =
      runtime.activity == SyncActivity.verifying ||
      runtime.verificationRequired;
  if (isStale && verificationActive) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    );
  }

  if (runtime.authorization == SyncAuthorization.unknown ||
      runtime.authorization == SyncAuthorization.refreshing ||
      runtime.activity == SyncActivity.checkingAuthorization) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.checkingAuthorization,
    );
  }
  if (runtime.activity == SyncActivity.verifying ||
      runtime.verificationRequired) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
    );
  }
  if (runtime.activity == SyncActivity.debouncing ||
      facts.followUpRequired ||
      facts.counts.pendingConfirmation > 0) {
    return result(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.localChanges,
    );
  }
  if (isStale) {
    return result(
      outcome: SyncHealthOutcome.failed,
      failureReason: SyncFailureReason.stale,
      action: SyncHealthAction.retry,
    );
  }
  return result(outcome: SyncHealthOutcome.good);
}
