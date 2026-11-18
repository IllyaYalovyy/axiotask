import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 12);

  test(
    'authorization configuration failure explains why connection is blocked',
    () {
      final health = SyncHealth(
        outcome: SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.applicationFailure,
        diagnosticCode: 'auth.configuration',
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: null,
        evaluatedAt: t0,
      );
      expect(
        health.reasonLabel,
        'Google connection configuration needs repair',
      );
    },
  );

  test('known sync failures explain the problem without raw response data', () {
    for (final entry in <String, String>{
      'google_tasks.malformed_success':
          'Google returned task data Axiotask could not read',
      'sync.unsupported_task_depth': 'A task has too many nested subtasks',
      'sync.coordinator_run_failed': 'Sync stopped unexpectedly. Open details',
    }.entries) {
      final health = SyncHealth(
        outcome: SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.applicationFailure,
        diagnosticCode: entry.key,
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: t0,
        evaluatedAt: t0,
      );
      expect(health.reasonLabel, entry.value);
      expect(health.usesCompactStatus, isFalse);
    }
  });

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
      expect(waiting.reasonLabel, 'Retry 3 after 12:01:30 UTC');
      expect(
        project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: t0,
            retryWaiting: true,
            retryNextAttemptAt: DateTime.utc(2026, 8, 16, 0, 0, 5),
            retryAttemptCount: 2,
          ),
        ).reasonLabel,
        'Retry 3 after 2026-08-16 00:00:05 UTC',
        reason: 'A retry on another UTC day names the date',
      );
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

  group('routine status and explanations (Android audit 18, 19)', () {
    test('one queued edit after a recent sync is compact and unconfirmed', () {
      final health = project(
        facts: PersistedSyncFacts(
          lastSuccessfulSyncAt: t0,
          counts: const SyncWorkCounts(pending: 1),
        ),
        elapsed: const Duration(seconds: 30),
      );
      expect(health.outcome, SyncHealthOutcome.pending);
      expect(health.pendingReason, SyncPendingReason.localChanges);
      expect(health.usesCompactStatus, isTrue);
      expect(health.compactLabel, 'Saved on device');
      expect(health.compactDetail, '1 waiting for Google');
      expect(
        health.localWorkLabel,
        '1 change saved on this device, not yet on Google.',
      );
      expect(health.compactLabel, isNot('Synced'));
    });

    test('the next step for queued work matches what was already sent', () {
      SyncHealth queued(SyncWorkCounts counts) => project(
        facts: PersistedSyncFacts(lastSuccessfulSyncAt: t0, counts: counts),
        elapsed: const Duration(seconds: 30),
      );
      for (final (counts, step) in <(SyncWorkCounts, String)>[
        (
          const SyncWorkCounts(pending: 1),
          'Axiotask sends it when Google is reachable.',
        ),
        (
          const SyncWorkCounts(pending: 1, inFlight: 1),
          'Axiotask sends them when Google is reachable.',
        ),
        (
          const SyncWorkCounts(pending: 1, uncertain: 2),
          'Axiotask sends it when Google is reachable.',
        ),
        (
          const SyncWorkCounts(uncertain: 1),
          'Axiotask is confirming with Google.',
        ),
      ]) {
        final health = queued(counts);
        expect(health.pendingReason, SyncPendingReason.localChanges);
        expect(health.guidance, step, reason: '${counts.total} unresolved');
      }
      final uncertainOnly = queued(const SyncWorkCounts(uncertain: 1));
      expect(
        uncertainOnly.localWorkLabel,
        '1 change sent but not yet confirmed by Google.',
      );
      expect(uncertainOnly.guidance, isNot(contains('sends')));
    });

    test('a routine edit stays compact through the run that publishes it', () {
      // The coordinator debounces the edit, then verifies with Google while
      // the run sends it, then completes; the last success is 30 seconds old.
      final phases = <(String, SyncWorkCounts, SyncRuntimeFacts)>[
        (
          'debouncing',
          const SyncWorkCounts(pending: 1),
          const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.debouncing,
          ),
        ),
        (
          'verifying, pending',
          const SyncWorkCounts(pending: 1),
          const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
            verificationRequired: true,
          ),
        ),
        (
          'verifying, in flight',
          const SyncWorkCounts(inFlight: 1),
          const SyncRuntimeFacts(
            authorization: SyncAuthorization.usable,
            activity: SyncActivity.verifying,
          ),
        ),
        (
          'idle, confirmed',
          const SyncWorkCounts(),
          const SyncRuntimeFacts(authorization: SyncAuthorization.usable),
        ),
      ];
      for (final (phase, counts, runtime) in phases) {
        final health = project(
          facts: PersistedSyncFacts(lastSuccessfulSyncAt: t0, counts: counts),
          runtime: runtime,
          elapsed: const Duration(seconds: 30),
        );
        expect(health.usesCompactStatus, isTrue, reason: phase);
        if (counts.total == 0) {
          expect(health.outcome, SyncHealthOutcome.good, reason: phase);
          expect(health.compactLabel, 'Synced', reason: phase);
          continue;
        }
        expect(health.outcome, SyncHealthOutcome.pending, reason: phase);
        expect(health.compactLabel, isNot(contains('Synced')), reason: phase);
        expect(health.compactDetail, '1 waiting for Google', reason: phase);
        expect(
          health.localWorkLabel,
          '1 change saved on this device, not yet on Google.',
          reason: phase,
        );
      }
    });

    test('routine compactness ends at the freshness window', () {
      for (final (elapsed, compact) in <(Duration, bool)>[
        (const Duration(minutes: 4, seconds: 59), true),
        (const Duration(minutes: 5), false),
        (const Duration(hours: 3), false),
      ]) {
        final health = project(
          facts: PersistedSyncFacts(
            lastSuccessfulSyncAt: t0,
            counts: const SyncWorkCounts(pending: 1),
          ),
          elapsed: elapsed,
        );
        expect(health.outcome, SyncHealthOutcome.pending, reason: '$elapsed');
        expect(health.usesCompactStatus, compact, reason: '$elapsed');
      }
    });

    test(
      'uncertain, failed, retrying, stopped and unauthorized work expands',
      () {
        final cases = <String, SyncHealth>{
          'uncertain': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(uncertain: 1),
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'failed work': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1, failed: 1),
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'retrying': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1),
            ),
            runtime: const SyncRuntimeFacts(
              authorization: SyncAuthorization.usable,
              activity: SyncActivity.retrying,
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'stopped': project(
            facts: PersistedSyncFacts(
              syncEnabled: false,
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1),
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'reauthorize': project(
            facts: PersistedSyncFacts(
              reauthorizationRequired: true,
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1),
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'checking authorization': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1),
            ),
            runtime: const SyncRuntimeFacts(),
            elapsed: const Duration(seconds: 30),
          ),
          'verifying with work behind an old success': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(pending: 1),
            ),
            runtime: const SyncRuntimeFacts(
              authorization: SyncAuthorization.usable,
              activity: SyncActivity.verifying,
            ),
            elapsed: syncFreshnessWindow,
          ),
          'verifying with uncertain work': project(
            facts: PersistedSyncFacts(
              lastSuccessfulSyncAt: t0,
              counts: const SyncWorkCounts(uncertain: 1),
            ),
            runtime: const SyncRuntimeFacts(
              authorization: SyncAuthorization.usable,
              activity: SyncActivity.verifying,
            ),
            elapsed: const Duration(seconds: 30),
          ),
          'never synced': project(
            facts: const PersistedSyncFacts(counts: SyncWorkCounts(pending: 1)),
          ),
        };
        for (final MapEntry(key: name, value: health) in cases.entries) {
          expect(health.usesCompactStatus, isFalse, reason: name);
          expect(health.localWorkLabel, isNotNull, reason: name);
        }
      },
    );

    test('unknown application failures state the uncertainty', () {
      final unknown = SyncHealth(
        outcome: SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.applicationFailure,
        action: SyncHealthAction.retry,
        diagnosticCode: 'synthetic.unclassified',
        counts: const SyncWorkCounts(failed: 1),
        lastSuccessfulSyncAt: t0,
        evaluatedAt: t0,
      );
      expect(unknown.isCauseKnown, isFalse);
      expect(unknown.reasonLabel, 'Sync could not finish. Cause unknown');
      expect(
        unknown.guidance,
        'Retry, or open details for the reference code.',
      );
      expect(unknown.localWorkLabel, '1 change could not be sent.');

      final known = SyncHealth(
        outcome: SyncHealthOutcome.failed,
        failureReason: SyncFailureReason.applicationFailure,
        diagnosticCode: 'sync.malformed_task_notes',
        counts: const SyncWorkCounts(),
        lastSuccessfulSyncAt: t0,
        evaluatedAt: t0,
      );
      expect(known.isCauseKnown, isTrue);
      expect(
        known.reasonLabel,
        'Google returned task data Axiotask could not read',
      );
    });

    test('explanations come from typed reasons, never raw failure text', () {
      final sensitive = RegExp(
        r'token|bearer|secret|password|https?:|@',
        caseSensitive: false,
      );
      for (final reason in SyncFailureReason.values) {
        for (final code in <String?>[
          null,
          'auth.refresh_rejected',
          'google_tasks.unauthorized',
          'synthetic.unclassified',
        ]) {
          final health = SyncHealth(
            outcome: SyncHealthOutcome.failed,
            failureReason: reason,
            action: SyncHealthAction.retry,
            diagnosticCode: code,
            counts: const SyncWorkCounts(pending: 1),
            lastSuccessfulSyncAt: t0,
            evaluatedAt: t0,
          );
          for (final text in <String>[
            health.reasonLabel,
            health.guidance,
            health.localWorkLabel!,
          ]) {
            expect(text, isNot(matches(sensitive)), reason: '$reason $code');
            if (code != null) expect(text, isNot(contains(code)));
          }
        }
      }
    });
  });
}
