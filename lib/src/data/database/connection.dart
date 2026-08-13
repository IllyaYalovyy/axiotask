import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

const Duration databaseBusyTimeout = Duration(seconds: 5);
const int databaseWalAutoCheckpointPages = 1000;

enum SqliteSynchronous { off, normal, full, extra }

final class PragmaSettings {
  const PragmaSettings({
    required this.foreignKeys,
    required this.journalMode,
    required this.synchronous,
    required this.busyTimeout,
    required this.walAutoCheckpointPages,
  });

  final bool foreignKeys;
  final String journalMode;
  final SqliteSynchronous synchronous;
  final Duration busyTimeout;
  final int walAutoCheckpointPages;
}

final class WalCheckpointResult {
  const WalCheckpointResult({
    required this.busyFrames,
    required this.logFrames,
    required this.checkpointedFrames,
  });

  final int busyFrames;
  final int logFrames;
  final int checkpointedFrames;
}

QueryExecutor createFileDatabaseConnection(File file) {
  return NativeDatabase.createInBackground(
    file,
    setup: configureSqliteConnection,
  );
}

QueryExecutor createInMemoryDatabaseConnection() {
  return NativeDatabase.memory(setup: configureSqliteConnection);
}

void configureSqliteConnection(CommonDatabase database) {
  database
    ..execute('PRAGMA foreign_keys = ON')
    ..execute('PRAGMA journal_mode = WAL')
    ..execute('PRAGMA synchronous = FULL')
    ..execute('PRAGMA busy_timeout = ${databaseBusyTimeout.inMilliseconds}')
    ..execute('PRAGMA wal_autocheckpoint = $databaseWalAutoCheckpointPages');
}

Future<File> resolveProductionDatabaseFile(String databaseName) async {
  if (!_validDatabaseName.hasMatch(databaseName)) {
    throw ArgumentError.value(
      databaseName,
      'databaseName',
      'must be a simple .sqlite filename',
    );
  }

  final supportDirectory = await getApplicationSupportDirectory();
  return File('${supportDirectory.path}${Platform.pathSeparator}$databaseName');
}

final RegExp _validDatabaseName = RegExp(r'^[a-z0-9][a-z0-9.-]*\.sqlite$');

SqliteSynchronous sqliteSynchronousFromPragma(int value) {
  return switch (value) {
    0 => SqliteSynchronous.off,
    1 => SqliteSynchronous.normal,
    2 => SqliteSynchronous.full,
    3 => SqliteSynchronous.extra,
    _ => throw StateError('Unsupported SQLite synchronous setting.'),
  };
}
