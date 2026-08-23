// The account-switch reset service (#215) — the orchestration between the
// durable recovery dump and the store nuke, plus the two guarantees the whole
// account-switch flow rests on:
//
//  1. The nuke is the ONE place Undo cannot exist, so it never runs without a
//     recoverable artifact on disk first. If the dump cannot be written, the
//     data is left EXACTLY as it was — the same fail-open rule the schema-wipe
//     safety net follows (#129), applied to a user-initiated erase.
//  2. After it, a push carrying the PREVIOUS account's data is impossible: a
//     real sync run against the fake server sends nothing, and signing in with
//     the next account lands in a clean pull holding only that account's rows.
//
// Assertions read what is ON DISK (the dump file and its contents), what the
// store HOLDS, and what the fake server RECEIVED — never that a method fired.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/auth_sync_runtime.dart';
import 'package:axiotask/src/app/config.dart';
import 'package:axiotask/src/app/config_controller.dart';
import 'package:axiotask/src/app/local_data_reset.dart';
import 'package:axiotask/src/app/logging.dart';
import 'package:axiotask/src/auth/token_provider.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _t0 = '2026-01-01T00:00:00Z';

void main() {
  Log.initLogging();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_reset'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A store holding one synced list with a clean and a locally-edited task,
  /// plus a local-only list — everything an account switch must erase.
  Future<(AppDatabase, Store)> loaded() async {
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    await store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'S1', title: 'Work', etag: 'e1', updated: _t0),
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );
    await store.upsertList(
      StoredTaskList(
        list: TaskList(id: 'LOCAL', title: 'Scratch', updated: _t0),
        syncState: SyncState.clean,
        localUpdated: _t0,
        localOnly: true,
      ),
    );
    await store.upsertTask(
      StoredTask(
        task: Task(
          id: 'T1',
          position: '1',
          title: 'the old account secret',
          status: TaskStatus.needsAction,
          etag: 'e1',
          updated: _t0,
        ),
        listId: 'S1',
        syncState: SyncState.dirty,
        localUpdated: _t0,
        pendingOp: 'update',
      ),
    );
    await store.upsertTask(
      StoredTask(
        task: Task(
          id: 'T2',
          position: '2',
          title: 'scratch note',
          status: TaskStatus.needsAction,
          updated: _t0,
        ),
        listId: 'LOCAL',
        syncState: SyncState.clean,
        localUpdated: _t0,
      ),
    );
    return (db, store);
  }

  List<File> dumps(Directory dir) => dir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).startsWith('axiotask-prereset-'))
      .toList();

  group('LocalDataReset', () {
    test('writes a recoverable dump, then empties the store', () async {
      final (db, store) = await loaded();
      final reset = LocalDataReset(
        database: db,
        store: store,
        dbPath: p.join(tmp.path, 'axiotask.sqlite'),
      );

      final result = await reset.run();

      // The artifact is on disk, beside the database, and holds the erased row.
      final files = dumps(tmp);
      expect(files, hasLength(1), reason: 'exactly one recovery dump');
      expect(result.dumpPath, files.single.path);
      final text = files.single.readAsStringSync();
      expect(text, contains('the old account secret'));
      expect(text, contains('scratch note'));
      expect(jsonDecode(text), isA<Map<String, Object?>>());

      // ...and the store is empty, both lists gone.
      expect(await store.allLists(), isEmpty);
      expect(await store.allTasks(), isEmpty);

      // The receipt names what was erased, so the user is told, not guessed at.
      expect(result.lists, 2);
      expect(result.tasks, 2);
    });

    test('refuses the erase when the dump cannot be written', () async {
      final (db, store) = await loaded();
      // A database path inside a directory that does not exist: the durable
      // write fails, so the erase must not happen.
      final reset = LocalDataReset(
        database: db,
        store: store,
        dbPath: p.join(tmp.path, 'missing-dir', 'axiotask.sqlite'),
      );

      await expectLater(reset.run(), throwsA(isA<ResetAborted>()));

      // Data left EXACTLY as it was — the whole point of the refusal.
      expect((await store.allLists()).map((l) => l.list.id), hasLength(2));
      expect((await store.allTasks()).map((t) => t.task.id), ['T1', 'T2']);
      expect(await store.pendingPushCount(), 1);
    });

    test('refuses the erase when no database path is known', () async {
      final (db, store) = await loaded();
      final reset = LocalDataReset(database: db, store: store, dbPath: '');

      await expectLater(reset.run(), throwsA(isA<ResetAborted>()));
      expect(await store.allLists(), hasLength(2));
    });

    test('the refusal message never leaks the database path', () async {
      final (db, store) = await loaded();
      final dbPath = p.join(tmp.path, 'missing-dir', 'axiotask.sqlite');
      final reset = LocalDataReset(database: db, store: store, dbPath: dbPath);

      Object? err;
      try {
        await reset.run();
      } on ResetAborted catch (e) {
        err = e;
      }

      expect(err, isA<ResetAborted>());
      final message = (err! as ResetAborted).message;
      expect(message, isNot(contains(dbPath)));
      expect(message, contains('NOT erased'));
    });
  });

  group('push discipline after the reset', () {
    test('a sync run sends nothing from the erased account', () async {
      final (db, store) = await loaded();
      final client = FakeTasksApi();
      await LocalDataReset(
        database: db,
        store: store,
        dbPath: p.join(tmp.path, 'axiotask.sqlite'),
      ).run();

      // A full read-write sync against an EMPTY server: the erased account's
      // dirty task must not be recreated there.
      final outcome = await SyncEngine.withPush(client, store, true).run();

      expect(outcome.pushed, 0);
      expect(client.callCount(Method.insertTask), 0);
      expect(client.callCount(Method.patchTask), 0);
      expect(client.callCount(Method.deleteTask), 0);
      expect(client.callCount(Method.insertTasklist), 0);
      expect(client.callCount(Method.patchTasklist), 0);
    });
  });

  group('signing in after the reset', () {
    test('lands in a clean pull of the NEW account only', () async {
      final db = await AppDatabase.openMemory();
      addTearDown(db.close);
      final store = Store(db);
      // The OLD account's cache.
      await store.upsertList(
        StoredTaskList(
          list: TaskList(id: 'OLD', title: 'Old account', updated: _t0),
          syncState: SyncState.clean,
          localUpdated: _t0,
        ),
      );

      // The NEW account's server.
      final client = FakeTasksApi();
      client.seedList('NEW', 'New account');
      client.seedTask('NEW', 'N1', 'new account task', '00000000000001');

      final provider = FakeTokenProvider.withToken('access-new');
      final runtime = AuthSyncRuntime(
        store: store,
        config: ConfigController(
          path: File(p.join(tmp.path, 'config.json')),
          initial: const AppConfig(),
        ),
        tokenProvider: provider,
        buildClient: (_) => client,
        debounce: Duration.zero,
      );
      addTearDown(runtime.dispose);

      await LocalDataReset(
        database: db,
        store: store,
        dbPath: p.join(tmp.path, 'axiotask.sqlite'),
      ).run();
      await runtime.signIn();

      // Local ids are minted per device (#224); the account's list is the one
      // whose remote_id is Google's 'NEW'.
      final lists = (await store.allLists()).map((l) => l.remoteId).toList();
      expect(lists, ['NEW'], reason: 'only the new account is cached');
      expect((await store.allTasks()).map((t) => t.task.title), [
        'new account task',
      ]);
    });
  });
}
