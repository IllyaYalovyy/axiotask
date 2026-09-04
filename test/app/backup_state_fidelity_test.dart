// A backup holds the WHOLE local state, not just the visible rows (#272).
//
// The failure these protect: the push queue lives in three places the export
// used to drop on the floor — `pending_moves` (a queued reorder), the base
// snapshot on a dirty row (`base_*`, what the 412 resolver compares against),
// and `inflight_creates` (the marker that stops a crashed create from being
// inserted on Google twice). Restoring a backup that lost them leaves the user
// with rows that LOOK right and a sync that reorders nothing, resolves a
// conflict against the wrong base, or duplicates a task on their account.
//
// Every assertion reads the STATE the store holds after the restore.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:axiotask/src/app/backup_service.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/backup.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

const _t0 = '2026-01-01T00:00:00Z';
const _t1 = '2026-01-02T00:00:00Z';

Future<Store> freshStore() async {
  final db = await AppDatabase.openMemory();
  addTearDown(db.close);
  return Store(db);
}

StoredTaskList _list(
  String id, {
  String title = 'Inbox',
  String? remoteId = 'r-L1',
  bool localOnly = false,
}) => StoredTaskList(
  list: TaskList(
    id: id,
    title: title,
    etag: remoteId == null ? null : 'e-$id',
    updated: _t0,
  ),
  syncState: SyncState.clean,
  localUpdated: _t0,
  localOnly: localOnly,
  remoteId: remoteId,
);

StoredTask _task(
  String id,
  String listId, {
  String title = 'a task',
  String? notes,
  String? due,
  String? parent,
  String position = '00000000000001',
  String? remoteId,
  SyncState syncState = SyncState.clean,
  String? pendingOp,
  String localUpdated = _t0,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    status: TaskStatus.needsAction,
    due: due,
    etag: remoteId == null ? null : 'et-$id',
    updated: _t0,
  ),
  listId: listId,
  syncState: syncState,
  localUpdated: localUpdated,
  pendingOp: pendingOp,
  remoteId: remoteId,
);

