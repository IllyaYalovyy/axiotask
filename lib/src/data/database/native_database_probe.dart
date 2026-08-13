import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'app_database.dart';
import 'connection.dart';
import 'schema_verifier.dart';

const String nativeDatabaseProbeSubject = 'synthetic-probe-subject';

final class NativeDatabaseProbeResult {
  const NativeDatabaseProbeResult({
    required this.sqliteVersion,
    required this.accountCount,
    required this.settings,
  });

  final String sqliteVersion;
  final int accountCount;
  final PragmaSettings settings;

  Map<String, Object> toRecord() => <String, Object>{
    'status': 'passed',
    'schemaVersion': currentDatabaseSchemaVersion,
    'accountCount': accountCount,
    'journalMode': settings.journalMode,
    'foreignKeys': settings.foreignKeys,
    'synchronous': settings.synchronous.name,
    'busyTimeoutMs': settings.busyTimeout.inMilliseconds,
    'walAutoCheckpointPages': settings.walAutoCheckpointPages,
    'sqliteVersion': sqliteVersion,
  };
}

Future<NativeDatabaseProbeResult> runNativeDatabaseProductionPathProbe(
  String instanceName,
) async {
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(instanceName)) {
    throw ArgumentError.value(
      instanceName,
      'instanceName',
      'must be a lowercase isolated probe name',
    );
  }
  final file = await resolveProductionDatabaseFile(
    'axiotask-native-database-probe-$instanceName.sqlite',
  );
  return runNativeDatabaseProbe(file);
}

Future<NativeDatabaseProbeResult> runNativeDatabaseProbe(File file) async {
  if (file.existsSync()) {
    throw StateError('The isolated database probe target already exists.');
  }

  AppDatabase? database;
  StreamSubscription<List<Account>>? subscription;
  try {
    database = await AppDatabase.openFile(file);
    final initialEmission = Completer<List<Account>>();
    final changedEmission = Completer<List<Account>>();
    subscription = database.watchAccounts().listen((accounts) {
      if (!initialEmission.isCompleted) {
        initialEmission.complete(accounts);
      } else if (!changedEmission.isCompleted) {
        changedEmission.complete(accounts);
      }
    });

    if ((await initialEmission.future).isNotEmpty) {
      throw StateError('The isolated database probe did not start empty.');
    }
    await database.transaction(() async {
      await database!.createAccount(nativeDatabaseProbeSubject);
    });
    if ((await changedEmission.future).length != 1) {
      throw StateError('The database stream did not publish the transaction.');
    }

    final settings = await database.readPragmaSettings();
    await database.checkpoint();
    await subscription.cancel();
    subscription = null;
    await database.close();
    database = null;

    final reopened = await AppDatabase.openFile(file);
    database = reopened;
    final accounts = await reopened.allAccounts();
    if (accounts.length != 1 ||
        accounts.single.googleSubject != nativeDatabaseProbeSubject) {
      throw StateError('The database probe did not reopen persisted state.');
    }

    return NativeDatabaseProbeResult(
      sqliteVersion: sqlite.sqlite3.version.libVersion,
      accountCount: accounts.length,
      settings: settings,
    );
  } finally {
    await subscription?.cancel();
    await database?.close();
    await _deleteProbeFiles(file);
  }
}

Future<void> _deleteProbeFiles(File databaseFile) async {
  for (final suffix in <String>['-wal', '-shm', '']) {
    final file = File('${databaseFile.path}$suffix');
    if (file.existsSync()) {
      await file.delete();
    }
  }
}
