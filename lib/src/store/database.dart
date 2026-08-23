// The local SQLite cache — the Dart port of `store/mod.rs`.
//
// Opens the drift database and enforces the schema-fingerprint
// wipe-and-recreate lifecycle. Pre-1.0 there are NO migrations (RFC-003): the
// store is a CACHE of Google Tasks, so a schema change does not evolve the DB
// in place — the cache is exported to JSON and recreated from scratch. This is
// the pre-1.0 safety net; it is never simplified. A schema wipe destroys the
// cache ONLY — config.json / prefs.json live outside it by design.
//
// Adaptation from the reference (documented): the reference stamps its schema
// fingerprint in SQLite's `PRAGMA user_version`. drift claims `user_version`
// for its own (unused-here) migration versioning, so the Dart port stores the
// fingerprint in the OTHER 32-bit header slot, `PRAGMA application_id`. Same
// semantics: a persistent header integer, mismatch ⇒ wipe-and-recreate.

import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../model/dates.dart';
import 'store_error.dart';

part 'database.g.dart';

/// The store schema as executable DDL — the SINGLE source of truth for both the
/// schema fingerprint AND runtime (re)creation. It MUST mirror `schema.drift`
/// (which drift codegen reads to generate the typed table classes); a guard
/// test (`schema_source_matches_drift_schema`) fails if the two diverge, which
/// is what keeps the fingerprint honest.
///
/// !!! SCHEMA-CHANGE WARNING !!! Editing these statements changes the
/// fingerprint, so on the next launch every existing database is exported to
/// JSON and wiped-and-recreated. Change them only for a real schema change, and
/// update `schema.drift` in lockstep.
const List<String> schemaStatements = [
  '''
CREATE TABLE task_lists (
  id              TEXT PRIMARY KEY,
  remote_id       TEXT UNIQUE,
  title           TEXT NOT NULL,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL),
  local_only      INTEGER NOT NULL DEFAULT 0
)''',
  '''
CREATE TABLE tasks (
  id              TEXT PRIMARY KEY,
  remote_id       TEXT UNIQUE,
  list_id         TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id       TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  position        TEXT NOT NULL,
  title           TEXT NOT NULL,
  notes           TEXT,
  status          TEXT NOT NULL CHECK (status IN ('needsAction','completed')),
  due             TEXT,
  completed_at    TEXT,
  etag            TEXT,
  updated         TEXT NOT NULL,
  local_updated   TEXT NOT NULL,
  sync_state      TEXT NOT NULL CHECK (sync_state IN ('clean','dirty','deleted')),
  pending_op      TEXT CHECK (pending_op IN ('create','update','delete') OR pending_op IS NULL),
  base_title      TEXT,
  base_notes      TEXT,
  base_due        TEXT,
  base_status     TEXT CHECK (base_status IN ('needsAction','completed') OR base_status IS NULL),
  web_view_link   TEXT
)''',
  'CREATE INDEX idx_tasks_tree  ON tasks(list_id, parent_id, position)',
  "CREATE INDEX idx_tasks_dirty ON tasks(sync_state) WHERE sync_state != 'clean'",
  'CREATE INDEX idx_tasks_due   ON tasks(due) WHERE due IS NOT NULL',
  '''
CREATE TABLE pending_moves (
  task_id     TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id     TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  parent_id   TEXT,
  previous_id TEXT
)''',
  // `error` holds a SyncFailureKind NAME, never provider or API text (#218):
  // the Sync activity screen reads this column, so anything written here is
  // user-visible. Write it through Store.writeSyncLog, which takes the enum.
  // (The column keeps its name: renaming it would change the schema
  // fingerprint and cost every user a full re-pull for no user-visible gain.)
  '''
CREATE TABLE sync_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ran_at      TEXT NOT NULL,
  duration_ms INTEGER,
  pulled      INTEGER NOT NULL DEFAULT 0,
  pushed      INTEGER NOT NULL DEFAULT 0,
  conflicts   INTEGER NOT NULL DEFAULT 0,
  error       TEXT
)''',
  '''
CREATE TABLE inflight_creates (
  local_id  TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
  list_id   TEXT NOT NULL REFERENCES task_lists(id) ON DELETE CASCADE,
  base_local_updated TEXT
)''',
];

