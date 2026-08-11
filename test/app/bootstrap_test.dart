// Startup orchestration: the ordered sequence that opens the store, seeds the
// default list, writes the default config, and produces provider overrides —
// plus the fatal paths that must land on the startup-error screen instead of a
// blank/hung window. Assertions read persisted STATE (rows, files), not calls.

import 'dart:io';

import 'package:axiotask/src/app/bootstrap.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/instance.dart';
import 'package:axiotask/src/auth/token_store.dart';
import 'package:axiotask/src/store/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory dataBase;
  late Directory configBase;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('axiotask_boot_test');
    dataBase = Directory(p.join(tmp.path, 'data'))..createSync();
    configBase = Directory(p.join(tmp.path, 'config'))..createSync();
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'fresh signed-out launch opens the store and seeds "My Tasks"',
    () async {
      final result = await bootstrap(
        dataBase: dataBase,
        configBase: configBase,
        env: const {},
      );

      expect(result, isA<BootstrapReady>());
      final ready = result as BootstrapReady;
      addTearDown(ready.database.close);

      // The seeded default list is really in the opened DB.
      final store = Store(ready.database);
      final lists = await store.allLists();
      expect(lists.single.list.title, 'My Tasks');

      // config.json was written with defaults at the instance-scoped path.
      final cfg = configPathIn(configBase, env: const {});
      expect(cfg.existsSync(), isTrue);
      expect(AppConfig.loadFrom(cfg)!.sync.autoSyncOnStart, isTrue);

      // Overrides are handed to the root ProviderScope.
      expect(ready.overrides, isNotEmpty);
      expect(ready.instancePrefix, isNull);
    },
  );

  test('AXIOTASK_PREFIX isolates the whole data subtree (dev-mode)', () async {
    const env = {instanceEnv: 'dev'};
    final result = await bootstrap(
      dataBase: dataBase,
      configBase: configBase,
      env: env,
    );

    final ready = result as BootstrapReady;
    addTearDown(ready.database.close);

    expect(ready.instancePrefix, 'dev');
    // DB and config land under axiotask-dev, not axiotask.
    expect(
      Directory(p.join(dataBase.path, 'axiotask-dev')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(configBase.path, 'axiotask-dev', 'config.json')).existsSync(),
      isTrue,
    );
    // The production directory is untouched.
    expect(Directory(p.join(dataBase.path, 'axiotask')).existsSync(), isFalse);
  });

  test(
    'an invalid AXIOTASK_PREFIX fails to the startup-error screen',
    () async {
      final result = await bootstrap(
        dataBase: dataBase,
        configBase: configBase,
        env: const {instanceEnv: '../prod'},
      );

      expect(result, isA<BootstrapFailed>());
      expect((result as BootstrapFailed).message, contains(instanceEnv));
      // Never silently resolved to production data.
      expect(
        Directory(p.join(dataBase.path, 'axiotask')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'an unopenable data location fails to the error screen, not a crash',
    () async {
      // Put a FILE where the instance directory needs to be: creating the DB's
      // parent dir then throws, and the fatal is surfaced on the screen.
      final blocker = File(p.join(dataBase.path, 'axiotask'));
      blocker.writeAsStringSync('not a directory');

      final result = await bootstrap(
        dataBase: dataBase,
        configBase: configBase,
        env: const {},
      );

      expect(result, isA<BootstrapFailed>());
      expect((result as BootstrapFailed).message, isNotEmpty);
    },
  );

  test(
    'a persisted session (tokens.json) suppresses the "My Tasks" seed',
    () async {
      // Desktop keeps a refresh token beside the DB; its presence is the real
      // "signed in" state at seed time, so the store must NOT be pre-seeded —
      // the account's real lists arrive from the first sync (ensure_default_list
      // gates on is_authenticated).
      final dbFile = dbPathIn(dataBase, env: const {});
      final tokensFile = tokensFileBeside(dbFile);
      tokensFile.parent.createSync(recursive: true);
      FileTokenStore(tokensFile).save(
        const StoredTokens(
          accessToken: 'a',
          refreshToken: 'r',
          scope: 'https://www.googleapis.com/auth/tasks',
        ),
      );

      final ready =
          await bootstrap(
                dataBase: dataBase,
                configBase: configBase,
                env: const {},
              )
              as BootstrapReady;
      addTearDown(ready.database.close);

      // No local seed: a signed-in user's lists come from sync.
      final lists = await Store(ready.database).allLists();
      expect(lists, isEmpty);
    },
  );

  test(
    're-launch on an existing store does NOT re-seed a second list',
    () async {
      final first = await bootstrap(
        dataBase: dataBase,
        configBase: configBase,
        env: const {},
      );
      await (first as BootstrapReady).database.close();

      final second = await bootstrap(
        dataBase: dataBase,
        configBase: configBase,
        env: const {},
      );
      final ready = second as BootstrapReady;
      addTearDown(ready.database.close);

      final lists = await Store(ready.database).allLists();
      expect(lists, hasLength(1), reason: 'still exactly one "My Tasks"');
    },
  );
}
