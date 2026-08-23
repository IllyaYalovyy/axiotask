// Stable local task identity (#224): a row's id is minted once and NEVER
// changes, so every reference held outside the store — the router's open-detail
// id, an undo token, a captured widget callback — keeps resolving across the
// sync that lands the row on Google.
//
// The defect this suite protects against: create a task, act on it within the
// 3-5s the debounced push takes, and the action failed with
// `task <id> not found` because `finishCreate` had rewritten the row's primary
// key from the local UUID to Google's id underneath the caller.
//
// Every test here drives a REAL create push against the fake server through the
// real engine, then acts through references captured BEFORE that push landed,
// and asserts on the state the user would see: the row is still there, the edit
// stuck, and the server holds exactly one copy.

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/dates.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/database.dart' show AppDatabase;
import 'package:axiotask/src/store/store.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

/// One app instance (store + commands + engine) over a fake Google holding a
/// single already-synced list, so a create push has somewhere real to land.
class Rig {
  Rig._(this.client, this.store, this.commands, this.engine, this.listId);

  final FakeTasksApi client;
  final Store store;
  final Commands commands;
  final SyncEngine engine;

  /// LOCAL id of the list the tests create into.
  final String listId;

  static Future<Rig> create() async {
    final client = FakeTasksApi();
    client.seedList('L-remote', 'Inbox');
    final db = await AppDatabase.openMemory();
    addTearDown(db.close);
    final store = Store(db);
    var n = 0;
    String newId() => 'gen-${++n}';
    final engine = SyncEngine.withPush(client, store, true, newId: newId);
    // First sync adopts the server's list into a local row.
    await engine.run();
    final list = (await store.allLists()).single;
    return Rig._(
      client,
      store,
      Commands(store, newId: newId),
      engine,
      list.list.id,
    );
  }

  /// Tasks the fake server currently holds in the seeded list.
  Future<List<Task>> serverTasks() async =>
      (await client.listTasks('L-remote')).items;
}

