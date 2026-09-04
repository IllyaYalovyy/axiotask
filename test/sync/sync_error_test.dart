// Port of `sync/error.rs`'s in-file tests: a sync-run failure classifies as
// transient only for retryable API errors, and as auth-expired only for a dead
// session (`invalid_grant`). The scheduler (T5.9) branches on both to decide
// silent-retry vs back-off vs needs-reauth, so a mis-classification here would
// churn or mis-fire the attention UI.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/model/sync_run.dart';
import 'package:axiotask/src/store/store_error.dart';
import 'package:axiotask/src/sync/sync_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transient only for retryable API errors', () {
    expect(const SyncApiError(ServerError(503)).isTransient, isTrue);
    expect(const SyncApiError(Network('reset')).isTransient, isTrue);
    expect(const SyncApiError(RateLimited()).isTransient, isTrue);

    // Permanent API rejections are NOT transient.
    expect(const SyncApiError(OtherApiError('bad json')).isTransient, isFalse);
    expect(const SyncApiError(NotFound()).isTransient, isFalse);
    expect(const SyncApiError(PreconditionFailed()).isTransient, isFalse);
    // A dead session is its own state, not a transient.
    expect(
      const SyncApiError(AuthExpired('invalid_grant')).isTransient,
      isFalse,
    );
    // Store/internal failures fail identically forever — permanent.
    expect(const SyncStoreError(StoreSqlError('bug')).isTransient, isFalse);
    expect(const SyncInternalError('bug').isTransient, isFalse);
  });

  test('auth expired detected only for a dead session', () {
    expect(
      const SyncApiError(AuthExpired('invalid_grant')).isAuthExpired,
      isTrue,
    );
    expect(const SyncApiError(Unauthorized()).isAuthExpired, isFalse);
    expect(const SyncApiError(ServerError(500)).isAuthExpired, isFalse);
    expect(const SyncInternalError('bug').isAuthExpired, isFalse);
  });

  group('failureKind — the persisted, user-visible classification (#218)', () {
    // The Sync activity screen reads this classification straight out of
    // sync_log, so it is what a failed run tells the user. Collapsing every
    // failure into one code would make the history useless — a flaky network
    // and a broken local database would read identically — and mapping any of
    // them back to the provider's own text would leak it (#131/#187).
    test('each failure shape maps to its own kind', () {
      expect(
        const SyncApiError(Network('https://tasks…?key=SECRET')).failureKind,
        SyncFailureKind.network,
      );
      expect(
        const SyncApiError(AuthExpired('invalid_grant')).failureKind,
        SyncFailureKind.auth,
      );
      expect(
        const SyncApiError(Unauthorized()).failureKind,
        SyncFailureKind.unauthorized,
      );
      expect(
        const SyncApiError(RateLimited()).failureKind,
        SyncFailureKind.rateLimited,
      );
      expect(
        const SyncApiError(ServerError(503)).failureKind,
        SyncFailureKind.server,
      );
      expect(
        const SyncApiError(NotFound()).failureKind,
        SyncFailureKind.notFound,
      );
      expect(
        const SyncApiError(PreconditionFailed()).failureKind,
        SyncFailureKind.precondition,
      );
      expect(
        const SyncStoreError(StoreSqlError('no such column: foo')).failureKind,
        SyncFailureKind.store,
      );
      expect(
        const SyncInternalError('invariant broken').failureKind,
        SyncFailureKind.internal,
      );
      // Provider text we refuse to interpret is the catch-all — never its own
      // pass-through kind.
      expect(
        const SyncApiError(OtherApiError('<html>SECRET</html>')).failureKind,
        SyncFailureKind.unknown,
      );
    });

    test('no kind\'s label carries the failure\'s own detail', () {
      // The label is a function of the enum alone, so this holds for EVERY
      // failure that could ever reach the screen — including one whose detail
      // is a captive portal's HTML login page.
      const leaky =
          '<!DOCTYPE html><html>sign in at '
          'http://wifi.local/login?token=SECRET</html>';
      for (final e in <SyncError>[
        const SyncApiError(OtherApiError(leaky)),
        const SyncApiError(Network(leaky)),
        const SyncApiError(AuthExpired(leaky)),
        const SyncStoreError(StoreSqlError(leaky)),
        const SyncInternalError(leaky),
      ]) {
        final label = syncFailureLabel(e.failureKind);
        expect(label, isNot(contains('SECRET')));
        expect(label, isNot(contains('wifi.local')));
        expect(label, isNot(contains('<html')));
        expect(label, isNotEmpty);
      }
    });
  });

  group('SyncError.coerce — nothing escapes the union (#270)', () {
    test('typed failures keep their identity', () {
      expect(
        SyncError.coerce(const ServerError(503)),
        const SyncApiError(ServerError(503)),
      );
      expect(
        SyncError.coerce(const StoreSqlError('no such column: foo')),
        const SyncStoreError(StoreSqlError('no such column: foo')),
      );
      // Already coerced: idempotent, and never double-wrapped.
      const already = SyncInternalError('boom');
      expect(identical(SyncError.coerce(already), already), isTrue);
    });

    test(
      'an UNTYPED throw still classifies as a permanent internal failure',
      () {
        // The whole point: a raw SqliteException out of a store write, a
        // TypeError out of a decode. Before #270 these slipped past every
        // `on SyncError` guard, killing the startup task and the background loop
        // with it, and leaving the status with nothing to report.
        final coerced = SyncError.coerce(
          Exception('SqliteException(13): database or disk is full'),
        );
        expect(coerced, isA<SyncInternalError>());
        expect(
          coerced.isTransient,
          isFalse,
          reason: 'an unrecognized failure repeats until something changes',
        );
        expect(coerced.isAuthExpired, isFalse);
        expect(coerced.failureKind, SyncFailureKind.internal);
      },
    );
  });
}
