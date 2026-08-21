import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 12);

  SyncHealth project({
    PersistedSyncFacts facts = const PersistedSyncFacts(),
    SyncRuntimeFacts runtime = const SyncRuntimeFacts(
      authorization: SyncAuthorization.usable,
    ),
    Duration elapsed = const Duration(minutes: 1),
  }) => projectSyncHealth(facts: facts, runtime: runtime, now: t0.add(elapsed));

  group('Inactive (HLT-001)', () {
    test('sync stopped has precedence and retains every unresolved count', () {
      final health = project(
        facts: PersistedSyncFacts(
          syncEnabled: false,
          lastSuccessfulSyncAt: t0,
          latestFailure: SyncFailureFact(
            reason: SyncFailureReason.remoteFailure,
            occurredAt: t0.add(const Duration(seconds: 30)),
            diagnosticCode: 'sync.remote.synthetic',
            action: SyncHealthAction.retry,
          ),
          counts: const SyncWorkCounts(
            pending: 2,
            inFlight: 1,
            uncertain: 3,
            failed: 4,
          ),
        ),
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.absent,
          activity: SyncActivity.verifying,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.inactive);
      expect(health.inactiveReason, SyncInactiveReason.syncStopped);
      expect(health.action, SyncHealthAction.resume);
      expect(health.counts.total, 10);
      expect(health.lastSuccessfulSyncAt, t0);
    });

    test('authorization action distinguishes Connect from Reauthorize', () {
      final connect = project(
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.absent,
        ),
      );
      final reauthorize = project(
        facts: const PersistedSyncFacts(reauthorizationRequired: true),
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
        ),
      );

      expect(connect.inactiveReason, SyncInactiveReason.noAuthorization);
      expect(connect.action, SyncHealthAction.connect);
      expect(reauthorize.inactiveReason, SyncInactiveReason.noAuthorization);
      expect(reauthorize.action, SyncHealthAction.reauthorize);
    });
  });

  group('Failed and Pending precedence (HLT-002/003/006/007/012)', () {
    for (final reason in SyncFailureReason.values.where(
      (value) => value != SyncFailureReason.stale,
    )) {
      test(
        'detected ${reason.name} remains Failed during another active scope',
        () {
          final health = project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              latestFailure: SyncFailureFact(
                reason: reason,
                occurredAt: t0.add(const Duration(seconds: 30)),
                diagnosticCode: 'sync.${reason.name}.synthetic',
              ),
            ),
            runtime: const SyncRuntimeFacts(
              authorization: SyncAuthorization.usable,
              activity: SyncActivity.verifying,
            ),
          );

          expect(health.outcome, SyncHealthOutcome.failed);
          expect(health.failureReason, reason);
        },
      );
    }

    test('backoff waiting is Failed and only executing retry is Pending', () {
      final facts = PersistedSyncFacts(
        lastSuccessfulSyncAt: t0,
        retryWaiting: true,
        latestFailure: SyncFailureFact(
          reason: SyncFailureReason.remoteFailure,
          occurredAt: t0.add(const Duration(seconds: 1)),
          diagnosticCode: 'sync.rate_limited.synthetic',
          action: SyncHealthAction.retry,
        ),
        retryNextAttemptAt: t0.add(const Duration(minutes: 1, seconds: 30)),
        retryAttemptCount: 2,
      );

      final waiting = project(facts: facts);
      expect(waiting.outcome, SyncHealthOutcome.failed);
      expect(waiting.action, SyncHealthAction.retry);
      expect(waiting.reasonLabel, contains('Retry 3 after'));
      final retrying = project(
        facts: facts,
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
          activity: SyncActivity.retrying,
        ),
      );
      expect(retrying.outcome, SyncHealthOutcome.pending);
      expect(retrying.pendingReason, SyncPendingReason.retrying);
    });

    test('exhaustion remains Failed with immediate Retry action', () {
      final exhausted = project(
        facts: PersistedSyncFacts(
          automaticRetryExhausted: true,
          latestFailure: SyncFailureFact(
            reason: SyncFailureReason.remoteFailure,
            occurredAt: t0.add(const Duration(seconds: 1)),
            diagnosticCode: 'sync.retry_exhausted.synthetic',
            action: SyncHealthAction.retry,
          ),
        ),
      );

      expect(exhausted.outcome, SyncHealthOutcome.failed);
      expect(exhausted.action, SyncHealthAction.retry);
      expect(exhausted.reasonLabel, 'Automatic retry exhausted');
    });

    test('authorization request network failure is Failed, never Inactive', () {
      final health = project(
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.unknown,
          detectedFailureReason: SyncFailureReason.noConnection,
          diagnosticCode: 'auth.network.synthetic',
          failureAction: SyncHealthAction.retry,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.noConnection);
      expect(health.inactiveReason, isNull);
      expect(health.action, SyncHealthAction.retry);
    });

    test('follow-up and all unresolved work kinds prevent a green flash', () {
      for (final facts in <PersistedSyncFacts>[
        PersistedSyncFacts(lastSuccessfulSyncAt: t0, followUpRequired: true),
        PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          counts: const SyncWorkCounts(pending: 1),
        ),
        PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          counts: const SyncWorkCounts(inFlight: 1),
        ),
        PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          counts: const SyncWorkCounts(uncertain: 1),
        ),
      ]) {
        expect(project(facts: facts).outcome, SyncHealthOutcome.pending);
      }
    });

    test('partial publication retains the old success and is Failed', () {
      final health = project(
        facts: PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          latestFailure: SyncFailureFact(
            reason: SyncFailureReason.remoteFailure,
            occurredAt: t0.add(const Duration(seconds: 20)),
            diagnosticCode: 'sync.partial_scope.synthetic',
          ),
          requiredScopeIncomplete: true,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.lastSuccessfulSyncAt, t0);
    });

    test(
      'incomplete durable run is Pending only while verification is active',
      () {
        final active = project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: t0,
            requiredScopeIncomplete: true,
          ),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
            verificationRequired: true,
          ),
        );
        final interrupted = project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: t0,
            requiredScopeIncomplete: true,
          ),
        );

        expect(active.outcome, SyncHealthOutcome.pending);
        expect(active.pendingReason, SyncPendingReason.verifying);
        expect(interrupted.outcome, SyncHealthOutcome.failed);
        expect(interrupted.failureReason, SyncFailureReason.applicationFailure);
      },
    );

    test('failed desired work remains Failed during active verification', () {
      final health = project(
        facts: PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          requiredScopeIncomplete: true,
          counts: const SyncWorkCounts(failed: 1),
        ),
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
          activity: SyncActivity.verifying,
          verificationRequired: true,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.applicationFailure);
    });
  });

  group('Good and freshness (HLT-004/005/008/013)', () {
    test('is Good only after a recent completed required synchronization', () {
      final good = project(facts: PersistedSyncFacts(lastSuccessfulSyncAt: t0));

      expect(good.outcome, SyncHealthOutcome.good);
      expect(good.summary, 'Synced');
      expect(good.summary, isNot('Up to date'));
    });

    test('every independently forbidden fact makes the baseline non-green', () {
      final recent = t0.subtract(const Duration(minutes: 1));
      final cases = <SyncHealth>[
        project(
          facts: PersistedSyncFacts(
            syncEnabled: false,
            lastSuccessfulSyncAt: recent,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.unknown,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.refreshing,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.absent,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            connectivity: SyncConnectivity.provenNoRoute,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            verificationRequired: true,
          ),
        ),
        project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: recent),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
          ),
        ),
        project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: recent,
            followUpRequired: true,
          ),
        ),
        project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: recent,
            retryWaiting: true,
          ),
        ),
        project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: recent,
            automaticRetryExhausted: true,
          ),
        ),
        project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: recent,
            requiredScopeIncomplete: true,
          ),
        ),
        for (final counts in const <SyncWorkCounts>[
          SyncWorkCounts(pending: 1),
          SyncWorkCounts(inFlight: 1),
          SyncWorkCounts(uncertain: 1),
          SyncWorkCounts(failed: 1),
        ])
          project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: recent,
              counts: counts,
            ),
          ),
      ];

      expect(
        cases,
        everyElement(
          predicate<SyncHealth>(
            (value) => value.outcome != SyncHealthOutcome.good,
          ),
        ),
      );
    });

    test('five-minute boundary is exact', () {
      final facts = PersistedSyncFacts(lastSuccessfulSyncAt: t0);

      expect(
        project(
          facts: facts,
          elapsed: const Duration(minutes: 5) - const Duration(milliseconds: 1),
        ).outcome,
        SyncHealthOutcome.good,
      );
      expect(
        project(
          facts: facts,
          elapsed: const Duration(minutes: 5),
        ).failureReason,
        SyncFailureReason.stale,
      );
      expect(
        project(
          facts: facts,
          elapsed: const Duration(minutes: 5, milliseconds: 1),
        ).failureReason,
        SyncFailureReason.stale,
      );
      expect(
        project(
          facts: facts,
          elapsed: const Duration(minutes: 5),
          runtime: const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
          ),
        ).pendingReason,
        SyncPendingReason.verifying,
      );
    });

    test('cache, token, and positive connectivity never manufacture Good', () {
      final health = project(
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
          connectivity: SyncConnectivity.mayHaveReturned,
          verificationRequired: true,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.pending);
      expect(health.pendingReason, SyncPendingReason.verifying);
      expect(health.lastSuccessfulSyncAt, isNull);
    });

    test('known no-route invalidates an otherwise Good result', () {
      final health = project(
        facts: PersistedSyncFacts(lastSuccessfulSyncAt: t0),
        runtime: const SyncRuntimeFacts(
          authorization: SyncAuthorization.usable,
          connectivity: SyncConnectivity.provenNoRoute,
        ),
      );

      expect(health.outcome, SyncHealthOutcome.failed);
      expect(health.failureReason, SyncFailureReason.noConnection);
    });
  });

  test('every non-Good result keeps exact last-success or Never (HLT-009)', () {
    final withSuccess = project(
      facts: PersistedSyncFacts(syncEnabled: false, lastSuccessfulSyncAt: t0),
    );
    final never = project(
      runtime: const SyncRuntimeFacts(authorization: SyncAuthorization.absent),
    );

    expect(withSuccess.lastSuccessLabel, contains('2026-08-15 12:00 UTC'));
    expect(never.lastSuccessLabel, 'Never');
  });

  test('backward wall-clock discontinuity requires verification', () {
    final health = project(
      facts: PersistedSyncFacts(
        lastSuccessfulSyncAt: t0.add(const Duration(minutes: 2)),
      ),
    );

    expect(health.outcome, SyncHealthOutcome.pending);
    expect(health.pendingReason, SyncPendingReason.verifying);
    expect(health.lastSuccessLabel, contains('clock changed'));
  });
}
