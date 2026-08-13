import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

const int currentDatabaseSchemaVersion = 1;
const String expectedSchemaFingerprint =
    'axiotask-schema-v1:accounts(id,google_subject)';

final class SchemaVerificationException implements Exception {
  const SchemaVerificationException(this.code);

  final String code;

  @override
  String toString() => 'SchemaVerificationException($code)';
}

void verifyExistingDatabaseFile(File file) {
  if (!file.existsSync()) {
    return;
  }

  sqlite.Database? database;
  try {
    database = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    _verifyRawDatabase(database);
  } on SchemaVerificationException {
    rethrow;
  } on Object {
    throw const SchemaVerificationException('database_unreadable');
  } finally {
    database?.close();
  }
}

void _verifyRawDatabase(sqlite.Database database) {
  if (database.userVersion != currentDatabaseSchemaVersion) {
    throw const SchemaVerificationException('schema_version_mismatch');
  }

  final integrity = database.select('PRAGMA quick_check');
  if (integrity.length != 1 || integrity.single.values.single != 'ok') {
    throw const SchemaVerificationException('integrity_check_failed');
  }
  if (database.select('PRAGMA foreign_key_check').isNotEmpty) {
    throw const SchemaVerificationException('foreign_key_check_failed');
  }

  final schema = database.select(_schemaContractQuery);
  _verifySchemaContract(schema.map((row) => row.values.toList()).toList());
}

Future<void> verifyOpenDatabaseSchema(
  Future<List<Map<String, Object?>>> Function(String sql) select, {
  bool verifyVersion = true,
}) async {
  if (verifyVersion) {
    final versionRows = await select('PRAGMA user_version');
    if (_singleInt(versionRows) != currentDatabaseSchemaVersion) {
      throw const SchemaVerificationException('schema_version_mismatch');
    }
  }

  final integrityRows = await select('PRAGMA quick_check');
  if (_singleValue(integrityRows) != 'ok') {
    throw const SchemaVerificationException('integrity_check_failed');
  }
  if ((await select('PRAGMA foreign_key_check')).isNotEmpty) {
    throw const SchemaVerificationException('foreign_key_check_failed');
  }

  final schemaRows = await select(_schemaContractQuery);
  _verifySchemaContract(schemaRows.map((row) => row.values.toList()).toList());
}

void _verifySchemaContract(List<List<Object?>> schema) {
  if (schema.length != 1 ||
      schema.single.length != 2 ||
      schema.single[0] != 'accounts') {
    throw const SchemaVerificationException('schema_objects_mismatch');
  }

  final normalizedSql = _normalizeSql(schema.single[1]);
  if (normalizedSql != _expectedAccountsSql) {
    throw const SchemaVerificationException('accounts_schema_mismatch');
  }
}

Object? _singleValue(List<Map<String, Object?>> rows) {
  if (rows.length != 1 || rows.single.length != 1) {
    throw const SchemaVerificationException('pragma_result_malformed');
  }
  return rows.single.values.single;
}

int _singleInt(List<Map<String, Object?>> rows) {
  final value = _singleValue(rows);
  if (value is! int) {
    throw const SchemaVerificationException('pragma_result_malformed');
  }
  return value;
}

String _normalizeSql(Object? sql) {
  if (sql is! String) {
    throw const SchemaVerificationException('schema_sql_missing');
  }
  return sql.toLowerCase().replaceAll(RegExp(r'[\s"]+'), '');
}

const String _schemaContractQuery = '''
  SELECT name, sql
  FROM sqlite_schema
  WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
  ORDER BY name
''';

const String _expectedAccountsSql =
    'createtableaccounts('
    'idintegernotnullprimarykeyautoincrement,'
    'google_subjecttextnotnullcheck(length(google_subject)>0)unique'
    ')';
