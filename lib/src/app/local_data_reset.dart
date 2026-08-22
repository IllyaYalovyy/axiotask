// The account-switch reset (#215) — the local half of "switch to another
// Google account": sign out, ERASE everything this device holds, sign in with
// the other account, pull it fresh.
//
// This is the only irreversible operation the product offers a user, so it is
// built around the rule the pre-1.0 wipe safety net already established (#129):
// nothing destructive runs until a recoverable artifact is durably on disk.
// Here that rule is absolute — a schema wipe may proceed backup-less when the
// cache holds nothing Google lacks, but this erase also destroys LOCAL-ONLY
// lists and tasks, which exist nowhere else. No dump ⇒ no erase, and the store
// is left exactly as it was.
//
// What survives: `config.json` and `prefs.json` (theme, view, sort, window
// size) live outside the database by design, so the app the user comes back to
// still looks and behaves like theirs.
//
// The order — dump, then erase — is load-bearing: the dump is taken from the
// live database, so it must complete before a single row is removed.

import '../store/database.dart';
import '../store/store.dart';
import 'logging.dart';

/// The erase was REFUSED or could not complete; the local data is untouched.
///
/// [message] is written for the user and is safe to render verbatim: it never
/// carries the database path or the raw IO error (both go to the log, #187).
class ResetAborted implements Exception {
  const ResetAborted(this.message);

  /// The user-facing sentence explaining that nothing was erased, and why.
  final String message;

  @override
  String toString() => message;
}

/// What an erase destroyed, and where the recovery copy landed — the receipt
/// the Account tab shows so the user is told what happened rather than left to
/// guess.
class ResetLocalDataResult {
  const ResetLocalDataResult({
    required this.dumpPath,
    required this.lists,
    required this.tasks,
  });

  /// Absolute path of the durable pre-reset dump.
  final String dumpPath;

  /// Lists erased (synced and local-only alike).
  final int lists;

  /// Visible tasks erased (across every list).
  final int tasks;
}

/// Erases every local row after writing the durable recovery dump.
class LocalDataReset {
  const LocalDataReset({
    required this.database,
    required this.store,
    required this.dbPath,
  });

  /// The open database — the dump is read straight out of it, schema-agnostic.
  final AppDatabase database;

  /// The store whose rows are erased.
  final Store store;

  /// The database file, so the dump lands beside it exactly as a pre-wipe
  /// backup does. Empty when the app was launched without a real file (there is
  /// then nowhere durable to put the dump, so the erase is refused).
  final String dbPath;

  /// Write the recovery dump, then erase every local list, task, push drain and
  /// sync-log row. Throws [ResetAborted] — with the data untouched — when the
  /// dump cannot be written durably.
  Future<ResetLocalDataResult> run() async {
    if (dbPath.isEmpty) {
      Log.error('local-data reset refused: no database file path is known');
      throw const ResetAborted(
        'The local data was NOT erased: this app instance has no database file '
        'to write a recovery copy beside.',
      );
    }

    // Counted BEFORE the erase — the receipt describes what was destroyed.
    final lists = (await store.allLists()).length;
    final tasks = (await store.allTasks()).length;

    final String dumpPath;
    try {
      // The `!` is safe: a non-empty dbPath always yields a path or throws.
      dumpPath = (await database.writeRawDump(
        label: 'prereset',
        dbPath: dbPath,
      ))!;
    } on RawDumpFailed catch (e) {
      // The raw reason names the target path, so it goes to the log only.
      Log.error('local-data reset refused: recovery copy failed (${e.reason})');
      throw const ResetAborted(
        'The local data was NOT erased: the recovery copy could not be written '
        'to disk. Free up space or fix the permissions on the data directory, '
        'then try again.',
      );
    }

    await store.resetLocalData();
    Log.info(
      'local data erased ($lists list(s), $tasks task(s)); '
      'recovery copy written',
    );
    return ResetLocalDataResult(dumpPath: dumpPath, lists: lists, tasks: tasks);
  }
}