void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('axiotask_backup_fidelity'),
  );
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  BackupService service(Store store) =>
      BackupService(store: store, backupsDir: tmp);

  Future<(Store, File)> exported(Store src) async {
    final out = File('${tmp.path}/snap.json');
    await service(src).export(to: out);
    final dst = await freshStore();
    return (dst, out);
  }

  test('a queued reorder survives export and restore', () async {
    final src = await freshStore();
    await src.upsertList(_list('L1'));
    await src.upsertTask(_task('T1', 'L1', remoteId: 'g1'));
    await src.upsertTask(
      _task('T2', 'L1', title: 'moved', position: '2', remoteId: 'g2'),
    );
    await src.recordMove('T2', 'L1', null, 'T1');

    final (dst, out) = await exported(src);
    await service(dst).importFrom(from: out);

    final moves = await dst.pendingMoves();
    expect(moves.length, 1, reason: 'the queued reorder came back');
    expect(moves.single.taskId, 'T2');
    expect(moves.single.listId, 'L1');
    expect(moves.single.parentId, isNull);
    expect(
      moves.single.previousId,
      'T1',
      reason: 'the sibling it follows is named in LOCAL id space',
    );
    expect(
      await dst.pendingPushCount(),
      1,
      reason: 'the restored move is queued work',
    );
  });

  test('an in-flight create marker survives export and restore', () async {
    // The marker is what stops a create whose answer never arrived from being
    // inserted on Google a SECOND time. A backup that drops it turns a restore
    // into a duplicate.
    final src = await freshStore();
    await src.upsertList(_list('L1'));
    await src.upsertTask(
      _task(
        'T1',
        'L1',
        title: 'in flight',
        syncState: SyncState.dirty,
        pendingOp: 'create',
        localUpdated: _t1,
      ),
    );
    await src.recordInflightCreate('T1', 'L1');

    final (dst, out) = await exported(src);
    await service(dst).importFrom(from: out);

    expect(await dst.inflightCreates(), [
      ('T1', 'L1'),
    ], reason: 'the marker came back with its list');
    expect(
      await dst.inflightBaseLocalUpdated('T1'),
      _t1,
      reason: 'and the drain snapshot it was based on',
    );
    final row = (await dst.findTaskAny('T1'))!;
    expect(
      row.localUpdated,
      _t1,
      reason: 'the row still matches its marker, so recovery can adopt it',
    );
    final base = await dst.baseSnapshot('T1');
    expect(base, isNotNull, reason: 'the base the orphan is matched against');
    expect(base!.title, 'in flight');
  });

  test("a dirty row's base snapshot survives export and restore", () async {
    final src = await freshStore();
    await src.upsertList(_list('L1'));
    await src.upsertTask(
      _task('T1', 'L1', title: 'as the server has it', remoteId: 'g1'),
    );
    // The edit that dirties the row captures the pre-edit content as its base.
    await src.upsertTask(
      _task(
        'T1',
        'L1',
        title: 'edited locally',
        remoteId: 'g1',
        syncState: SyncState.dirty,
        pendingOp: 'update',
        localUpdated: _t1,
      ),
    );
    expect((await src.baseSnapshot('T1'))!.title, 'as the server has it');

    final (dst, out) = await exported(src);
    await service(dst).importFrom(from: out);

    final row = (await dst.findTaskAny('T1'))!;
    expect(row.task.title, 'edited locally');
    expect(
      row.syncState,
      SyncState.dirty,
      reason: 'the edit is still unpushed',
    );
    expect(row.pendingOp, 'update');
    expect(row.remoteId, 'g1', reason: 'never re-created — Google holds it');
    expect(
      (await dst.baseSnapshot('T1'))!.title,
      'as the server has it',
      reason: 'a 412 must still resolve against the right base',
    );
    await dst.checkInvariants();
  });

  test('a version-1 backup still restores', () async {
    // Files written before the format carried moves/markers/bases must keep
    // loading — a backup the user cannot restore is worthless.
    final v1 = {
      'version': 1,
      'app': 'axiotask',
      'exported_at': _t0,
      'lists': [
        {
          'id': 'L1',
          'remote_id': 'r-L1',
          'title': 'Inbox',
          'etag': 'e-L1',
          'updated': _t0,
          'local_only': false,
          'sync_state': 'clean',
          'local_updated': _t0,
          'tasks': [
            {
              'id': 'T1',
              'remote_id': 'g1',
              'position': '00000000000001',
              'title': 'from v1',
              'status': 'needsAction',
              'etag': 'et-T1',
              'updated': _t0,
              'sync_state': 'clean',
              'local_updated': _t0,
            },
          ],
        },
      ],
    };
    final out = File('${tmp.path}/v1.json')..writeAsStringSync(jsonEncode(v1));

    final dst = await freshStore();
    final result = await service(dst).importFrom(from: out);

    expect(result.lists, 1);
    expect(result.tasks, 1);
    final row = (await dst.findTaskAny('T1'))!;
    expect(row.task.title, 'from v1');
    expect(row.remoteId, 'g1');
    expect(await dst.pendingMoves(), isEmpty);
    expect(await dst.inflightCreates(), isEmpty);
    expect(await dst.baseSnapshot('T1'), isNull);
  });

  test(
    'a backup id already taken by a different row lands under a fresh id',
    () async {
      // Two devices mint local ids independently (#224), so a backup's id can
      // already belong to an UNRELATED row here. Writing under it would silently
      // overwrite the user's other task.
      final dst = await freshStore();
      await dst.upsertList(_list('L1', title: 'Inbox', remoteId: 'r-L1'));
      await dst.upsertTask(
        _task('T1', 'L1', title: 'mine', remoteId: 'g-mine'),
      );

      // The backup names a DIFFERENT Google task, under the same local id.
      final src = await freshStore();
      await src.upsertList(_list('L1', title: 'Inbox', remoteId: 'r-L1'));
      await src.upsertTask(
        _task('T1', 'L1', title: 'theirs', remoteId: 'g-theirs'),
      );
      final out = File('${tmp.path}/collide.json');
      await service(src).export(to: out);

      final result = await service(dst).importFrom(from: out);
      expect(result.tasks, 1);

      final rows = await dst.listTasks('L1');
      expect(rows.length, 2, reason: 'both tasks are here');
      expect(
        (await dst.findTaskAny('T1'))!.task.title,
        'mine',
        reason: 'the local row that owns the id is untouched',
      );
      final restored = rows.firstWhere((r) => r.remoteId == 'g-theirs');
      expect(
        restored.task.id,
        isNot('T1'),
        reason: 'a fresh local id was minted',
      );
      expect(restored.task.title, 'theirs');
      await dst.checkInvariants();
    },
  );

  test('a fault mid-restore leaves no moves or markers behind', () async {
    // The queue state is written row by row alongside the tasks, so it has to
    // roll back with them — a surviving move or marker would name a task that
    // is not there.
    final src = await freshStore();
    await src.upsertList(_list('L1', remoteId: null));
    await src.upsertTask(
      _task(
        'T1',
        'L1',
        syncState: SyncState.dirty,
        pendingOp: 'create',
        localUpdated: _t1,
      ),
    );
    await src.recordInflightCreate('T1', 'L1');
    await src.recordMove('T1', 'L1', null, null);
    await src.upsertTask(
      _task(
        'T2',
        'L1',
        position: '2',
        syncState: SyncState.dirty,
        pendingOp: 'create',
        localUpdated: _t1,
      ),
    );
    final out = File('${tmp.path}/fault.json');
    await service(src).export(to: out);

    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final dst = _FaultingStore(db)..failOnTaskWrite(2);

    await expectLater(
      BackupService(store: dst, backupsDir: tmp).importFrom(from: out),
      throwsA(anything),
    );

    expect(await dst.allTasks(), isEmpty);
    expect(await dst.pendingMoves(), isEmpty, reason: 'the move rolled back');
    expect(
      await dst.inflightCreates(),
      isEmpty,
      reason: 'so did the in-flight marker',
    );
  });

  // The round trip as a property: for a RANDOM local state, exporting,
  // restoring into an empty store and exporting again must reproduce the same
  // document. Any field the format drops — or any row the restore mangles —
  // shows up as a difference, without the test having to name the field.
  test('export → restore → export round-trips any local state', () async {
    final rnd = Random(0x272ba);
    for (var case_ = 0; case_ < 40; case_++) {
      final src = await freshStore();
      await _seedRandom(src, rnd);

      final a = File('${tmp.path}/rt-a-$case_.json');
      await service(src).export(to: a);

      final dst = await freshStore();
      await service(dst).importFrom(from: a);

      final b = File('${tmp.path}/rt-b-$case_.json');
      await service(dst).export(to: b);

      // Compared as canonical TEXT: a mismatch then names the field that
      // moved instead of printing two opaque objects.
      expect(
        _canonical(Backup.fromJson(b.readAsStringSync())).toJsonPretty(),
        _canonical(Backup.fromJson(a.readAsStringSync())).toJsonPretty(),
        reason: 'case $case_ lost or mangled state on the round trip',
      );
      await dst.checkInvariants();
    }
  });
}

