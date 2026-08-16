import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/sync/retry/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_random.dart';

void main() {
  final now = DateTime.utc(2026, 8, 15, 12);

  test('REL-007 request retry is initial plus 1/2/4 full-jitter waits', () {
    final policy = SyncRetryPolicy(
      FakeRandom.scriptedJitter(const <Duration>[
        Duration.zero,
        Duration(seconds: 2),
        Duration(seconds: 3),
      ]),
    );

    expect(policy.requestDelay(1, _transportFailure, now), Duration.zero);
    expect(
      policy.requestDelay(2, _transportFailure, now),
      const Duration(seconds: 2),
    );
    expect(
      policy.requestDelay(3, _transportFailure, now),
      const Duration(seconds: 3),
    );
    expect(
      () => policy.requestDelay(4, _transportFailure, now),
      throwsRangeError,
    );
    expect(syncRequestAttemptLimit, 4);
  });

  test('REL-008 valid later Retry-After wins while past dates do not', () {
    final policy = SyncRetryPolicy(
      FakeRandom.scriptedJitter(const <Duration>[
        Duration(milliseconds: 500),
        Duration(seconds: 1),
      ]),
    );
    final delayed = _failureWithRetryAfter(
      const RetryAfterDelay(Duration(seconds: 30)),
    );
    final past = _failureWithRetryAfter(
      RetryAfterDate(now.subtract(const Duration(seconds: 1))),
    );

    expect(policy.requestDelay(1, delayed, now), const Duration(seconds: 30));
    expect(policy.requestDelay(1, past, now), const Duration(seconds: 1));
  });

  test('REL-009 between-run schedule is 1/2/4/8/16/32 then capped 60', () {
    final policy = SyncRetryPolicy(
      FakeRandom.scriptedJitter(const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
        Duration(seconds: 32),
        Duration(seconds: 60),
        Duration(seconds: 59),
      ]),
    );

    expect(
      List<Duration>.generate(
        8,
        (index) => policy.betweenRunDelay(index, _transportFailure, now),
      ),
      const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
        Duration(seconds: 32),
        Duration(seconds: 60),
        Duration(seconds: 59),
      ],
    );
    expect(syncRetryEpisodeBudget, const Duration(minutes: 5));
  });

  test('REL-011 and REL-017 unknown/permanent failures fail closed', () {
    final policy = SyncRetryPolicy(FakeRandom.seeded(1));

    expect(policy.isAutomaticallyRetryable(_transportFailure), isTrue);
    expect(policy.isAutomaticallyRetryable(_unknownFailure), isFalse);
    expect(policy.isAutomaticallyRetryable(_permanentFailure), isFalse);
  });
}

const Failure _transportFailure = Failure(
  code: 'synthetic.transport',
  category: FailureCategory.network,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Synthetic transport failure.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic transport failure.',
);

const Failure _unknownFailure = Failure(
  code: 'synthetic.unknown',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.unknown,
  impact: 'Synthetic unknown failure.',
  safeSummary: 'Synthetic unknown failure.',
);

const Failure _permanentFailure = Failure(
  code: 'synthetic.permanent',
  category: FailureCategory.remote,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Synthetic permanent failure.',
  safeSummary: 'Synthetic permanent failure.',
);

Failure _failureWithRetryAfter(RetryAfter retryAfter) => Failure(
  code: 'synthetic.rate_limit',
  category: FailureCategory.rateLimit,
  operation: FailureOperation.read,
  retry: RetryClassification.transient,
  impact: 'Synthetic rate limit.',
  action: FailureAction.retry,
  safeSummary: 'Synthetic rate limit.',
  remoteContext: RemoteFailureContext(statusCode: 429, retryAfter: retryAfter),
);
