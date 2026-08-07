// Port of `store/mod.rs`'s in-file tests (inventory-core.md §src/store/mod.rs):
// the schema-fingerprint wipe-and-recreate lifecycle — the pre-1.0 safety net.
// Each test names the specific failure it prevents; the whole point is that a
// schema change must never silently brick or silently destroy a user's cache.
//
// Adaptation: the reference stamps its fingerprint in `PRAGMA user_version`;
// the Dart port uses `PRAGMA application_id` because drift owns user_version
// (see database.dart). The ported assertions therefore read application_id.
import 'dart:io';

import 'package:axiotask/src/store/database.dart';
import 'package:axiotask/src/store/store_error.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// The OLD schema: tasks WITHOUT web_view_link / base_* columns, task_lists
// present. Mirrors the reference's `old_schema_db` fixture.
const _oldTaskLists =
    'CREATE TABLE task_lists (id TEXT PRIMARY KEY, title TEXT NOT NULL, '
    'etag TEXT, updated TEXT NOT NULL, local_updated TEXT NOT NULL, '
    'sync_state TEXT NOT NULL, pending_op TEXT, '
    'local_only INTEGER NOT NULL DEFAULT 0)';
const _oldTasks =
    'CREATE TABLE tasks (id TEXT PRIMARY KEY, list_id TEXT NOT NULL, '
    'parent_id TEXT, position TEXT NOT NULL, title TEXT NOT NULL, notes TEXT, '
    'status TEXT NOT NULL, due TEXT, completed_at TEXT, etag TEXT, '
    'updated TEXT NOT NULL, local_updated TEXT NOT NULL, '
    'sync_state TEXT NOT NULL, pending_op TEXT)';

/// Construct an AppDatabase over [file] WITHOUT running the schema lifecycle, so
/// a test can plant an old/legacy schema before reconciling.
AppDatabase _rawFileDb(File file) => AppDatabase(
  NativeDatabase(file, setup: (raw) => raw.execute('PRAGMA foreign_keys = ON')),
);

AppDatabase _rawMemDb() => AppDatabase(
  NativeDatabase.memory(
    setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
  ),
);

/// Plant the OLD schema and stamp a stale fingerprint so `prepareSchema` treats
/// the database as incompatible (mismatch, not an accidental unstamped 0).
Future<void> _seedOldSchema(AppDatabase db, {int staleAppId = 3}) async {
  await db.customStatement(_oldTaskLists);
  await db.customStatement(_oldTasks);
  await db.customStatement('PRAGMA application_id = $staleAppId');
}

Future<int> _count(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingle()).read<int>('n');

List<File> _prewipeBackups(Directory dir) =>
    dir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.last;
      return name.startsWith('axiotask-prewipe-') && name.endsWith('.json');
    }).toList();

