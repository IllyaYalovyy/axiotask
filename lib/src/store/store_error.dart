// Errors surfaced by the store — the Dart port of `store/error.rs`. A sealed
// union so callers can exhaustively switch (mirrors the reference's
// `enum StoreError`). `WipeAborted` is the pre-1.0 fail-open safety net: a
// schema-change wipe is refused when the cache holds data not yet on Google and
// the pre-wipe backup could not be written durably (see `database.dart`).

/// Persistence-layer error base. Sealed: exhaustively matchable.
sealed class StoreError implements Exception {
  const StoreError(this.message);

  /// Human-readable detail.
  final String message;

  @override
  String toString() => 'StoreError: $message';
}

/// Could not open / create the database file.
class StoreOpenError extends StoreError {
  const StoreOpenError(super.message);
}

/// Preparing the schema (create / wipe-and-recreate) failed.
class StoreMigrateError extends StoreError {
  const StoreMigrateError(super.message);
}

/// A pre-1.0 wipe-and-recreate was refused because the local store holds data
/// not yet on Google (local-only or unsynced) and the pre-wipe backup could not
/// be written durably to disk. Startup fails open — the data is left intact —
/// rather than destroy it silently (#129).
class WipeAborted extends StoreError {
  const WipeAborted(super.message);
}

/// Underlying SQL execution failed.
class StoreSqlError extends StoreError {
  const StoreSqlError(super.message);
}
