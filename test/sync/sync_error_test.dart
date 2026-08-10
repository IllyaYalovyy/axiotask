// Port of `sync/error.rs`'s in-file tests: a sync-run failure classifies as
// transient only for retryable API errors, and as auth-expired only for a dead
// session (`invalid_grant`). The scheduler (T5.9) branches on both to decide
// silent-retry vs back-off vs needs-reauth, so a mis-classification here would
// churn or mis-fire the attention UI.

import 'package:axiotask/src/api/api_error.dart';
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
}