void main() {
  // ─── The contract: an id, once minted, never moves ─────────────────────────

  test(
    'a watched task keeps its id across the create push that lands it',
    () async {
      final rig = await Rig.create();
      final created = await rig.commands.createTask(
        listId: rig.listId,
        title: 'buy milk',
      );
      final heldId = created.task.id;

      // The detail panel's subscription, opened BEFORE the push lands.
      final seen = <StoredTask?>[];
      final sub = rig.store.watchTask(heldId).listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await rig.engine.run();
      await pumpEventQueue();

      expect(
        seen,
        isNotEmpty,
        reason: 'the detail stream must have emitted the created row',
      );
      expect(
        seen.any((r) => r == null),
        isFalse,
        reason:
            'the create push must never make the watched row disappear — a '
            'null emission is the id-swap defect (#224) as the panel sees it',
      );
      expect(
        seen.map((r) => r!.task.id).toSet(),
        {heldId},
        reason: 'the watched id must be the SAME id for the row\'s whole life',
      );
      // And the row now knows Google's id, without wearing it.
      final row = (await rig.store.findTaskAny(heldId))!;
      expect(row.remoteId, isNotNull);
      expect(row.remoteId, isNot(heldId));
      expect(row.syncState, SyncState.clean);
    },
  );

  test(
    'the create push records the server id as remote_id, not as the id',
    () async {
      final rig = await Rig.create();
      final created = await rig.commands.createTask(
        listId: rig.listId,
        title: 'buy milk',
      );
      await rig.engine.run();

      final rows = await rig.store.listTasks(rig.listId);
      expect(rows.map((r) => r.task.id), [created.task.id]);
      final server = await rig.serverTasks();
      expect(server.single.title, 'buy milk');
      expect(rows.single.remoteId, server.single.id);
    },
  );

  // ─── The reported repro class: act through a pre-landing reference ─────────

  group('references captured before the push still work after it lands', () {
    /// Create a task, capture its id, then let the push land — the exact
    /// 3-5s window the user hit.
    Future<(Rig, String)> createThenLand() async {
      final rig = await Rig.create();
      final created = await rig.commands.createTask(
        listId: rig.listId,
        title: 'buy milk',
      );
      final id = created.task.id;
      await rig.engine.run();
      return (rig, id);
    }

    test('rename', () async {
      final (rig, id) = await createThenLand();
      await rig.commands.renameTask(id, 'buy oat milk');
      expect((await rig.store.findTaskAny(id))!.task.title, 'buy oat milk');
      await rig.engine.run();
      expect((await rig.serverTasks()).single.title, 'buy oat milk');
      expect((await rig.serverTasks()).length, 1);
    });

    test('set due', () async {
      final (rig, id) = await createThenLand();
      await withClock(Clock.fixed(DateTime.utc(2026, 6, 1)), () async {
        await rig.commands.setDue(id, DateMove.tomorrow);
      });
      final row = (await rig.store.findTaskAny(id))!;
      expect(row.task.due, normalizeDue('2026-06-02'));
      await rig.engine.run();
      expect((await rig.serverTasks()).single.due, isNotNull);
    });

    test(
      'edit in an open detail persists (the exact reported repro)',
      () async {
        final rig = await Rig.create();
        final created = await rig.commands.createTask(
          listId: rig.listId,
          title: 'buy milk',
        );
        final id = created.task.id;
        // The detail panel is OPEN on the just-created task.
        rig.commands.setEditing(id);
        await rig.engine.holdCreateId(rig.commands.heldCreateId).run();
        // The panel closes; the push lands while the user is still on the row.
        rig.commands.setEditing(null);
        await rig.engine.run();

        // Now the user types in the still-open detail: the notes field saves.
        await rig.commands.setNotes(id, 'oat, not soy');
        expect((await rig.store.findTaskAny(id))!.task.notes, 'oat, not soy');
        await rig.engine.run();
        expect((await rig.serverTasks()).single.notes, 'oat, not soy');
      },
    );

    test('complete then undo', () async {
      final (rig, id) = await createThenLand();
      final token = await rig.commands.toggleComplete(id);
      expect(
        (await rig.store.findTaskAny(id))!.task.status,
        TaskStatus.completed,
      );
      await rig.commands.undoToggleComplete(token);
      expect(
        (await rig.store.findTaskAny(id))!.task.status,
        TaskStatus.needsAction,
      );
      await rig.engine.run();
      expect((await rig.serverTasks()).single.status, TaskStatus.needsAction);
    });

    test('delete then undo', () async {
      final (rig, id) = await createThenLand();
      final token = await rig.commands.deleteTask(id);
      expect(token.hadEtag, isTrue);
      await rig.commands.undoDelete(token);
      final row = (await rig.store.findTaskAny(id))!;
      expect(row.syncState, SyncState.dirty);
      expect(row.pendingOp, 'update', reason: 'the server already holds it');
      await rig.engine.run();
      expect((await rig.serverTasks()).length, 1);
    });

    test('move to another list', () async {
      final (rig, id) = await createThenLand();
      final other = await rig.commands.createList('Later');
      final token = await rig.commands.moveTaskToList(id, other.list.id);
      expect(token, isNotNull);
      await rig.engine.run();
      final moved = await rig.store.listTasks(other.list.id);
      expect(moved.map((r) => r.task.title), ['buy milk']);
      expect(await rig.store.listTasks(rig.listId), isEmpty);
    });
  });

  // ─── Pull side: match by remote_id, mint fresh local ids ───────────────────

  test('an unseen remote task is stored under a FRESH local id', () async {
    final rig = await Rig.create();
    rig.client.seedTask('L-remote', 'remote-abc', 'from phone', '00001');

    await rig.engine.run();

    final row = (await rig.store.listTasks(rig.listId)).single;
    expect(row.task.title, 'from phone');
    expect(
      row.task.id,
      isNot('remote-abc'),
      reason: 'Google ids never become primary keys (#224)',
    );
    expect(row.remoteId, 'remote-abc');
  });

  test('a second pull matches the same row by remote_id, not by id', () async {
    final rig = await Rig.create();
    rig.client.seedTask('L-remote', 'remote-abc', 'from phone', '00001');
    await rig.engine.run();
    final firstId = (await rig.store.listTasks(rig.listId)).single.task.id;

    await rig.engine.run();
    await rig.engine.run();

    final rows = await rig.store.listTasks(rig.listId);
    expect(rows, hasLength(1), reason: 'a re-pull must not duplicate the row');
    expect(rows.single.task.id, firstId, reason: 'and must not re-mint its id');
  });

  test('a pulled subtask points at its parent by LOCAL id', () async {
    final rig = await Rig.create();
    rig.client.seedTask('L-remote', 'remote-p', 'parent', '00001');
    rig.client.seedTaskWithParent(
      'L-remote',
      'remote-c',
      'child',
      '00002',
      'remote-p',
    );

    await rig.engine.run();

    final rows = await rig.store.listTasks(rig.listId);
    final parent = rows.firstWhere((r) => r.task.title == 'parent');
    final child = rows.firstWhere((r) => r.task.title == 'child');
    expect(child.task.parent, parent.task.id);
    expect(child.task.parent, isNot('remote-p'));
  });

  test('a pulled list is stored under a fresh local id + remote_id', () async {
    final rig = await Rig.create();
    final list = (await rig.store.allLists()).single;
    expect(list.list.title, 'Inbox');
    expect(list.remoteId, 'L-remote');
    expect(list.list.id, isNot('L-remote'));
  });

  // ─── Local-only lists keep remote_id null forever ─────────────────────────

  test('a local-only list never learns a remote id', () async {
    final rig = await Rig.create();
    final local = await rig.commands.createList('Private', localOnly: true);
    await rig.commands.createTask(listId: local.list.id, title: 'secret');

    await rig.engine.run();

    final stored = (await rig.store.allLists()).firstWhere(
      (l) => l.list.title == 'Private',
    );
    expect(stored.remoteId, isNull);
    expect((await rig.store.listTasks(local.list.id)).single.remoteId, isNull);
    expect(
      (await rig.serverTasks()).where((t) => t.title == 'secret'),
      isEmpty,
    );
  });

  // ─── A landing list create keeps the list id (and its tasks) put ──────────

  test('a landing list create keeps the list id its tasks reference', () async {
    final rig = await Rig.create();
    final created = await rig.commands.createList('Later');
    final listId = created.list.id;
    final task = await rig.commands.createTask(
      listId: listId,
      title: 'ship it',
    );

    await rig.engine.run();

    final stored = (await rig.store.allLists()).firstWhere(
      (l) => l.list.title == 'Later',
    );
    expect(stored.list.id, listId, reason: 'the list id is immutable (#224)');
    expect(stored.remoteId, isNotNull);
    final rows = await rig.store.listTasks(listId);
    expect(rows.map((r) => r.task.id), [task.task.id]);
    expect(rows.single.remoteId, isNotNull);
  });
}
