import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_database.dart';

Future<AppDatabase> openProductionDatabase(String databaseName) async {
  final file = await resolveProductionDatabaseFile(databaseName);
  return AppDatabase.openFile(file);
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
