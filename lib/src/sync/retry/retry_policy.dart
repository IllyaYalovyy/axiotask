import '../../core/failure.dart';
import '../../core/randomness.dart';

const int syncRequestAttemptLimit = 4;
const Duration syncRequestAttemptTimeout = Duration(seconds: 30);
const Duration syncRetryEpisodeBudget = Duration(minutes: 5);

final class SyncRetryPolicy {
  const SyncRetryPolicy(this.random);

  final RandomSource random;

  bool isAutomaticallyRetryable(Failure failure) =>
      failure.retry == RetryClassification.transient &&
      switch (failure.category) {
        FailureCategory.network ||
        FailureCategory.rateLimit ||
        FailureCategory.remote => true,
        _ => false,
      };

  Duration requestDelay(int retryNumber, Failure failure, DateTime now) {
    if (retryNumber < 1 || retryNumber >= syncRequestAttemptLimit) {
      throw RangeError.range(
        retryNumber,
        1,
        syncRequestAttemptLimit - 1,
        'retryNumber',
      );
    }
    final nominal = Duration(seconds: 1 << (retryNumber - 1));
    return _delay(nominal, failure, now);
  }

  Duration betweenRunDelay(int retryNumber, Failure failure, DateTime now) {
    if (retryNumber < 0) {
      throw RangeError.value(
        retryNumber,
        'retryNumber',
        'must not be negative',
      );
    }
    final exponent = retryNumber > 6 ? 6 : retryNumber;
    final seconds = 1 << exponent;
    final nominal = Duration(seconds: seconds > 60 ? 60 : seconds);
    return _delay(nominal, failure, now);
  }

  DateTime? serverNotBefore(Failure failure, DateTime now) {
    final retryAfter = failure.remoteContext?.retryAfter;
    return switch (retryAfter) {
      RetryAfterDelay(:final delay) when !delay.isNegative => now.toUtc().add(
        delay,
      ),
      RetryAfterDate(:final date) when date.toUtc().isAfter(now.toUtc()) =>
        date.toUtc(),
      _ => null,
    };
  }

  Duration _delay(Duration nominal, Failure failure, DateTime now) {
    final jitter = random.fullJitter(nominal);
    final notBefore = serverNotBefore(failure, now);
    if (notBefore == null) return jitter;
    final serverDelay = notBefore.difference(now.toUtc());
    return serverDelay > jitter ? serverDelay : jitter;
  }
}
