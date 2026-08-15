import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/connection.dart';
import 'package:axiotask/src/data/database/schema_verifier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'axiotask-s02-database-',
    );
  });

  tearDown(() async {
    if (temporaryRoot.existsSync()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('closes and reopens the same durable account data', () async {
    final file = File('${temporaryRoot.path}/persistence.sqlite');
    final first = await AppDatabase.openFile(file);
    final originalId = await first.createAccount('synthetic-persistent');
    final settings = await first.readPragmaSettings();
    final checkpoint = await first.checkpoint();

    expect(settings.foreignKeys, isTrue);
    expect(settings.journalMode, 'wal');
    expect(settings.synchronous, SqliteSynchronous.full);
    expect(settings.busyTimeout.inMilliseconds, 5000);
    expect(settings.walAutoCheckpointPages, 1000);
    expect(checkpoint.busyFrames, 0);
    await first.close();

    final reopened = await AppDatabase.openFile(file);
    addTearDown(reopened.close);
    final accounts = await reopened.allAccounts();

    expect(accounts.single.id, originalId);
    expect(accounts.single.googleSubject, 'synthetic-persistent');
    expect(await reopened.schemaFingerprint(), expectedSchemaFingerprint);
  });

  test('WAL permits a concurrent reader during an uncommitted write', () async {
    final file = File('${temporaryRoot.path}/concurrent.sqlite');
    final writer = await AppDatabase.openFile(file);
    await writer.createAccount('synthetic-before-write');
    addTearDown(writer.close);

    final inserted = Completer<void>();
    final allowCommit = Completer<void>();
    final write = writer.transaction(() async {
      await writer.createAccount('synthetic-uncommitted');
      inserted.complete();
      await allowCommit.future;
    });

    await inserted.future;
    final reader = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    addTearDown(reader.close);
    expect(
      reader
          .select('SELECT google_subject FROM accounts ORDER BY id')
          .map((row) => row['google_subject']),
      <String>['synthetic-before-write'],
    );
    allowCommit.complete();
    await write;
    expect(
      reader
          .select('SELECT google_subject FROM accounts ORDER BY id')
          .map((row) => row['google_subject']),
      <String>['synthetic-before-write', 'synthetic-uncommitted'],
    );
  });

  test('rejects and preserves a malformed existing schema', () async {
    final file = File('${temporaryRoot.path}/malformed.sqlite');
    final malformed = sqlite.sqlite3.open(file.path)
      ..execute('CREATE TABLE accounts (wrong_column TEXT)')
      ..userVersion = 1;
    malformed.close();
    final before = file.readAsBytesSync();

    expect(
      AppDatabase.openFile(file),
      throwsA(isA<SchemaVerificationException>()),
    );

    expect(file.readAsBytesSync(), before);
    final preserved = sqlite.sqlite3.open(file.path);
    addTearDown(preserved.close);
    expect(
      preserved.select('PRAGMA table_info(accounts)').single['name'],
      'wrong_column',
    );
  });

  test('does not downgrade or recreate an unknown schema version', () async {
    final file = File('${temporaryRoot.path}/future.sqlite');
    final original = await AppDatabase.openFile(file);
    await original.createAccount('synthetic-future-version');
    await original.close();
    final futureSchema = sqlite.sqlite3.open(file.path)..userVersion = 2;
    futureSchema.close();

    expect(
      AppDatabase.openFile(file),
      throwsA(
        isA<SchemaVerificationException>().having(
          (error) => error.code,
          'code',
          'schema_version_mismatch',
        ),
      ),
    );

    final preserved = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    addTearDown(preserved.close);
    expect(preserved.userVersion, 2);
    expect(
      preserved.select('SELECT google_subject FROM accounts').single.values,
      contains('synthetic-future-version'),
    );
  });

  test('rejects and preserves a modified version-1 cache schema', () async {
    final file = File('${temporaryRoot.path}/modified-v1.sqlite');
    final original = await AppDatabase.openFile(file);
    await original.createAccount('synthetic-modified-schema');
    await original.close();
    final modified = sqlite.sqlite3.open(file.path)
      ..execute('ALTER TABLE tasks ADD COLUMN unexpected_value TEXT');
    modified.close();

    expect(
      AppDatabase.openFile(file),
      throwsA(
        isA<SchemaVerificationException>().having(
          (error) => error.code,
          'code',
          'schema_contract_mismatch',
        ),
      ),
    );

    final preserved = sqlite.sqlite3.open(
      file.path,
      mode: sqlite.OpenMode.readOnly,
    );
    addTearDown(preserved.close);
    expect(
      preserved.select('PRAGMA table_info(tasks)').map((row) => row['name']),
      contains('unexpected_value'),
    );
  });

  test('rejects and preserves a corrupt existing database', () async {
    final file = File('${temporaryRoot.path}/corrupt.sqlite');
    final corruptBytes = Uint8List.fromList(<int>[
      0x73,
      0x79,
      0x6e,
      0x74,
      0x68,
      0x65,
      0x74,
      0x69,
      0x63,
    ]);
    file.writeAsBytesSync(corruptBytes, flush: true);

    expect(
      AppDatabase.openFile(file),
      throwsA(isA<SchemaVerificationException>()),
    );

    expect(file.readAsBytesSync(), corruptBytes);
  });

  test('fails when the database parent path is unavailable', () async {
    final blockingFile = File('${temporaryRoot.path}/not-a-directory')
      ..writeAsStringSync('synthetic blocker', flush: true);
    final unavailable = File('${blockingFile.path}/database.sqlite');

    expect(
      AppDatabase.openFile(unavailable),
      throwsA(isA<FileSystemException>()),
    );
    expect(blockingFile.readAsStringSync(), 'synthetic blocker');
    expect(unavailable.existsSync(), isFalse);
  });
}
