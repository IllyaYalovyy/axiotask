// Undo-delete raced against the DELETE push (#267).
//
// The defect this suite protects against: the user deletes a task, the engine
// starts pushing the DELETE, and the user hits Undo before the response lands.
// The undo revives the row IN PLACE (it still has its tombstone), but the push
// then hard-deleted that revived row unconditionally — Google had deleted the
// task AND the local row was gone, so the undo the user watched succeed lost
// the task on BOTH sides with nothing left to recover it from.
//
// Every test here drives a REAL delete push against the fake server through the
// real engine, blocking inside `deleteTask` so the undo lands squarely in the
// in-flight window, and asserts on the state the user would see afterwards: the
// rows the store returns and the tasks the fake Google holds.

import 'dart:async';

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/api/tasks_api.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/page.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// A client that hands the test control of the DELETE's in-flight window: the
/// FIRST `deleteTask` completes [inFlight] and then parks until [release] is
/// completed. Everything else delegates to the real fake Google, so the server
/// state the assertions read is the fake's, not a script's.
class BlockingDeleteApi implements TasksApi {
  BlockingDeleteApi(this._inner);

  final FakeTasksApi _inner;

  /// Completes when the engine has entered the first DELETE.
  final inFlight = Completer<void>();

  /// Complete this to let that DELETE reach the server.
  final release = Completer<void>();

  /// Every DELETE the engine issued, as `list/task` remote ids.
  final deletes = <String>[];

  @override
  Future<void> deleteTask(String listId, String id) async {
    deletes.add('$listId/$id');
    if (!inFlight.isCompleted) {
      inFlight.complete();
      await release.future;
    }
    return _inner.deleteTask(listId, id);
  }

  @override
  Future<List<TaskList>> listTasklists() => _inner.listTasklists();
  @override
  Future<TaskList> insertTasklist(String title) => _inner.insertTasklist(title);
  @override
  Future<TaskList> patchTasklist(String id, String title) =>
      _inner.patchTasklist(id, title);
  @override
  Future<void> deleteTasklist(String id) => _inner.deleteTasklist(id);
  @override
  Future<Page<Task>> listTasks(String listId, {String? pageToken}) =>
      _inner.listTasks(listId, pageToken: pageToken);
  @override
  Future<Task> insertTask(String listId, NewTask task) =>
      _inner.insertTask(listId, task);
  @override
  Future<Task> getTask(String listId, String id) => _inner.getTask(listId, id);
  @override
  Future<Task> patchTask(
    String listId,
    String id,
    TaskPatch patch, {
    String? etag,
  }) => _inner.patchTask(listId, id, patch, etag: etag);
  @override
  Future<Task> moveTask(
    String listId,
    String id, {
    String? parent,
    String? previous,
  }) => _inner.moveTask(listId, id, parent: parent, previous: previous);
}

/// One app instance over a fake Google holding a single already-synced list,
/// with the DELETE path under the test's control.
class Rig {
  Rig._(
    this.fake,
    this.client,
    this.store,
    this.commands,
    this.engine,
    this.listId,
  );

  final FakeTasksApi fake;
  final BlockingDeleteApi client;
  final Store store;
  final Commands commands;
  final SyncEngine engine;

  /// LOCAL id of the list the tests create into.
  final String listId;

  static Future<Rig> create() async {
    final fake = FakeTasksApi();
    fake.seedList('L-remote', 'Inbox');
    final client = BlockingDeleteApi(fake);
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    var n = 0;
    String newId() => 'gen-${++n}';
    final engine = SyncEngine.withPush(client, store, true, newId: newId);
    await engine.run(); // adopt the server's list into a local row
    final list = (await store.allLists()).single;
    return Rig._(
      fake,
      client,
      store,
      Commands(store, newId: newId),
      engine,
      list.list.id,
    );
  }

  /// Tasks the fake server currently holds in the seeded list.
  Future<List<Task>> serverTasks() async =>
      (await fake.listTasks('L-remote')).items;

  /// Create [title] (optionally under [parent]) and land it on the server.
  Future<String> land(String title, {String? parent}) async {
    final created = await commands.createTask(
      listId: listId,
      parentId: parent,
      title: title,
    );
    await engine.run();
    return created.task.id;
  }
}

/// A clock the test advances by hand, so every `local_updated` stamp the
/// commands write is distinct without depending on wall-clock resolution.
class Ticker {
  DateTime now = DateTime.utc(2026, 6, 1);
  Clock get clock => Clock(() => now);
  void tick() => now = now.add(const Duration(seconds: 1));
}