/// Seed [store] with a random but VALID local state: server-backed and
/// local-only lists, clean/dirty rows, one level of subtasks, queued moves and
/// in-flight create markers.
Future<void> _seedRandom(Store store, Random rnd) async {
  final listCount = 1 + rnd.nextInt(3);
  var taskSeq = 0;
  for (var i = 0; i < listCount; i++) {
    final localOnly = rnd.nextInt(4) == 0;
    final listId = 'L$i';
    await store.upsertList(
      _list(
        listId,
        title: 'list $i',
        remoteId: localOnly ? null : 'r-$listId',
        localOnly: localOnly,
      ),
    );
    if (!localOnly && rnd.nextInt(3) == 0) {
      // An unpushed list rename.
      await store.upsertList(
        StoredTaskList(
          list: TaskList(
            id: listId,
            title: 'list $i (renamed)',
            etag: 'e-$listId',
            updated: _t0,
          ),
          syncState: SyncState.dirty,
          localUpdated: _t1,
          pendingOp: 'update',
          remoteId: 'r-$listId',
        ),
      );
    }
    final tops = <String>[];
    final taskCount = rnd.nextInt(5);
    for (var j = 0; j < taskCount; j++) {
      final id = 'T${taskSeq++}';
      final synced = !localOnly && rnd.nextBool();
      final parent = tops.isEmpty || rnd.nextInt(3) != 0
          ? null
          : tops[rnd.nextInt(tops.length)];
      await store.upsertTask(
        _task(
          id,
          listId,
          title: 'task $id',
          notes: rnd.nextBool() ? 'notes $id' : null,
          due: rnd.nextBool()
              ? '2026-03-0${1 + rnd.nextInt(9)}T00:00:00Z'
              : null,
          parent: parent,
          position: '0000000000000$j',
          remoteId: synced ? 'g-$id' : null,
        ),
      );
      if (parent == null) tops.add(id);

      if (synced && rnd.nextBool()) {
        // A local edit on top of the clean row: dirty, with a base snapshot.
        await store.upsertTask(
          _task(
            id,
            listId,
            title: 'task $id (edited)',
            parent: parent,
            position: '0000000000000$j',
            remoteId: 'g-$id',
            syncState: SyncState.dirty,
            pendingOp: 'update',
            localUpdated: _t1,
          ),
        );
      } else if (!synced) {
        // An unpushed create, sometimes with its in-flight marker open.
        await store.upsertTask(
          _task(
            id,
            listId,
            title: 'task $id',
            parent: parent,
            position: '0000000000000$j',
            syncState: SyncState.dirty,
            pendingOp: 'create',
            localUpdated: _t1,
          ),
        );
        if (!localOnly && rnd.nextBool()) {
          await store.recordInflightCreate(id, listId);
        }
      }
      if (rnd.nextInt(4) == 0) {
        await store.recordMove(
          id,
          listId,
          parent,
          tops.length > 1 ? tops[rnd.nextInt(tops.length - 1)] : null,
        );
      }
    }
  }
}

