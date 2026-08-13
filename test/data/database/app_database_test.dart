import 'dart:async';

import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/connection.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.inMemory();
  });

  tearDown(() async {
    await database.close();
  });

  test('enforces account identity and foreign keys', () async {
    final accountId = await database.createAccount('synthetic-subject-a');

    expect(accountId, greaterThan(0));
    expect(
      database.createAccount('synthetic-subject-a'),
      throwsA(isA<SqliteException>()),
    );
    expect(database.createAccount(''), throwsA(isA<SqliteException>()));

    await database.customStatement('''
      CREATE TABLE constraint_probe (
        account_id INTEGER NOT NULL REFERENCES accounts(id)
      )
    ''');
    expect(
      database.customStatement(
        'INSERT INTO constraint_probe (account_id) VALUES (?)',
        <Object>[accountId + 1],
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('commits and rolls back complete transactions', () async {
    await database.transaction(() async {
      await database.createAccount('synthetic-committed');
    });

    expect(
      () => database.transaction(() async {
        await database.createAccount('synthetic-rolled-back');
        throw const _RollbackProbe();
      }),
      throwsA(isA<_RollbackProbe>()),
    );

    final subjects = (await database.allAccounts())
        .map((account) => account.googleSubject)
        .toList();
    expect(subjects, <String>['synthetic-committed']);
  });

  test('reactive account query emits committed changes', () async {
    final firstEmission = Completer<List<Account>>();
    final secondEmission = Completer<List<Account>>();
    final subscription = database.watchAccounts().listen((accounts) {
      if (!firstEmission.isCompleted) {
        firstEmission.complete(accounts);
      } else if (!secondEmission.isCompleted) {
        secondEmission.complete(accounts);
      }
    });
    addTearDown(subscription.cancel);

    expect(await firstEmission.future, isEmpty);
    await database.createAccount('synthetic-stream');
    expect(
      await secondEmission.future,
      predicate<List<Account>>(
        (accounts) =>
            accounts.length == 1 &&
            accounts.single.googleSubject == 'synthetic-stream',
      ),
    );
  });

  test('selects strict connection pragmas for an in-memory store', () async {
    final settings = await database.readPragmaSettings();

    expect(settings.foreignKeys, isTrue);
    expect(settings.busyTimeout.inMilliseconds, 5000);
    expect(settings.synchronous, SqliteSynchronous.full);
    expect(settings.journalMode, 'memory');
    expect(settings.walAutoCheckpointPages, 1000);
  });
}

final class _RollbackProbe implements Exception {
  const _RollbackProbe();
}
