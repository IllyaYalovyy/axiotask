import 'dart:io';

import 'package:axiotask/src/data/application_support_directory.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory dataHome;

  setUp(() async {
    dataHome = await Directory.systemTemp.createTemp('axiotask-data-home-');
  });

  tearDown(() async {
    if (dataHome.existsSync()) await dataHome.delete(recursive: true);
  });

  test('matches the GTK application identifier', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    expect(
      cmake,
      contains('set(APPLICATION_ID "$linuxApplicationIdentifier")'),
    );
  });

  test('resolves below XDG_DATA_HOME, else below the home directory', () {
    expect(
      linuxApplicationSupportDirectory(const <String, String>{
        'XDG_DATA_HOME': '/data',
        'HOME': '/synthetic-home',
      }).path,
      '/data/$linuxApplicationIdentifier',
    );
    for (final environment in const <Map<String, String>>[
      <String, String>{'HOME': '/synthetic-home'},
      <String, String>{'HOME': '/synthetic-home', 'XDG_DATA_HOME': ''},
      <String, String>{'HOME': '/synthetic-home', 'XDG_DATA_HOME': 'relative'},
    ]) {
      expect(
        linuxApplicationSupportDirectory(environment).path,
        '/synthetic-home/.local/share/$linuxApplicationIdentifier',
      );
    }
  });

  test(
    'a fresh installation ignores data left by v1.5.3 and opens a database',
    () async {
      // v1.5.3 kept an incompatible database in a directory named after the
      // executable, which path_provider would otherwise reuse.
      final legacy = Directory('${dataHome.path}/axiotask')..createSync();
      final legacyFile = File('${legacy.path}/axiotask.sqlite');
      sqlite.sqlite3.open(legacyFile.path)
        ..execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT)')
        ..execute('PRAGMA user_version = 1')
        ..close();
      final legacyBytes = legacyFile.readAsBytesSync();

      final directory = await resolveApplicationSupportDirectory(
        environment: <String, String>{'XDG_DATA_HOME': dataHome.path},
      );

      expect(directory.path, '${dataHome.path}/$linuxApplicationIdentifier');
      expect(directory.existsSync(), isTrue);
      final database = await AppDatabase.openFile(
        File('${directory.path}/axiotask.sqlite'),
      );
      expect(await database.allAccounts(), isEmpty);
      await database.close();
      expect(legacyFile.readAsBytesSync(), legacyBytes);
    },
    skip: !Platform.isLinux,
  );
}