/// A [Backup] with its lists and tasks in a canonical order and the export
/// timestamp dropped — so the comparison is about CONTENT, not row order.
Backup _canonical(Backup b) => Backup(
  version: b.version,
  app: b.app,
  exportedAt: '',
  lists: [
    for (final l in [...b.lists]..sort((x, y) => x.id.compareTo(y.id)))
      BackupList(
        id: l.id,
        remoteId: l.remoteId,
        title: l.title,
        etag: l.etag,
        updated: l.updated,
        localOnly: l.localOnly,
        syncState: l.syncState,
        localUpdated: l.localUpdated,
        pendingOp: l.pendingOp,
        tasks: [...l.tasks]..sort((x, y) => x.id.compareTo(y.id)),
      ),
  ],
);

/// A store whose Nth task write faults — standing in for the process dying
/// part-way through a restore.
class _FaultingStore extends Store {
  _FaultingStore(super.db);

  int? _failTaskWrite;
  int _taskWrites = 0;

  void failOnTaskWrite(int nth) => _failTaskWrite = nth;

  @override
  Future<void> upsertTask(StoredTask t) async {
    if (++_taskWrites == _failTaskWrite) {
      throw StateError('injected fault on task write #$_taskWrites');
    }
    return super.upsertTask(t);
  }
}