/// Stable 32-bit fingerprint of the current schema, stored in the database
/// header's `application_id` slot. A database stamped with a different value is
/// from an incompatible schema. Never zero — 0 is the default of an unstamped
/// (fresh, or pre-fingerprint) database, which must be told apart from a match.
///
/// FNV-1a-32 over the canonical schema text: deterministic across launches (a
/// hard requirement — [DateTime.now]/[Object.hashCode] would not be), and it
/// flips on ANY schema edit, which is all the reset logic needs. The value is
/// codebase-internal, so it need not equal the reference crate's SHA-256 form.
int schemaFingerprint() {
  const int fnvOffset = 0x811c9dc5;
  const int fnvPrime = 0x01000193;
  var hash = fnvOffset;
  for (final byte in utf8.encode(schemaStatements.join(';\n'))) {
    hash ^= byte;
    hash = (hash * fnvPrime) & 0xFFFFFFFF;
  }
  final signed = hash.toSigned(32);
  return signed == 0 ? 1 : signed;
}

/// The local cache database. Schema creation and the fingerprint
/// wipe-and-recreate lifecycle are owned by [prepareSchema] (see class doc),
/// NOT drift's migrator, which is deliberately inert here.
@DriftDatabase(include: {'schema.drift'})
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Open a file-backed database (WAL, foreign keys on), creating the file if
  /// missing, then reconcile the schema (create fresh, or export-and-wipe an
  /// incompatible one). The pre-wipe JSON backup is written beside [file].
  static Future<AppDatabase> open(File file) async {
    final db = AppDatabase(_openFile(file));
    await db.prepareSchema(backupDbPath: file.path);
    return db;
  }

  /// Open an in-memory database (foreign keys on); useful for tests. Has no
  /// file and nothing to preserve, so a wipe never writes a backup.
  static Future<AppDatabase> openMemory() async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await db.prepareSchema();
    return db;
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    // Schema creation is owned by prepareSchema (the fingerprint lifecycle),
    // never drift's migrator. Both callbacks are intentionally inert.
    onCreate: (m) async {},
    onUpgrade: (m, from, to) async {},
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Make the schema current. Fast path: a database already stamped with the
  /// current fingerprint is left untouched. Otherwise the database is either
  /// fresh (create the schema and stamp it) or from an incompatible schema — in
  /// which case its contents are exported to JSON and it is wiped and
  /// recreated. Pre-1.0 there are no migrations.
  ///
  /// [backupDbPath] (the database file) is where the pre-wipe JSON backup is
  /// written; `null` for an in-memory database, which has nothing to preserve.
  /// Throws [WipeAborted] (fail open — data left intact) when an incompatible
  /// database holds local-only/unsynced data AND the pre-wipe backup cannot be
  /// written durably (#129).
  Future<void> prepareSchema({String? backupDbPath}) async {
    final stamped = await _readApplicationId();
    final expected = schemaFingerprint();
    if (stamped == expected) return;

    // Incompatible or fresh. If it already holds tables it is an old schema (or
    // a pre-fingerprint database): back it up, then wipe it clean. The wipe is
    // destructive, so it must not run unless the pre-wipe backup is durably on
    // disk — UNLESS the cache holds nothing Google lacks, in which case the
    // wipe-and-recreate is safe even without a backup (#129).
    if (await _hasUserTables()) {
      final outcome = await _exportBeforeWipe(backupDbPath);
      if (outcome is _BackupFailed) {
        if (await hasUnsyncedLocalData()) {
          throw WipeAborted(
            'Refusing to reset the local store after a schema change: it holds '
            'local-only or unsynced changes that are not yet saved to Google, '
            'and the pre-wipe backup could not be written to disk '
            '(${outcome.reason}). Your data has been left untouched. Free up '
            'disk space or fix file permissions for the data directory and '
            'restart.',
          );
        }
        // Fully synced with Google; wipe-and-recreate best-effort.
      }
      await _wipe();
    }

    for (final stmt in schemaStatements) {
      await customStatement(stmt);
    }
    await _stampApplicationId(expected);
  }

  /// Whether the (soon-to-be-wiped) database holds local state that is NOT
  /// recoverable from Google: local-only lists, unpushed dirty/deleted rows, or
  /// queued moves / in-flight creates. Used only when the pre-wipe backup could
  /// not be written — a fully-synced cache is safe to wipe without a backup
  /// (Google is the source of truth), but local-only/dirty data would be lost.
  ///
  /// Schema-agnostic and conservative: the database being inspected is from an
  /// OLDER schema, so a probe against a table that exists but errors is treated
  /// as "at risk" rather than assumed safe. Exposed so the at-risk detector can
  /// be exercised directly.
  Future<bool> hasUnsyncedLocalData() async {
    const probes = [
      ('task_lists', 'local_only = 1'),
      ('task_lists', "sync_state <> 'clean'"),
      ('tasks', "sync_state <> 'clean'"),
      ('tasks', 'pending_op IS NOT NULL'),
      ('pending_moves', '1 = 1'),
      ('inflight_creates', '1 = 1'),
    ];
    for (final (table, predicate) in probes) {
      if (await _anyRowMatches(table, predicate)) return true;
    }
    return false;
  }

  // ── internals ─────────────────────────────────────────────────────────────

  Future<int> _readApplicationId() async {
    final row = await customSelect('PRAGMA application_id').getSingle();
    return row.read<int>('application_id');
  }

  Future<void> _stampApplicationId(int value) async {
    // PRAGMA cannot be parameterized; the fingerprint is a trusted integer.
    await customStatement('PRAGMA application_id = $value');
  }

  Future<bool> _hasUserTables() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS n FROM sqlite_master '
      "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    ).getSingle();
    return row.read<int>('n') > 0;
  }

  /// True if [table] exists and holds at least one row matching [predicate]. A
  /// missing table ⇒ false (nothing there to lose). A query error against an
  /// existing table (e.g. a column the old schema lacks) ⇒ true (conservative:
  /// never destroy data we could not inspect). Both arguments are compile-time
  /// constants from [hasUnsyncedLocalData], never user input.
  Future<bool> _anyRowMatches(String table, String predicate) async {
    final exists = await customSelect(
      "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name = ?",
      variables: [Variable.withString(table)],
    ).getSingle();
    if (exists.read<int>('n') == 0) {
      return false; // table absent from old schema
    }
    try {
      final row = await customSelect(
        'SELECT EXISTS(SELECT 1 FROM "$table" WHERE $predicate) AS m',
      ).getSingle();
      return row.read<int>('m') != 0;
    } on Object {
      return true; // cannot even inspect: conservative
    }
  }

  /// Drop every user object — triggers, then views, then tables — so the schema
  /// can be recreated from scratch. Dropping only tables is not enough: a
  /// standalone view (and any INSTEAD OF trigger on it) is not attached to a
  /// table, so it would survive a table-only wipe and linger as a stale object
  /// (#133). Foreign keys are toggled OFF for the drop and restored to ON after
  /// so tables can go in any order without tripping a reference constraint.
  Future<void> _wipe() async {
    await customStatement('PRAGMA foreign_keys = OFF');
    for (final (kind, keyword) in [
      ('trigger', 'TRIGGER'),
      ('view', 'VIEW'),
      ('table', 'TABLE'),
    ]) {
      final objects = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%'",
        variables: [Variable.withString(kind)],
      ).get();
      for (final row in objects) {
        // `name` comes from sqlite_master, not user input; quote it defensively.
        final name = row.read<String>('name');
        await customStatement('DROP $keyword IF EXISTS "$name"');
      }
    }
    await customStatement('PRAGMA foreign_keys = ON');
  }

  /// JSON export of a soon-to-be-wiped database, written (and flushed) beside
  /// the database file. Returns whether the backup is durable so the caller can
  /// decide if the destructive wipe is safe (#129). An in-memory database
  /// ([backupDbPath] == null) has no file and nothing a user would miss, so it
  /// reports [_BackupDurable].
  Future<_BackupOutcome> _exportBeforeWipe(String? backupDbPath) async {
    if (backupDbPath == null) return const _BackupDurable();
    try {
      await writeRawDump(label: 'prewipe', dbPath: backupDbPath);
      return const _BackupDurable();
    } on RawDumpFailed catch (e) {
      return _BackupFailed(e.reason);
    }
  }

  /// Write a schema-agnostic JSON dump of every user table beside the database
  /// file at [dbPath], flushed to durable storage before returning, and return
  /// the path written. The file is named `axiotask-<label>-<stamp>.json`.
  ///
  /// This is the pre-1.0 wipe safety net (#129) exposed for reuse: any
  /// destructive step that empties the store leaves the SAME recoverable
  /// artifact a schema wipe does — the account-switch reset (#215) writes a
  /// `prereset` dump before erasing everything.
  ///
  /// Returns `null` when [dbPath] is `null` — an in-memory database has no file
  /// and nothing a user would miss. Throws (dump failure or write failure) so
  /// the caller can refuse to proceed with the destructive step; the message
  /// carries the target path, so it belongs in the LOG, never in a user-facing
  /// string (#187).
  Future<String?> writeRawDump({
    required String label,
    required String? dbPath,
  }) async {
    if (dbPath == null) return null;
    final String json;
    try {
      json = await _rawDumpJson(label);
    } on Object catch (e) {
      throw RawDumpFailed('dump: $e');
    }
    final out = _dumpPath(dbPath, label);
    try {
      await _writeDurably(out, utf8.encode(json));
    } on Object catch (e) {
      throw RawDumpFailed('write $out: $e');
    }
    return out;
  }

  /// Schema-agnostic dump of every user table to a single JSON document. Reads
  /// whatever columns exist (it cannot assume the current schema — that is the
  /// point); drift decodes each cell to a Dart value, and BLOBs are base64'd.
  Future<String> _rawDumpJson(String label) async {
    final tableRows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ).get();
    final tables = <String, Object?>{};
    for (final t in tableRows) {
      final table = t.read<String>('name');
      final rows = await customSelect('SELECT * FROM "$table"').get();
      tables[table] = [
        for (final row in rows)
          {for (final e in row.data.entries) e.key: _cellToJson(e.value)},
      ];
    }
    final doc = {
      'app': 'axiotask',
      'kind': '$label-raw-dump',
      'exported_at': nowUtcString(),
      'tables': tables,
    };
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  static String _dumpPath(String dbPath, String label) {
    final t = clock.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year.toString().padLeft(4, '0')}${pad(t.month)}${pad(t.day)}'
        '-${pad(t.hour)}${pad(t.minute)}${pad(t.second)}';
    final dir = File(dbPath).parent.path;
    return '$dir${Platform.pathSeparator}axiotask-$label-$stamp.json';
  }

  /// Write [bytes] to [path] and flush them to durable storage before
  /// returning. Without the flush, a plain write can report success while the
  /// bytes still sit in OS buffers — a crash would then lose the "backup" that a
  /// wipe was told had been taken (#129). Parent-directory fsync (the
  /// reference's extra guard) is not exposed by dart:io; the file flush is the
  /// guarantee. Throws when the target directory is missing/unwritable — the
  /// signal the caller turns into [_BackupFailed] or a refused reset.
  ///
  /// ASYNC: a full-store dump is not a small file, and this now runs from a
  /// user gesture (the account-switch reset, #215) as well as from startup. A
  /// synchronous write of that size on the UI isolate is an ANR risk on a phone
  /// — the same reason `BackupService.export` uses async IO.
  static Future<void> _writeDurably(String path, List<int> bytes) =>
      File(path).writeAsBytes(bytes, flush: true);
}