void main() {
  // Several tests deliberately construct more than one AppDatabase (a reopen, or
  // two independent in-memory DBs for the schema guard). Each uses its OWN
  // executor, so drift's shared-executor race warning is a false positive here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('open / fingerprint', () {
    test('open_memory_succeeds_and_schema_exists', () async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final n = await _count(
        db,
        "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name='tasks'",
      );
      expect(n, 1, reason: 'fresh in-memory DB must have the tasks table');
    });

    test('open_stamps_the_schema_fingerprint', () async {
      // A fresh database is stamped with the current fingerprint (a non-zero
      // value), not left at the default 0. (application_id, not user_version.)
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final row = await db.customSelect('PRAGMA application_id').getSingle();
      final stamped = row.read<int>('application_id');
      expect(stamped, isNot(0), reason: 'fresh DB must be stamped');
      expect(stamped, schemaFingerprint());
    });

    test('reopen_of_current_db_preserves_data', () async {
      // Fingerprint match ⇒ no wipe. Data written to a current-schema DB must
      // survive a reopen; the store must not wipe-and-recreate on every launch.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final db1 = await AppDatabase.open(file);
      await db1.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Inbox','u','lu','clean')",
      );
      await db1.close();

      final db2 = await AppDatabase.open(file);
      addTearDown(db2.close);
      final n = await _count(db2, 'SELECT COUNT(*) AS n FROM task_lists');
      expect(n, 1, reason: 'data must survive a reopen');
      final id =
          (await db2.customSelect('SELECT id FROM task_lists').getSingle())
              .read<String>('id');
      expect(id, 'L1');
      expect(
        _prewipeBackups(dir),
        isEmpty,
        reason: 'an unchanged schema must not trigger a backup/wipe',
      );
    });

    test('fresh_db_is_not_backed_up', () async {
      // Creating a brand-new database has nothing to export: no pre-wipe file.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = await AppDatabase.open(File('${dir.path}/axiotask.sqlite'));
      addTearDown(db.close);
      expect(
        _prewipeBackups(dir),
        isEmpty,
        reason: 'a fresh DB must not produce a pre-wipe backup',
      );
    });
  });

  group('incompatible schema → export, wipe, recreate', () {
    test('incompatible_schema_is_exported_then_wiped_and_recreated', () async {
      // #126: a schema change silently bricks an existing DB. Model a DB a prior
      // build created/stamped, whose tasks table predates the current columns.
      // Non-happy path: the fixture holds a parent task AND a child subtask.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final seed = _rawFileDb(file);
      await _seedOldSchema(seed);
      await seed.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Old Inbox','u','lu','clean')",
      );
      await seed.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('P1','L1','1','Parent survives','needsAction','u','lu','clean')",
      );
      await seed.customStatement(
        'INSERT INTO tasks (id,list_id,parent_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('C1','L1','P1','1','Child subtask','needsAction','u','lu','clean')",
      );
      await seed.close();

      // Reopen through the real entry point.
      final db = await AppDatabase.open(file);
      addTearDown(db.close);

      // 1. Recreated with the CURRENT schema (new column present).
      final hasCol = await _count(
        db,
        "SELECT COUNT(*) AS n FROM pragma_table_info('tasks') WHERE name='web_view_link'",
      );
      expect(
        hasCol,
        1,
        reason: 'recreated tasks table must have the new column',
      );
      final stamped =
          (await db.customSelect('PRAGMA application_id').getSingle())
              .read<int>('application_id');
      expect(stamped, schemaFingerprint(), reason: 'must be re-stamped');

      // 2. The stale cache is gone (Google is the source of truth).
      expect(
        await _count(db, 'SELECT COUNT(*) AS n FROM task_lists'),
        0,
        reason: 'incompatible DB must be wiped clean',
      );

      // 3. The old data was exported before the wipe — parent AND child, so
      //    nothing local is lost silently.
      final backups = _prewipeBackups(dir);
      expect(backups.length, 1, reason: 'exactly one pre-wipe backup expected');
      final json = backups.single.readAsStringSync();
      expect(json, contains('Old Inbox'));
      expect(json, contains('Parent survives'));
      expect(json, contains('Child subtask'));
    });

    test('wipe_and_recreate_drops_stale_views_and_triggers', () async {
      // #133: a table-only wipe leaves a standalone VIEW (and any INSTEAD OF
      // trigger on it) behind, lingering as a stale object in the recreated DB.
      // The wipe must drop views and triggers too. Non-happy path: the old DB
      // carries objects the current schema does not define at all.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final seed = _rawFileDb(file);
      await _seedOldSchema(seed);
      await seed.customStatement(
        'CREATE VIEW v_legacy AS SELECT id, title FROM tasks',
      );
      await seed.customStatement(
        'CREATE TRIGGER trg_legacy INSTEAD OF INSERT ON v_legacy BEGIN SELECT 1; END',
      );
      await seed.close();

      final db = await AppDatabase.open(file);
      addTearDown(db.close);
      expect(
        await _count(
          db,
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='view'",
        ),
        0,
        reason: 'a schema wipe must drop stale views',
      );
      expect(
        await _count(
          db,
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='trigger'",
        ),
        0,
        reason: 'a schema wipe must drop stale triggers',
      );
    });

    test('cascade_delete_still_works_after_a_wipe', () async {
      // Invariant #3: deletes cascade. The wipe toggles PRAGMA foreign_keys
      // OFF/ON — this proves the connection is not left FK-disabled, which would
      // silently orphan subtasks on delete.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final seed = _rawFileDb(file);
      await seed.customStatement('CREATE TABLE legacy (x TEXT)');
      await seed.customStatement('PRAGMA application_id = 3');
      await seed.close();

      final db = await AppDatabase.open(file);
      addTearDown(db.close);
      await db.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Inbox','u','lu','clean')",
      );
      await db.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('P1','L1','1','Parent','needsAction','u','lu','clean')",
      );
      await db.customStatement(
        'INSERT INTO tasks (id,list_id,parent_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('C1','L1','P1','1','Child','needsAction','u','lu','clean')",
      );

      await db.customStatement("DELETE FROM tasks WHERE id='P1'");
      expect(
        await _count(db, "SELECT COUNT(*) AS n FROM tasks WHERE id='C1'"),
        0,
        reason: 'child subtask must cascade-delete after a wipe (FK left ON)',
      );
    });
  });

  group('#129 backup-failure fail-open policy', () {
    test('wipe_aborts_when_backup_fails_and_local_only_data_at_risk', () async {
      // A schema change must NOT wipe local data Google does not have (a
      // local-only list) unless the pre-wipe backup is durably on disk. With
      // the backup write forced to fail, open must FAIL OPEN — abort and leave
      // the at-risk data untouched — not silently destroy it.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final db = _rawFileDb(file);
      addTearDown(db.close);
      await _seedOldSchema(db);
      await db.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state,local_only) '
        "VALUES ('L1','My private list','u','lu','clean',1)",
      );
      await db.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('T1','L1','1','Only here','needsAction','u','lu','clean')",
      );

      // Backup target dir does not exist ⇒ the durable write cannot succeed.
      final unwritable = '${dir.path}/no-such-dir/axiotask.sqlite';
      await expectLater(
        db.prepareSchema(backupDbPath: unwritable),
        throwsA(isA<WipeAborted>()),
      );

      expect(
        await _count(
          db,
          'SELECT COUNT(*) AS n FROM task_lists WHERE local_only = 1',
        ),
        1,
        reason: 'the local-only list must survive the aborted wipe',
      );
      expect(
        await _count(db, 'SELECT COUNT(*) AS n FROM tasks'),
        1,
        reason: 'the local-only task must survive the aborted wipe',
      );
      expect(
        _prewipeBackups(dir),
        isEmpty,
        reason: 'a failed backup must not leave a file behind',
      );
    });

    test('wipe_aborts_when_backup_fails_and_dirty_edits_at_risk', () async {
      // Unpushed edits (sync_state != 'clean') are also not yet on Google, so
      // they are at risk and must block a backup-less wipe.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final db = _rawFileDb(file);
      addTearDown(db.close);
      await _seedOldSchema(db);
      await db.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Inbox','u','lu','clean')",
      );
      await db.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state,pending_op) '
        "VALUES ('T1','L1','1','Edited offline','needsAction','u','lu','dirty','update')",
      );

      final unwritable = '${dir.path}/no-such-dir/axiotask.sqlite';
      await expectLater(
        db.prepareSchema(backupDbPath: unwritable),
        throwsA(isA<WipeAborted>()),
      );
      expect(
        await _count(
          db,
          "SELECT COUNT(*) AS n FROM tasks WHERE sync_state <> 'clean'",
        ),
        1,
        reason: 'the dirty edit must survive the aborted wipe',
      );
    });

    test('clean_cache_wipes_best_effort_even_when_backup_fails', () async {
      // A fully-synced cache holds nothing Google does not already have, so it
      // may still be wiped-and-recreated even when the pre-wipe backup cannot
      // be written — a schema change must not brick startup for the common case.
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/axiotask.sqlite');

      final db = _rawFileDb(file);
      addTearDown(db.close);
      await _seedOldSchema(db);
      await db.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Inbox','u','lu','clean')",
      );
      await db.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('T1','L1','1','Synced task','needsAction','u','lu','clean')",
      );

      final unwritable = '${dir.path}/no-such-dir/axiotask.sqlite';
      await db.prepareSchema(backupDbPath: unwritable); // must NOT throw

      expect(
        await _count(
          db,
          "SELECT COUNT(*) AS n FROM pragma_table_info('tasks') WHERE name='web_view_link'",
        ),
        1,
        reason: 'clean cache must be recreated on the new schema',
      );
      expect(
        await _count(db, 'SELECT COUNT(*) AS n FROM tasks'),
        0,
        reason: 'clean cache must be wiped clean',
      );
    });

    test('has_unsynced_local_data_distinguishes_clean_from_at_risk', () async {
      // Exercise the at-risk detector directly across its branches.
      final clean = _rawMemDb();
      addTearDown(clean.close);
      await _seedOldSchema(clean);
      await clean.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state) '
        "VALUES ('L1','Inbox','u','lu','clean')",
      );
      await clean.customStatement(
        'INSERT INTO tasks (id,list_id,position,title,status,updated,local_updated,sync_state) '
        "VALUES ('T1','L1','1','Synced','needsAction','u','lu','clean')",
      );
      expect(
        await clean.hasUnsyncedLocalData(),
        isFalse,
        reason: 'a fully-synced cache is not at risk',
      );

      final local = _rawMemDb();
      addTearDown(local.close);
      await _seedOldSchema(local);
      await local.customStatement(
        'INSERT INTO task_lists (id,title,updated,local_updated,sync_state,local_only) '
        "VALUES ('L1','Private','u','lu','clean',1)",
      );
      expect(
        await local.hasUnsyncedLocalData(),
        isTrue,
        reason: 'a local-only list is at risk',
      );
    });
  });

  group('schema integrity', () {
    test('open_creates_exactly_the_five_tables_and_three_indexes', () async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final tables =
          (await db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type='table' "
                    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
                  )
                  .get())
              .map((r) => r.read<String>('name'))
              .toList();
      expect(
        tables,
        containsAll(<String>[
          'inflight_creates',
          'pending_moves',
          'sync_log',
          'task_lists',
          'tasks',
        ]),
      );
      expect(tables.length, 5, reason: 'exactly five tables');
      final indexes =
          (await db
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type='index' "
                    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
                  )
                  .get())
              .map((r) => r.read<String>('name'))
              .toList();
      expect(indexes, ['idx_tasks_dirty', 'idx_tasks_due', 'idx_tasks_tree']);
    });

    test('schema_source_matches_drift_schema', () async {
      // Guard: `schemaStatements` (the fingerprint + creation source) must
      // describe the SAME schema drift generates from schema.drift (used by the
      // typed query layer in T1.3). If they diverge, a schema change could slip
      // past the fingerprint (no wipe) OR the typed queries could mismatch the
      // runtime schema — this test fails first.
      final fromStatements = _rawMemDb();
      addTearDown(fromStatements.close);
      for (final stmt in schemaStatements) {
        await fromStatements.customStatement(stmt);
      }

      final fromDrift = _rawMemDb();
      addTearDown(fromDrift.close);
      await fromDrift.createMigrator().createAll();

      expect(
        await _schemaSnapshot(fromStatements),
        await _schemaSnapshot(fromDrift),
      );
    });

    test('open_file_uses_wal_journal', () async {
      final dir = Directory.systemTemp.createTempSync('axiotask_store');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = await AppDatabase.open(File('${dir.path}/axiotask.sqlite'));
      addTearDown(db.close);
      final mode = (await db.customSelect('PRAGMA journal_mode').getSingle())
          .read<String>('journal_mode');
      expect(mode.toLowerCase(), 'wal');
    });
  });
}

/// Normalized structural snapshot (tables → columns, plus indexes) used by the
/// schema-source guard. Compares structure, not DDL text, so formatting
/// differences between the two creation paths do not matter.
Future<Map<String, Object?>> _schemaSnapshot(AppDatabase db) async {
  final tables =
      (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name NOT LIKE 'sqlite_%' ORDER BY name",
              )
              .get())
          .map((r) => r.read<String>('name'))
          .toList();
  final result = <String, Object?>{};
  for (final name in tables) {
    final cols = await db
        .customSelect("SELECT * FROM pragma_table_info('$name') ORDER BY cid")
        .get();
    result['table:$name'] = [
      for (final c in cols)
        '${c.read<String>('name')} ${c.read<String>('type')} '
            'notnull=${c.read<int>('notnull')} pk=${c.read<int>('pk')} '
            'dflt=${c.data['dflt_value']}',
    ];
  }
  result['indexes'] =
      (await db
              .customSelect(
                "SELECT name, tbl_name FROM sqlite_master WHERE type='index' "
                "AND name NOT LIKE 'sqlite_%' ORDER BY name",
              )
              .get())
          .map(
            (r) => '${r.read<String>('name')} on ${r.read<String>('tbl_name')}',
          )
          .toList();
  return result;
}
