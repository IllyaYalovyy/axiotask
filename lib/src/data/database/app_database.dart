import 'dart:io';

import 'package:drift/drift.dart';

import 'connection.dart';
import 'schema_verifier.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: <Type>[
    Accounts,
    TaskListCacheRows,
    TaskCacheRows,
    TaskListRemoteBases,
    TaskRemoteBases,
    ScopeCompletenessRows,
    AccountPreferenceRows,
    DesiredStateRows,
    DesiredStateDependencyRows,
    DesiredStateAttemptRows,
    SyncRunRows,
    TaskDeleteGroupRows,
    TaskDeleteTombstoneRows,
    TaskDeleteSnapshotRows,
    TaskDueChangeGroupRows,
    TaskDueChangeSnapshotRows,
    BulkOperationRows,
    BulkOperationMemberRows,
    SyncFactRows,
    TaskListPreferenceRows,
    ViewPreferenceRows,
    AccountBackupImportManifestRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase._(super.executor);

  factory AppDatabase.inMemory() {
    return AppDatabase._(createInMemoryDatabaseConnection());
  }

  static Future<AppDatabase> openFile(File file) async {
    if (!file.parent.existsSync()) {
      throw const FileSystemException(
        'Database parent directory is unavailable.',
      );
    }
    verifyExistingDatabaseFile(file);
    final database = AppDatabase._(createFileDatabaseConnection(file));
    try {
      await database.schemaFingerprint();
      return database;
    } on Object {
      await database.close();
      rethrow;
    }
  }

  @override
  int get schemaVersion => currentDatabaseSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) {
      throw const SchemaVerificationException('migration_not_supported');
    },
    beforeOpen: (_) => _verifyOpenSchema(verifyVersion: false),
  );

  Future<int> createAccount(String googleSubject) {
    return into(
      accounts,
    ).insert(AccountsCompanion.insert(googleSubject: googleSubject));
  }

  Future<List<Account>> allAccounts() {
    return (select(accounts)..orderBy(<OrderingTerm Function(Accounts)>[
          (table) => OrderingTerm.asc(table.id),
        ]))
        .get();
  }

  Stream<List<Account>> watchAccounts() {
    return (select(accounts)..orderBy(<OrderingTerm Function(Accounts)>[
          (table) => OrderingTerm.asc(table.id),
        ]))
        .watch();
  }

  Future<PragmaSettings> readPragmaSettings() async {
    final foreignKeys = await _singlePragmaInt('foreign_keys');
    final journalMode = await _singlePragmaValue('journal_mode');
    final synchronous = await _singlePragmaInt('synchronous');
    final busyTimeout = await _singlePragmaInt('busy_timeout');
    final walAutoCheckpoint = await _singlePragmaInt('wal_autocheckpoint');

    return PragmaSettings(
      foreignKeys: foreignKeys == 1,
      journalMode: journalMode.toString().toLowerCase(),
      synchronous: sqliteSynchronousFromPragma(synchronous),
      busyTimeout: Duration(milliseconds: busyTimeout),
      walAutoCheckpointPages: walAutoCheckpoint,
    );
  }

  Future<WalCheckpointResult> checkpoint() async {
    final row = await customSelect(
      'PRAGMA wal_checkpoint(TRUNCATE)',
    ).getSingle();
    final values = row.data.values.toList(growable: false);
    if (values.length != 3 || values.any((value) => value is! int)) {
      throw StateError('Unexpected SQLite checkpoint result.');
    }
    return WalCheckpointResult(
      busyFrames: values[0]! as int,
      logFrames: values[1]! as int,
      checkpointedFrames: values[2]! as int,
    );
  }

  Future<String> schemaFingerprint() async {
    await _verifyOpenSchema();
    return expectedSchemaFingerprint;
  }

  Future<void> _verifyOpenSchema({bool verifyVersion = true}) {
    return verifyOpenDatabaseSchema((sql) async {
      final rows = await customSelect(sql).get();
      return rows.map((row) => row.data).toList(growable: false);
    }, verifyVersion: verifyVersion);
  }

  Future<int> _singlePragmaInt(String name) async {
    final value = await _singlePragmaValue(name);
    if (value is! int) {
      throw StateError('Unexpected SQLite pragma result.');
    }
    return value;
  }

  Future<Object?> _singlePragmaValue(String name) async {
    final row = await customSelect('PRAGMA $name').getSingle();
    if (row.data.length != 1) {
      throw StateError('Unexpected SQLite pragma result.');
    }
    return row.data.values.single;
  }
}