void main() {
  test(
    'undo while the DELETE is in flight keeps the task and re-creates it once',
    () async {
      final ticker = Ticker();
      await withClock(ticker.clock, () async {
        final rig = await Rig.create();
        final id = await rig.land('buy milk');
        final remoteId = (await rig.store.findTaskAny(id))!.remoteId;
        expect(remoteId, isNotNull, reason: 'the server must hold it first');

        ticker.tick();
        final token = await rig.commands.deleteTask(id);

        // The DELETE is on the wire; the user hits Undo before it answers.
        final run = rig.engine.run();
        await rig.client.inFlight.future;
        ticker.tick();
        await rig.commands.undoDelete(token);
        rig.client.release.complete();
        await run;

        // What the user sees: the task is still on their list.
        final row = await rig.store.findTaskAny(id);
        expect(
          row,
          isNotNull,
          reason:
              'the undone task must survive the DELETE that was already in '
              'flight — hard-deleting it loses it on BOTH sides (#267)',
        );
        expect(row!.task.title, 'buy milk');
        expect((await rig.store.listTasks(rig.listId)).map((r) => r.task.id), [
          id,
        ], reason: 'and it is VISIBLE, not left as a tombstone');
        // Google no longer holds it, so the row must go back as a fresh create.
        expect(row.remoteId, isNull, reason: 'that remote id is dead');
        expect(row.syncState, SyncState.dirty);
        expect(row.pendingOp, 'create');
        expect(await rig.serverTasks(), isEmpty);

        // The next run puts it back on Google exactly once.
        ticker.tick();
        await rig.engine.run();
        final server = await rig.serverTasks();
        expect(server.map((t) => t.title), ['buy milk']);
        final settled = (await rig.store.findTaskAny(id))!;
        expect(settled.task.id, id, reason: 'the local id never moves (#224)');
        expect(settled.syncState, SyncState.clean);
        expect(settled.remoteId, server.single.id);
        expect(
          rig.client.deletes,
          hasLength(1),
          reason: 'the revived row must never be DELETEd a second time',
        );
      });
    },
  );

  test(
    'undo of a deleted PARENT brings the cascaded subtask back too',
    () async {
      final ticker = Ticker();
      await withClock(ticker.clock, () async {
        final rig = await Rig.create();
        final parent = await rig.land('groceries');
        final kid = await rig.land('milk', parent: parent);
        expect((await rig.serverTasks()).length, 2);

        ticker.tick();
        final token = await rig.commands.deleteTask(parent);

        final run = rig.engine.run();
        await rig.client.inFlight.future;
        ticker.tick();
        await rig.commands.undoDelete(token);
        rig.client.release.complete();
        await run;

        // Google's DELETE cascaded the subtask away, so BOTH rows lost their
        // remote identity and must go back as fresh creates.
        for (final id in [parent, kid]) {
          final row = await rig.store.findTaskAny(id);
          expect(row, isNotNull, reason: '$id must survive the racing DELETE');
          expect(row!.remoteId, isNull, reason: '$id: the cascade killed it');
          expect(row.pendingOp, 'create');
        }
        expect((await rig.store.findTaskAny(kid))!.task.parent, parent);
        expect(await rig.serverTasks(), isEmpty);

        ticker.tick();
        await rig.engine.run();
        final server = await rig.serverTasks();
        expect(server.map((t) => t.title).toSet(), {'groceries', 'milk'});
        expect(server.length, 2, reason: 're-created once, not duplicated');
        final parentRemote = (await rig.store.findTaskAny(parent))!.remoteId;
        expect(
          server.firstWhere((t) => t.title == 'milk').parent,
          parentRemote,
          reason: 'the subtask is re-created UNDER its parent',
        );
      });
    },
  );

  test(
    're-deleting inside the same window does not resurrect the task',
    () async {
      final ticker = Ticker();
      await withClock(ticker.clock, () async {
        final rig = await Rig.create();
        final id = await rig.land('buy milk');

        ticker.tick();
        final token = await rig.commands.deleteTask(id);

        final run = rig.engine.run();
        await rig.client.inFlight.future;
        ticker.tick();
        await rig.commands.undoDelete(token);
        ticker.tick();
        await rig.commands.deleteTask(id); // ...and changes their mind again
        rig.client.release.complete();
        await run;

        // The last thing the user asked for is "deleted", and the row must not
        // come back as a create just because its local_updated moved.
        expect(await rig.store.listTasks(rig.listId), isEmpty);
        expect(await rig.serverTasks(), isEmpty);

        ticker.tick();
        await rig.engine.run();
        expect(
          await rig.store.findTaskAny(id),
          isNull,
          reason: 'the second delete completes on the 404 and clears the row',
        );
        expect(await rig.serverTasks(), isEmpty);
      });
    },
  );
}
