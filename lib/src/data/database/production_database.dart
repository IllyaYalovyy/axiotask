import 'dart:io';

import '../application_support_directory.dart';
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

  final supportDirectory = await resolveApplicationSupportDirectory();
  return File('${supportDirectory.path}${Platform.pathSeparator}$databaseName');
}

final RegExp _validDatabaseName = RegExp(r'^[a-z0-9][a-z0-9.-]*\.sqlite$');
