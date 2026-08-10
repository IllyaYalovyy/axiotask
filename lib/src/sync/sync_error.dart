// Errors specific to a sync run — the Dart port of `sync/error.rs`.
//
// A sealed union so the scheduler (T5.9) can classify a run failure without
// stringly-typed matching. Most variants are recoverable on the next run;
// [SyncStoreError] failures are the only ones treated as fatal (a store that
// cannot be written will fail identically every run). In practice the engine
// swallows transient API errors and returns a partial [SyncOutcome], so a
// transient [SyncError] rarely reaches the scheduler — the classification
// exists so backoff/attention never mis-fires when one does.

import '../api/api_error.dart';
import '../store/store_error.dart';

/// What can go wrong during a sync run.
sealed class SyncError implements Exception {
  const SyncError();

  /// Whether this run failure is expected to clear itself on a later run with
  /// no user action (a network blip, a 5xx, a rate-limit). The scheduler
  /// retries these silently at the base cadence; everything else is permanent
  /// (store corruption, a non-retryable API rejection, an internal invariant)
  /// and fails identically on every retry until something changes.
  bool get isTransient => switch (this) {
    SyncApiError(:final error) => error.isTransient,
    _ => false,
  };

  /// Whether this failure means the stored session is dead and the user must
  /// sign in again (`invalid_grant`). This is its own UI state (needs-reauth)
  /// — neither a silent transient retry nor the generic "needs attention".
  bool get isAuthExpired => switch (this) {
    SyncApiError(:final error) => error is AuthExpired,
    _ => false,
  };
}

/// The underlying API call failed.
final class SyncApiError extends SyncError {
  const SyncApiError(this.error);

  /// The wrapped API error.
  final ApiError error;

  @override
  bool operator ==(Object other) =>
      other is SyncApiError && other.error == error;

  @override
  int get hashCode => Object.hash(SyncApiError, error);

  @override
  String toString() => 'SyncError.api($error)';
}

/// Local persistence failed.
final class SyncStoreError extends SyncError {
  const SyncStoreError(this.error);

  /// The wrapped store error.
  final StoreError error;

  @override
  bool operator ==(Object other) =>
      other is SyncStoreError && other.error == error;

  @override
  int get hashCode => Object.hash(SyncStoreError, error);

  @override
  String toString() => 'SyncError.store($error)';
}

/// Internal invariant violated. Should not happen in production.
final class SyncInternalError extends SyncError {
  const SyncInternalError(this.message);

  /// Human-readable detail.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is SyncInternalError && other.message == message;

  @override
  int get hashCode => Object.hash(SyncInternalError, message);

  @override
  String toString() => 'SyncError.internal($message)';
}
