// BackupService: export → file, import → store. These assert the STATE that
// survives a backup/restore (the rows the store holds, the bytes on disk, the
// counts reported), and the non-happy paths that protect the user's data:
// a newer-version backup is refused (never silently dropped), restore is
// non-destructive (never clobbers or deletes an existing row), a dangling parent
// is re-homed rather than orphaned, and a missing file fails loudly.

import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/backup_paths.dart';
import 'package:axiotask/src/app/backup_service.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/backup.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

StoredTaskList _list(String id, String title, {bool localOnly = false}) =>
    StoredTaskList(
      list: TaskList(
        id: id,
        title: title,
        etag: localOnly ? null : 'e-$id',
        updated: _t0,
      ),
      syncState: SyncState.clean,
      localUpdated: _t0,
      localOnly: localOnly,
    );

StoredTask _task(
  String id,
  String listId,
  String title, {
  String? parent,
  String position = '00000000000001',
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    status: TaskStatus.needsAction,
    etag: 'et-$id',
    updated: _t0,
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: _t0,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('axiotask_backup_svc'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  BackupService service(Store store) =>
      BackupService(store: store, backupsDir: tmp);

  group('export', () {
    test('writes a lossless file and reports its counts and bytes', () async {
      final store = await freshStore();
      await store.upsertList(_list('L1', 'Inbox'));
      await store.upsertTask(_task('T1', 'L1', 'first'));
      await store.upsertTask(_task('T2', 'L1', 'second'));

      final out = File('${tmp.path}/snap.json');
      final result = await withClock(
        Clock.fixed(DateTime.utc(2026, 6, 8)),
        () => service(store).export(to: out),
      );

      expect(out.existsSync(), isTrue);
      expect(result.lists, 1);
      expect(result.tasks, 2);
      expect(result.bytes, utf8.encode(out.readAsStringSync()).length);

      final parsed = Backup.fromJson(out.readAsStringSync());
      expect(parsed.exportedAt, '2026-06-08T00:00:00.000Z');
      expect(parsed.taskCount, 2);
      expect(parsed.lists.single.title, 'Inbox');
    });

    test('with no target lands a timestamped default that latest picks up',
        () async {
      final store = await freshStore();
      await store.upsertList(_list('L1', 'Inbox'));

      final result = await withClock(
        Clock.fixed(DateTime(2026, 6, 8, 1, 45)),
        () => service(store).export(),
      );

      expect(result.path.endsWith('axiotask-backup-20260608-014500.json'), isTrue);
      final latest = latestBackupIn(tmp);
      expect(latest, isNotNull);
      expect(latest!.path, result.path);
    });
  });

  group('import', () {
    test('round-trips lists and tasks into an empty store as fresh creates',
        () async {
      final src = await freshStore();
      await src.upsertList(_list('L1', 'Inbox'));
      await src.upsertTask(_task('T1', 'L1', 'first'));
      await src.upsertTask(_task('T2', 'L1', 'second', parent: 'T1'));
      final out = File('${tmp.path}/snap.json');
      await service(src).export(to: out);

      final dst = await freshStore();
      final result = await service(dst).importFrom(from: out);

      expect(result.lists, 1);
      expect(result.tasks, 2);
      final lists = await dst.allLists();
      expect(lists.single.list.title, 'Inbox');
      // A restored non-local list is a pending create with its etag dropped.
      expect(lists.single.syncState, SyncState.dirty);
      expect(lists.single.pendingOp, 'create');
      expect(lists.single.list.etag, isNull);
      final tasks = await dst.listTasks('L1');
      expect(tasks.map((t) => t.task.title), containsAll(['first', 'second']));
      final child = tasks.firstWhere((t) => t.task.id == 'T2');
      expect(child.task.parent, 'T1', reason: 'parent link preserved');
      expect(child.syncState, SyncState.dirty);
      expect(child.pendingOp, 'create');
      expect(child.task.etag, isNull);
    });

    test('importFrom() with no argument restores the newest backup', () async {
      final src = await freshStore();
      await src.upsertList(_list('L1', 'Inbox'));
      await src.upsertTask(_task('T1', 'L1', 'kept'));
      await withClock(
        Clock.fixed(DateTime(2026, 6, 8, 1, 45)),
        () => service(src).export(),
      );

      final dst = await freshStore();
      final result = await service(dst).importFrom();
      expect(result.tasks, 1);
      expect((await dst.listTasks('L1')).single.task.title, 'kept');
    });

    test('is non-destructive: existing rows are kept, only missing ones added',
        () async {
      // Source backup holds L1 (renamed) + T1 + T2.
      final src = await freshStore();
      await src.upsertList(_list('L1', 'Backup title'));
      await src.upsertTask(_task('T1', 'L1', 'first'));
      await src.upsertTask(_task('T2', 'L1', 'second'));
      final out = File('${tmp.path}/snap.json');
      await service(src).export(to: out);

      // Destination already has L1 (own title) and T1.
      final dst = await freshStore();
      await dst.upsertList(_list('L1', 'Existing title'));
      await dst.upsertTask(_task('T1', 'L1', 'mine'));

      final result = await service(dst).importFrom(from: out);
      expect(result.lists, 0, reason: 'L1 already present — untouched');
      expect(result.tasks, 1, reason: 'only the missing T2 is added');

      final lists = await dst.allLists();
      expect(lists.single.list.title, 'Existing title', reason: 'not clobbered');
      final tasks = await dst.listTasks('L1');
      expect(tasks.firstWhere((t) => t.task.id == 'T1').task.title, 'mine');
      expect(tasks.any((t) => t.task.id == 'T2'), isTrue);
    });

    test('re-homes a restored task whose parent is absent (FK safety)',
        () async {
      // Hand-craft a backup whose only task points at a parent that is nowhere.
      final backup = Backup.build('2026-06-08T00:00:00Z', [
        (_list('L1', 'Inbox'), [_task('T2', 'L1', 'orphan', parent: 'GHOST')]),
      ]);
      final out = File('${tmp.path}/orphan.json')
        ..writeAsStringSync(backup.toJsonPretty());

      final dst = await freshStore();
      final result = await service(dst).importFrom(from: out);
      expect(result.tasks, 1);
      final restored = (await dst.listTasks('L1')).single;
      expect(restored.task.parent, isNull, reason: 're-homed to top level');
    });

    test('refuses a backup written by a newer app version', () async {
      final future = {
        'version': backupVersion + 1,
        'app': 'axiotask',
        'exported_at': _t0,
        'lists': <Object?>[],
      };
      final out = File('${tmp.path}/future.json')
        ..writeAsStringSync(jsonEncode(future));

      final dst = await freshStore();
      expect(
        () => service(dst).importFrom(from: out),
        throwsA(
          isA<BackupError>().having(
            (e) => e.message,
            'message',
            contains('newer than this app supports'),
          ),
        ),
      );
    });

    test('fails loudly when there is no backup to restore', () async {
      final dst = await freshStore();
      expect(
        () => service(dst).importFrom(),
        throwsA(
          isA<BackupError>().having(
            (e) => e.message,
            'message',
            contains('no backup file found'),
          ),
        ),
      );
    });
  });
}