/// Decode one drift/SQLite cell into a JSON-encodable value; a BLOB
/// ([Uint8List]) becomes base64 so an unknown old column of any type
/// round-trips into the backup.
Object? _cellToJson(Object? value) {
  if (value is Uint8List) return base64.encode(value);
  return value; // int / double / String / null are already JSON-encodable
}

/// Setup applied to every raw connection: WAL journal (durable, concurrent
/// reads) and foreign keys ON (delete cascades). WAL is a no-op on in-memory
/// databases, which report `memory` as their journal mode. The closure's
/// parameter type is inferred from drift's `DatabaseSetup` typedef, so no
/// direct dependency on `package:sqlite3` is needed here.
QueryExecutor _openFile(File file) => NativeDatabase(
  file,
  setup: (raw) {
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute('PRAGMA foreign_keys = ON');
  },
);

/// The raw JSON dump could not be produced or durably written. [reason] carries
/// the target path / underlying IO error, so it is LOG material only — never a
/// user-facing string (#187). Deliberately outside the sealed [StoreError]
/// union: it is an internal signal callers turn into their own outcome (a
/// `_BackupFailed`, or a refused reset).
class RawDumpFailed implements Exception {
  const RawDumpFailed(this.reason);

  /// The underlying failure, including the target path.
  final String reason;

  @override
  String toString() => 'RawDumpFailed: $reason';
}

/// Outcome of the pre-wipe backup attempt, so the caller can decide whether the
/// destructive wipe is safe to proceed with (#129).
sealed class _BackupOutcome {
  const _BackupOutcome();
}

/// The backup is durably on disk, or there is nothing to preserve (an in-memory
/// database). Either way the wipe may proceed unconditionally.
class _BackupDurable extends _BackupOutcome {
  const _BackupDurable();
}

/// The backup could not be written durably; the wipe may only proceed if no
/// local-only/unsynced data is at risk.
class _BackupFailed extends _BackupOutcome {
  const _BackupFailed(this.reason);
  final String reason;
}
