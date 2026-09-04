// Port of the create/rename/toggle groups of `commands_test.rs` (the T2.3
// partition): Task CRUD basics (create inserts a dirty create, rename marks
// dirty preserving create-vs-update, toggle flips + completion cascade) plus
// the dirty_op / offline-create-then-edit regressions. Assertions read the
// STATE the store persists (rows returned by list_tasks / all_tasks), never
// which method ran — a stubbed no-op Commands fails every one of these.

import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/app/commands.dart';
import 'package:axiotask/src/model/dates.dart' show DateMove;
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
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

/// A synced (server-backed) list to create tasks in. Google acknowledged it,
/// so it carries a `remote_id`; these tests pin it equal to the opaque local
/// id (#224).
Future<void> seedList(Store store, String id) => store.upsertList(
  StoredTaskList(
    list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
    syncState: SyncState.clean,
    localUpdated: _t0,
    remoteId: id,
  ),
);

/// A local-only (never-synced) list — its rows keep their create-time
/// positions forever and it survives a fresh-sync wipe.
Future<void> seedLocalList(Store store, String id) => store.upsertList(
  StoredTaskList(
    list: TaskList(id: id, title: 'Local', updated: _t0),
    syncState: SyncState.clean,
    localUpdated: _t0,
    localOnly: true,
  ),
);

/// Seed an already-pushed task (etag + `remote_id`) — the "synced" starting
/// point for rename/toggle, so their pending_op should become `update`, not
/// `create`. It is the `remote_id`, not the etag, that says "Google has this
/// row" (#224).
Future<void> seedTask(
  Store store,
  String id,
  String listId,
  String title, {
  String? parent,
  String? due,
  String position = '1',
  String? webViewLink,
  TaskStatus status = TaskStatus.needsAction,
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: position,
      title: title,
      status: status,
      due: due,
      etag: 'e1',
      webViewLink: webViewLink,
      updated: _t0,
    ),
    listId: listId,
    syncState: SyncState.clean,
    localUpdated: _t0,
    remoteId: id,
  ),
);

/// Seed a never-pushed local task (no etag) — a dirty `create` awaiting its
/// first push, the starting point for the hard-delete / in-flight move cases.
Future<void> seedLocalTask(
  Store store,
  String id,
  String listId,
  String title, {
  String? parent,
  String position = '1',
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: position,
      title: title,
      status: TaskStatus.needsAction,
      updated: _t0,
    ),
    listId: listId,
    syncState: SyncState.dirty,
    localUpdated: _t0,
    pendingOp: 'create',
  ),
);

/// The canonical stored form of a bare date, for readable assertions —
/// what [normalizeDue] produces (`YYYY-MM-DDT00:00:00.000Z`).
String due(String date) => '${date}T00:00:00.000Z';

/// The stored due date of a listed task, or `null`.
Future<String?> dueOf(Store store, String listId, String id) async {
  final tasks = await store.listTasks(listId);
  return tasks.firstWhere((t) => t.task.id == id).task.due;
}

void main() {
  group('dirtyOp', () {
    // dirty_op_preserves_create_for_unsynced: a never-pushed row (no etag) must
    // stay a create — flipping to update would 404-delete it on push.
    test('preserves create for an unsynced row, update once synced', () {
      expect(dirtyOp(null), 'create');
      expect(dirtyOp('e1'), 'update');
    });
  });

  group('nextLocalPosition', () {
    test('is distinct and sorts before numeric server positions', () {
      final a = nextLocalPosition();
      final b = nextLocalPosition();
      // Distinct even back-to-back (#80: equal positions broke reorder).
      expect(a, isNot(b));
      // '!'-prefixed → sorts before Google's numeric positions.
      expect(a.compareTo('0'), lessThan(0));
      // Newer sorts ahead of older.
      expect(b.compareTo(a), lessThan(0));
    });

    // #249: the placeholder is a PREDICTION of where Google will put the row —
    // an `insert` with no `previous` goes to the top and comes back carrying a
    // 20-digit `u64::MAX - n` position. A placeholder that sorts after those
    // put a fresh row BELOW rows it must sit above, and the sync that adopted
    // Google's position 3-5s later visibly re-shuffled the list.
    test('sorts before the position Google gives a top insert', () async {
      final client = FakeTasksApi();
      client.seedList('L1', 'Inbox');
      final googleTop = await client.insertTask(
        'L1',
        const NewTask(title: 'inserted at the top'),
      );
      expect(nextLocalPosition().compareTo(googleTop.position), lessThan(0));
    });
  });

  group('createTask', () {
    // create_task_inserts_dirty_row
    test('inserts a dirty, never-synced create', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'T1');
      await seedList(store, 'L1');

      final created = await commands.createTask(
        listId: 'L1',
        title: 'new task',
      );

      final tasks = await store.listTasks('L1');
      expect(tasks, hasLength(1));
      expect(tasks.single.task.title, 'new task');
      expect(tasks.single.task.etag, isNull);
      expect(tasks.single.syncState, SyncState.dirty);
      expect(tasks.single.pendingOp, 'create');
      expect(created.task.id, 'T1');
    });

    test('applies a quick-add due, canonicalized to Google\'s form', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'T1');
      await seedList(store, 'L1');

      await commands.createTask(
        listId: 'L1',
        title: 'pay rent',
        due: '2026-06-15',
      );

      final t = (await store.listTasks('L1')).single.task;
      expect(t.due, '2026-06-15T00:00:00.000Z');
    });

    test('no list to create in is a no-op guarded by the caller', () async {
      // createTask itself trusts its listId; the empty/absent-target guard lives
      // in the quick-add UI (covered in the widget suite).
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'T1');
      await seedList(store, 'L1');
      await commands.createTask(listId: 'L1', title: 'x');
      expect(await store.listTasks('L1'), hasLength(1));
    });

    // F13/#191: creating a subtask under a task that is ITSELF a subtask would
    // make a third level — refused HERE so no list view ever holds an
    // unrenderable nest and nothing is written.
    test('refuses creating under a subtask (one level deep)', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'GC');
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C', 'L1', 'subtask', parent: 'P');

      await expectLater(
        commands.createTask(listId: 'L1', parentId: 'C', title: 'grandchild'),
        throwsA(
          isA<CommandError>().having(
            (e) => e.message,
            'message',
            contains('subtask'),
          ),
        ),
      );

      // Refused before any write — the list still holds only P and C.
      final tasks = await store.listTasks('L1');
      expect(tasks.map((t) => t.task.id), unorderedEquals(['P', 'C']));
    });

    // The one allowed level still works: a subtask under a top-level task.
    test('allows creating a subtask under a top-level task', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'C1');
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');

      final created = await commands.createTask(
        listId: 'L1',
        parentId: 'P',
        title: 'child',
      );

      expect(created.task.parent, 'P');
      expect((await store.findTaskAny('C1'))!.task.parent, 'P');
    });
  });

  group('renameTask', () {
    // rename_task_updates_title_and_marks_dirty
    test('retitles a synced task and queues it as an update', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'old title');

      await commands.renameTask('T1', 'new title');

      final t = (await store.listTasks('L1')).single;
      expect(t.task.title, 'new title');
      expect(t.syncState, SyncState.dirty);
      // Already pushed (had an etag) → update, not a duplicate create.
      expect(t.pendingOp, 'update');
    });

    test(
      'renaming a missing task throws the reference not-found shape',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await expectLater(
          commands.renameTask('ghost', 'x'),
          throwsA(
            isA<CommandError>().having(
              (e) => e.message,
              'message',
              'task ghost not found',
            ),
          ),
        );
      },
    );
  });

  group('toggleComplete', () {
    // toggle_complete_flips_status
    test(
      'flips status both ways and sets/clears the completion stamp',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'T1', 'L1', 'buy milk');

        await commands.toggleComplete('T1');
        var t = (await store.findTaskAny('T1'))!;
        expect(t.task.status, TaskStatus.completed);
        expect(t.task.completed, isNotNull);
        expect(t.syncState, SyncState.dirty);

        await commands.toggleComplete('T1');
        t = (await store.findTaskAny('T1'))!;
        expect(t.task.status, TaskStatus.needsAction);
        expect(t.task.completed, isNull);
      },
    );

    test('completing a parent cascades to its open subtasks', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'child 1', parent: 'P');
      await seedTask(store, 'C2', 'L1', 'child 2', parent: 'P');

      await commands.toggleComplete('P');

      for (final id in ['P', 'C1', 'C2']) {
        final t = (await store.findTaskAny(id))!;
        expect(t.task.status, TaskStatus.completed, reason: '$id completed');
      }
    });

    test('un-completing a parent never cascades to its subtasks', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      // Parent + child both completed.
      await seedTask(store, 'P', 'L1', 'parent', status: TaskStatus.completed);
      await seedTask(
        store,
        'C1',
        'L1',
        'child',
        parent: 'P',
        status: TaskStatus.completed,
      );

      await commands.toggleComplete('P'); // re-open the parent

      expect(
        (await store.findTaskAny('P'))!.task.status,
        TaskStatus.needsAction,
      );
      // The child stays completed — un-complete does not cascade.
      expect(
        (await store.findTaskAny('C1'))!.task.status,
        TaskStatus.completed,
      );
    });
  });

  group('undoToggleComplete', () {
    // F11/#184: a swipe-to-complete is reversible; undo of a leaf completion
    // returns it to open with its completion stamp cleared.
    test('undo of a leaf completion reopens it and clears the stamp', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'buy milk');

      final token = await commands.toggleComplete('T1');
      expect(token.wasCompleting, isTrue);
      expect(
        (await store.findTaskAny('T1'))!.task.status,
        TaskStatus.completed,
      );

      await commands.undoToggleComplete(token);
      final t = (await store.findTaskAny('T1'))!;
      expect(t.task.status, TaskStatus.needsAction);
      expect(t.task.completed, isNull);
      expect(t.syncState, SyncState.dirty);
    });

    // The exactness requirement: completing a parent cascades only its OPEN
    // descendants; undo must reopen exactly that set and leave a descendant that
    // was already completed before the swipe untouched.
    test(
      'undo reopens exactly the cascade set, sparing already-completed subtasks',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(store, 'C1', 'L1', 'open child', parent: 'P');
        await seedTask(
          store,
          'C2',
          'L1',
          'already-done child',
          parent: 'P',
          status: TaskStatus.completed,
        );

        final token = await commands.toggleComplete('P');
        // Only the open child rode the cascade; C2 was skipped.
        expect(token.cascadedReopenIds, <String>['C1']);
        for (final id in ['P', 'C1', 'C2']) {
          expect(
            (await store.findTaskAny(id))!.task.status,
            TaskStatus.completed,
            reason: '$id completed after the swipe',
          );
        }

        await commands.undoToggleComplete(token);
        // P and C1 return to the pre-swipe open state.
        expect(
          (await store.findTaskAny('P'))!.task.status,
          TaskStatus.needsAction,
        );
        expect(
          (await store.findTaskAny('C1'))!.task.status,
          TaskStatus.needsAction,
        );
        // C2 was completed BEFORE the swipe — undo leaves it completed.
        expect(
          (await store.findTaskAny('C2'))!.task.status,
          TaskStatus.completed,
          reason: 'a pre-completed subtask must not be reopened by undo',
        );
      },
    );

    // A reopen never cascades, so its undo simply re-completes the one row.
    test('undo of a reopen re-completes the row', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'done', status: TaskStatus.completed);

      final token = await commands.toggleComplete('T1'); // reopen
      expect(token.wasCompleting, isFalse);
      expect(token.cascadedReopenIds, isEmpty);
      expect(
        (await store.findTaskAny('T1'))!.task.status,
        TaskStatus.needsAction,
      );

      await commands.undoToggleComplete(token);
      final t = (await store.findTaskAny('T1'))!;
      expect(t.task.status, TaskStatus.completed);
      expect(t.task.completed, isNotNull);
    });

    // Non-happy path: a row in the token vanished between complete and undo —
    // undo must skip it, not throw, and still reopen the survivors.
    test('undo skips a cascade row that has since vanished', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'child', parent: 'P');

      final token = await commands.toggleComplete('P');
      await store.deleteTaskHard('C1'); // the child is gone before undo

      await commands.undoToggleComplete(token);
      expect(
        (await store.findTaskAny('P'))!.task.status,
        TaskStatus.needsAction,
      );
      expect(await store.findTaskAny('C1'), isNull);
    });
  });

  group('setNotes', () {
    test('sets notes, marks dirty, and clears to null on empty', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'task');

      await commands.setNotes('T1', 'remember the milk');
      var t = (await store.findTaskAny('T1'))!;
      expect(t.task.notes, 'remember the milk');
      expect(t.syncState, SyncState.dirty);
      expect(t.pendingOp, 'update'); // was synced → update

      // Empty clears the field to null (Google treats empty notes as absent).
      await commands.setNotes('T1', '');
      t = (await store.findTaskAny('T1'))!;
      expect(t.task.notes, isNull);
    });
  });

  group('deleteTask', () {
    // delete_task_with_etag_marks_deleted
    test('a synced task is tombstoned and its delete stays queued', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'doomed'); // has etag e1

      final token = await commands.deleteTask('T1');
      expect(token.hadEtag, isTrue);

      // Excluded from the visible list…
      expect(await store.listTasks('L1'), isEmpty);
      // …but the push still sees the pending delete.
      final dirty = await store.drainDirty();
      expect(dirty, hasLength(1));
      expect(dirty.single.pendingOp, 'delete');
    });

    // delete_task_without_etag_hard_deletes
    test(
      'a never-pushed task is hard-deleted, leaving nothing to push',
      () async {
        final store = await freshStore();
        final commands = Commands(store, newId: () => 'local-1');
        await seedList(store, 'L1');
        await commands.createTask(listId: 'L1', title: 'ephemeral');

        final token = await commands.deleteTask('local-1');
        expect(token.hadEtag, isFalse);
        expect(await store.listTasks('L1'), isEmpty);
        expect(await store.drainDirty(), isEmpty);
      },
    );

    // A never-pushed row with an in-flight create marker MUST tombstone, not
    // hard-delete: its insert may have committed on Google under an id we never
    // recorded, and dropping the marker would strand that task (non-happy path,
    // the serverMayHold in-flight branch).
    test('a create whose insert is still in flight is tombstoned', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'local-1');
      await seedList(store, 'L1');
      await commands.createTask(listId: 'L1', title: 'maybe-on-server');
      await store.recordInflightCreate('local-1', 'L1');

      final token = await commands.deleteTask('local-1');
      expect(token.hadEtag, isFalse);
      // Tombstoned (not gone): the delete must still reach the orphan.
      final row = await store.findTaskAny('local-1');
      expect(row, isNotNull);
      expect(row!.syncState, SyncState.deleted);
      expect(row.pendingOp, 'delete');
    });

    test('deleting a missing task throws the not-found shape', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await expectLater(
        commands.deleteTask('ghost'),
        throwsA(
          isA<CommandError>().having(
            (e) => e.message,
            'message',
            'task ghost not found',
          ),
        ),
      );
    });

    // delete_parent_tombstones_the_whole_subtree_locally (#138)
    test('deleting a parent tombstones the whole subtree in one step', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'kid one', parent: 'P');
      await seedTask(store, 'C2', 'L1', 'kid two', parent: 'P');

      final token = await commands.deleteTask('P');
      expect(token.subtree, hasLength(2), reason: 'descendants captured');

      // The whole subtree vanishes from the view immediately (no live orphan).
      expect(await store.listTasks('L1'), isEmpty);
      for (final id in ['P', 'C1', 'C2']) {
        final row = await store.findTaskAny(id);
        expect(row?.syncState, SyncState.deleted, reason: '$id tombstoned');
      }

      // Only the root's delete is queued; the children are local-only tombstones.
      final dirty = await store.drainDirty();
      final deletes = dirty
          .where((r) => r.pendingOp == 'delete')
          .map((r) => r.task.id)
          .toList();
      expect(deletes, ['P']);
      for (final id in ['C1', 'C2']) {
        expect(dirty.firstWhere((r) => r.task.id == id).pendingOp, isNull);
      }
    });
  });

  group('undoDelete', () {
    // undo_delete_restores_tombstoned_task
    test('revives a tombstoned task in place with its fields intact', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'restore me');
      await commands.setNotes('T1', 'important notes');

      final token = await commands.deleteTask('T1');
      expect(await store.listTasks('L1'), isEmpty);

      await commands.undoDelete(token);
      final tasks = await store.listTasks('L1');
      expect(tasks, hasLength(1));
      expect(tasks.single.task.title, 'restore me');
      expect(tasks.single.task.notes, 'important notes');
      expect(tasks.single.syncState, SyncState.dirty);
      // Was synced (had an etag) → revives as an update, not a duplicate create.
      expect(tasks.single.pendingOp, 'update');
    });

    // undo_delete_restores_hard_deleted_local_task
    test(
      'recreates a hard-deleted local-only task as a dirty create',
      () async {
        final store = await freshStore();
        final commands = Commands(store, newId: () => 'local-1');
        await seedList(store, 'L1');
        await commands.createTask(listId: 'L1', title: 'local task');
        await commands.setNotes('local-1', 'my notes');

        final token = await commands.deleteTask('local-1');
        expect(
          await store.findTaskAny('local-1'),
          isNull,
          reason: 'hard-deleted',
        );

        await commands.undoDelete(token);
        final tasks = await store.listTasks('L1');
        expect(tasks, hasLength(1));
        expect(tasks.single.task.title, 'local task');
        expect(tasks.single.task.notes, 'my notes');
        expect(tasks.single.pendingOp, 'create');
      },
    );

    // undo_after_delete_pushed_restores_the_whole_subtree
    test('after the delete pushed, undo rebuilds the whole subtree', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'kid one', parent: 'P');
      await seedTask(store, 'C2', 'L1', 'kid two', parent: 'P');

      final token = await commands.deleteTask('P');
      // Simulate the delete pushing: the root hard-deletes and the FK cascade
      // takes the child tombstones (what run_sync does in the reference).
      await store.deleteTaskHard('P');
      expect(await store.findTaskAny('C1'), isNull, reason: 'cascaded away');

      await commands.undoDelete(token);
      final tasks = await store.listTasks('L1');
      expect(tasks.map((t) => t.task.id).toSet(), {'P', 'C1', 'C2'});
      for (final id in ['C1', 'C2']) {
        final kid = tasks.firstWhere((t) => t.task.id == id);
        expect(kid.task.parent, 'P', reason: '$id re-attached to its parent');
        // The old remote ids are dead → recreated as fresh dirty creates.
        expect(kid.pendingOp, 'create');
      }
    });

    // undo_recreate_with_dead_parent_falls_back_to_top_level
    test(
      'undo of a subtask whose parent is gone lands it at top level',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(store, 'C1', 'L1', 'kid', parent: 'P');

        final kidToken = await commands.deleteTask('C1');
        await commands.deleteTask('P');
        // Both deletes push: hard-delete the parent (cascading the kid tombstone).
        await store.deleteTaskHard('P');
        expect(await store.findTaskAny('C1'), isNull);
        expect(await store.findTaskAny('P'), isNull);

        await commands.undoDelete(kidToken);
        final kid = (await store.listTasks('L1')).single;
        expect(kid.task.title, 'kid');
        expect(
          kid.task.parent,
          isNull,
          reason: 'orphaned undo lands at top level',
        );
      },
    );

    // undo_delete_after_unpushed_edit_keeps_the_edit_queued
    test('reviving after an unpushed edit keeps the edit queued', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'original');

      // Unpushed local edit (dirty update).
      await commands.renameTask('T1', 'edited offline');

      final token = await commands.deleteTask('T1');
      await commands.undoDelete(token);

      final revived = (await store.findTaskAny('T1'))!;
      expect(
        revived.syncState,
        SyncState.dirty,
        reason: 'edit must stay queued',
      );
      expect(revived.pendingOp, 'update');
      expect(revived.task.title, 'edited offline');
    });
  });

  group('offline create then edit', () {
    // offline_created_then_edited_task_pushes_as_create_not_deleted
    test(
      'an unsynced create stays a create after a rename and a toggle',
      () async {
        final store = await freshStore();
        final commands = Commands(store, newId: () => 'local-1');
        await seedList(store, 'L1');

        await commands.createTask(listId: 'L1', title: 'offline task');
        await commands.renameTask('local-1', 'edited offline');
        await commands.toggleComplete('local-1');

        final t = (await store.findTaskAny('local-1'))!;
        expect(t.task.etag, isNull);
        // Still a create — never flipped to update (which would 404-delete it).
        expect(t.pendingOp, 'create');
        expect(t.task.title, 'edited offline');
        expect(t.task.status, TaskStatus.completed);
      },
    );
  });

  // --- T5.1: due dates & the #164 parent/subtask cascade (12 cases) --------
  //
  // Invariant #164, enforced at the moment of a LOCAL edit: a subtask's
  // explicit due date may never be before its parent's explicit due date. Every
  // date-entry path funnels through the single set_due primitive (setDue for the
  // one-keystroke moves, setDueRaw for the picker/detail raw date), so
  // exercising both proves no path can bypass the rule. Assertions read the
  // dates the store persists — a no-op setDue fails all of these.
  group('setDue — due dates & #164 cascade', () {
    // set_due_applies_date_move
    test('applies a one-keystroke date move and marks the row dirty', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'task with due');

      await withClock(Clock.fixed(DateTime.utc(2026, 5, 23, 9)), () async {
        await commands.setDue('T1', DateMove.tomorrow);
      });

      final t = (await store.listTasks('L1')).single;
      expect(t.task.due, due('2026-05-24'));
      expect(t.syncState, SyncState.dirty);
    });

    // parent_edit_pulls_earlier_children_up_only
    test('setting the parent later pulls only earlier children up', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C_early',
        'L1',
        'early',
        parent: 'P',
        due: due('2026-08-05'),
      );
      await seedTask(
        store,
        'C_late',
        'L1',
        'late',
        parent: 'P',
        due: due('2026-08-20'),
      );
      await seedTask(store, 'C_none', 'L1', 'no date', parent: 'P');

      final res = await commands.setDueRaw('P', '2026-08-15');

      expect(await dueOf(store, 'L1', 'P'), due('2026-08-15'));
      // Earlier child pulled UP to the parent's new date.
      expect(await dueOf(store, 'L1', 'C_early'), due('2026-08-15'));
      // Later child untouched; a child with no explicit date never participates.
      expect(await dueOf(store, 'L1', 'C_late'), due('2026-08-20'));
      expect(await dueOf(store, 'L1', 'C_none'), isNull);
      expect(res.cascaded, 1);
      expect(res.cascadedParent, isFalse);
    });

    // child_set_earlier_pulls_parent_down
    test('setting a child earlier pulls the parent down to match', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2026-08-10'),
      );
      await seedTask(
        store,
        'C2',
        'L1',
        'sibling',
        parent: 'P',
        due: due('2026-08-25'),
      );

      final res = await commands.setDueRaw('C', '2026-08-05');

      expect(await dueOf(store, 'L1', 'C'), due('2026-08-05'));
      expect(await dueOf(store, 'L1', 'P'), due('2026-08-05'));
      // The other child is later than the new parent date — untouched.
      expect(await dueOf(store, 'L1', 'C2'), due('2026-08-25'));
      expect(res.cascaded, 1);
      expect(res.cascadedParent, isTrue);
    });

    // parent_without_date_is_inert
    test(
      'a parent with no date is inert — setting a child adds none',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent'); // no due
        await seedTask(
          store,
          'C',
          'L1',
          'child',
          parent: 'P',
          due: due('2026-08-10'),
        );

        final res = await commands.setDueRaw('C', '2026-08-01');

        expect(await dueOf(store, 'L1', 'C'), due('2026-08-01'));
        expect(await dueOf(store, 'L1', 'P'), isNull);
        expect(res.cascaded, 0);
      },
    );

    // child_set_later_than_parent_does_not_cascade
    test('a child set later than its parent does not cascade', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2026-08-10'),
      );

      final res = await commands.setDueRaw('C', '2026-08-20');

      expect(await dueOf(store, 'L1', 'C'), due('2026-08-20'));
      expect(await dueOf(store, 'L1', 'P'), due('2026-08-10'));
      expect(res.cascaded, 0);
    });

    // equal_dates_do_not_cascade
    test('equal dates are not "before" — no cascade on a tie', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2026-08-10'),
      );

      final res = await commands.setDueRaw('P', '2026-08-10');

      expect(res.cascaded, 0);
      expect(await dueOf(store, 'L1', 'C'), due('2026-08-10'));
    });

    // clearing_a_date_never_cascades
    test('clearing a date participates in nothing', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      // A pre-existing violation the invariant would never have allowed to be
      // created. Clearing the parent must not touch the child.
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2026-08-05'),
      );

      final res = await commands.setDue('P', DateMove.clear);

      expect(res.cascaded, 0);
      expect(await dueOf(store, 'L1', 'P'), isNull);
      expect(await dueOf(store, 'L1', 'C'), due('2026-08-05'));
    });

    // date_move_path_also_cascades
    test('the date-move path cascades too, not only raw dates', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      // Child fixed in the far past so "Today" is always later than it.
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2020-01-01'),
      );

      late final SetDueResult res;
      await withClock(Clock.fixed(DateTime.utc(2026, 8, 15, 9)), () async {
        res = await commands.setDue('P', DateMove.today);
      });

      expect(await dueOf(store, 'L1', 'C'), due('2026-08-15'));
      expect(res.cascaded, 1);
    });

    // completed_subtask_is_included_in_cascade
    test('a completed earlier subtask is still pulled up (#164)', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'done child',
        parent: 'P',
        due: due('2026-08-01'),
        status: TaskStatus.completed,
      );

      final res = await commands.setDueRaw('P', '2026-08-15');

      expect(res.cascaded, 1);
      expect(await dueOf(store, 'L1', 'C'), due('2026-08-15'));
    });

    // cascade_reverts_as_one_undo_unit
    test('one edit + its cascade revert as a single undo unit', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent', due: due('2026-08-10'));
      await seedTask(
        store,
        'C',
        'L1',
        'child',
        parent: 'P',
        due: due('2026-08-05'),
      );

      final res = await commands.setDueRaw('P', '2026-08-15');
      expect(await dueOf(store, 'L1', 'P'), due('2026-08-15'));
      expect(await dueOf(store, 'L1', 'C'), due('2026-08-15'));

      await commands.undoSetDue(res.undo);

      // Both rows back to exactly their pre-edit dates.
      expect(await dueOf(store, 'L1', 'P'), due('2026-08-10'));
      expect(await dueOf(store, 'L1', 'C'), due('2026-08-05'));
    });

    // set_due_from_picker_normalizes_bare_date_and_pushes (store-observable half;
    // the sync round-trip lands with the sync engine in a later task).
    test('the picker path canonicalizes a bare date before storing', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'pick a date');

      await commands.setDueRaw('T1', '2026-08-02');

      final t = (await store.listTasks('L1')).single;
      // Google 400s a bare "YYYY-MM-DD" (verified live) — must be canonical.
      expect(t.task.due, '2026-08-02T00:00:00.000Z');
      expect(t.syncState, SyncState.dirty);
    });

    // set_due_rejects_garbage_instead_of_poisoning_the_row
    test(
      'garbage is rejected at the boundary, leaving the row untouched',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'T1', 'L1', 'task'); // clean, no due

        await expectLater(
          commands.setDueRaw('T1', 'not-a-date'),
          throwsA(isA<CommandError>()),
        );

        final t = (await store.listTasks('L1')).single;
        expect(t.syncState, SyncState.clean, reason: 'row untouched');
        expect(t.task.due, isNull);
      },
    );
  });

  group('clearCompleted', () {
    // clear_completed_spares_open_subtasks_under_a_completed_parent
    test(
      'clears fully-completed subtrees but spares a completed parent with open work',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        // A completed parent still sheltering an OPEN child (parent completed
        // remotely before its child) — deleting it would destroy open work.
        await seedTask(
          store,
          'P-open-kid',
          'L1',
          'done parent, open kid',
          status: TaskStatus.completed,
        );
        await seedTask(
          store,
          'K-open',
          'L1',
          'still todo',
          parent: 'P-open-kid',
        );
        // A fully-completed subtree — safe to clear.
        await seedTask(
          store,
          'P-done',
          'L1',
          'done parent',
          status: TaskStatus.completed,
        );
        await seedTask(
          store,
          'K-done',
          'L1',
          'also done',
          parent: 'P-done',
          status: TaskStatus.completed,
        );

        final cleared = await commands.clearCompleted('L1');

        final left = (await store.listTasks(
          'L1',
        )).map((t) => t.task.id).toSet();
        expect(left, contains('K-open'), reason: 'open subtask survives');
        expect(
          left,
          contains('P-open-kid'),
          reason: 'its parent is spared too',
        );
        expect(left, isNot(contains('P-done')));
        expect(left, isNot(contains('K-done')));
        expect(cleared, 2);
      },
    );

    // A synced completed task must be TOMBSTONED (not hard-deleted) so its delete
    // reaches Google (invariant #3) — the non-happy sync-safety path.
    test(
      'a synced completed task is tombstoned so the delete pushes',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(
          store,
          'T1',
          'L1',
          'done',
          status: TaskStatus.completed,
        ); // has etag e1

        final cleared = await commands.clearCompleted('L1');
        expect(cleared, 1);

        expect(await store.listTasks('L1'), isEmpty);
        final dirty = await store.drainDirty();
        expect(dirty, hasLength(1));
        expect(dirty.single.task.id, 'T1');
        expect(dirty.single.pendingOp, 'delete');
      },
    );

    // A never-pushed completed local task is hard-deleted — nothing to push.
    test('a never-pushed completed task is hard-deleted', () async {
      final store = await freshStore();
      final commands = Commands(store, newId: () => 'local-1');
      await seedList(store, 'L1');
      await commands.createTask(listId: 'L1', title: 'ephemeral');
      await commands.toggleComplete('local-1');

      final cleared = await commands.clearCompleted('L1');
      expect(cleared, 1);
      expect(await store.findTaskAny('local-1'), isNull);
      expect(await store.drainDirty(), isEmpty);
    });

    // Nothing completed → nothing cleared (empty non-happy path).
    test('clears nothing when the list has no completed tasks', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'open');

      expect(await commands.clearCompleted('L1'), 0);
      expect(await store.listTasks('L1'), hasLength(1));
    });
  });

  group('local_updated stamps', () {
    test('an edit advances local_updated off the seeded stamp', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'x');
      await withClock(Clock.fixed(DateTime.utc(2026, 6, 1, 9)), () async {
        await commands.renameTask('T1', 'y');
      });
      final t = (await store.findTaskAny('T1'))!;
      expect(t.localUpdated, isNot(_t0));
      expect(t.localUpdated, startsWith('2026-06-01T09'));
    });
  });

  // --- T5.2: structural moves — move/reorder + move-to-list + held create ----
  //
  // These are the command-layer halves of the reference's move/reorder,
  // move_to_list and set_editing groups. The parent/position mutation and the
  // recorded pending_moves row are observable in the store now; the push half
  // (the move API drain, the cross-list sync round-trips of §H) lands with the
  // sync engine in T5.5–T5.7 and is proven there, not here. Assertions read the
  // rows the store persists — a no-op command fails every one of these.

  group('moveTask', () {
    // move_task_changes_parent
    test(
      'reparents a task and records a pending move under the new parent',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'T1', 'L1', 'parent');
        await seedTask(store, 'T2', 'L1', 'child-to-be');

        await commands.moveTask('T2', parentId: 'T1');

        final t2 = (await store.findTaskAny('T2'))!;
        expect(t2.task.parent, 'T1');
        // The reorder is pushed via the move API (a pending_moves row), not a patch.
        final moves = await store.pendingMoves();
        expect(
          moves.any((m) => m.taskId == 'T2' && m.parentId == 'T1'),
          isTrue,
          reason: 'a pending move carries the new parent',
        );
      },
    );

    // demoting_a_task_that_has_subtasks_is_refused (invariant #1, RFC-009 §F)
    test(
      'refuses demoting a task that has subtasks, leaving it untouched',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(store, 'C', 'L1', 'its subtask');
        await seedTask(store, 'X', 'L1', 'another top-level task');
        await commands.moveTask('C', parentId: 'P');

        await expectLater(
          commands.moveTask('P', parentId: 'X'),
          throwsA(
            isA<CommandError>().having(
              (e) => e.message,
              'message',
              contains('subtask'),
            ),
          ),
        );

        // P is still a top-level row and its subtask is untouched.
        expect((await store.findTaskAny('P'))!.task.parent, isNull);
        expect((await store.findTaskAny('C'))!.task.parent, 'P');
        // Nothing queued to push a third level at the server.
        final moves = await store.pendingMoves();
        expect(moves.any((m) => m.taskId == 'P'), isFalse);
      },
    );

    // nesting_a_task_under_a_subtask_is_refused (the mirror: target is a subtask)
    test(
      'refuses nesting under a subtask, leaving the mover top-level',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(store, 'C', 'L1', 'its subtask');
        await seedTask(store, 'X', 'L1', 'would-be grandchild');
        await commands.moveTask('C', parentId: 'P');

        await expectLater(
          commands.moveTask('X', parentId: 'C'),
          throwsA(
            isA<CommandError>().having(
              (e) => e.message,
              'message',
              contains('subtask'),
            ),
          ),
        );

        expect((await store.findTaskAny('X'))!.task.parent, isNull);
        final moves = await store.pendingMoves();
        expect(moves.any((m) => m.taskId == 'X'), isFalse);
      },
    );

    // Detaching (parent_id = None) is always allowed and lands the task at top.
    test(
      'detaching a subtask clears its parent and lands it at the top',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(store, 'C', 'L1', 'child', parent: 'P');

        await commands.moveTask('C', parentId: null);

        final c = (await store.findTaskAny('C'))!;
        expect(c.task.parent, isNull, reason: 'detached to top level');
        expect(c.task.position, '00000000000001', reason: 'lands first');
        final moves = await store.pendingMoves();
        final m = moves.firstWhere((m) => m.taskId == 'C');
        expect(m.parentId, isNull);
      },
    );

    // A previous_id records the sibling the task should follow and pins an
    // after-position locally so the UI reflects the order before the push.
    test('a previousId records an after-position for the push', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'first');
      await seedTask(store, 'T2', 'L1', 'second');

      await commands.moveTask('T2', previousId: 'T1');

      expect((await store.findTaskAny('T2'))!.task.position, 'after-T1');
      final m = (await store.pendingMoves()).firstWhere(
        (m) => m.taskId == 'T2',
      );
      expect(m.previousId, 'T1');
    });

    test('moving a missing task throws the not-found shape', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await expectLater(
        commands.moveTask('ghost', parentId: null),
        throwsA(
          isA<CommandError>().having(
            (e) => e.message,
            'message',
            'task ghost not found',
          ),
        ),
      );
    });
  });

  group('reorderTaskAfter', () {
    // reorder_swaps_positions: dropping a row after its neighbour reassigns
    // positions so the rendered order flips.
    test(
      'dropping a row after its neighbour flips the rendered order',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'T1', 'L1', 'first', position: '00000000000001');
        await seedTask(store, 'T2', 'L1', 'second', position: '00000000000002');

        // Precondition: rendered T1, then T2.
        var order = (await store.listTasks(
          'L1',
        )).map((t) => t.task.id).toList();
        expect(order, ['T1', 'T2']);

        await commands.reorderTaskAfter('T1', 'T2'); // T1 drops after T2

        order = (await store.listTasks('L1')).map((t) => t.task.id).toList();
        expect(order, [
          'T2',
          'T1',
        ], reason: 'the move is visible in list order');
      },
    );

    // reorder_moves_freshly_created_task (#80): create_task hands each row a
    // DISTINCT position, so reassigning by slot actually changes the order on
    // local-only rows (the old equal-position bug did nothing).
    test(
      'reorders a freshly created task despite create-time positions',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        // A local-only list never syncs, so rows keep create-time positions.
        await seedLocalList(store, 'L1');
        await commands.createTask(listId: 'L1', title: 'first');
        await commands.createTask(listId: 'L1', title: 'second');

        final before = await store.listTasks('L1');
        expect(before, hasLength(2));
        final lastId = before[1].task.id;
        final lastTitle = before[1].task.title;
        final firstTitle = before[0].task.title;
        expect(lastTitle, isNot(firstTitle));

        await commands.reorderTaskAfter(lastId, null); // last row up to the top

        final after = await store.listTasks('L1');
        expect(
          after[0].task.title,
          lastTitle,
          reason: 'reorder moves the last row to the top',
        );
        expect(after[1].task.title, firstTitle);
      },
    );

    // reorder_moves_subtask_across_completed_sibling (#90/#202): a move that
    // crosses a HIDDEN completed row is ONE anchored reorder — the anchor is
    // resolved against the full sibling list, so the hidden row keeps its slot.
    test(
      'walks a subtask across a hidden completed sibling in one move',
      () async {
        final store = await freshStore();
        final commands = Commands(store);
        await seedList(store, 'L1');
        await seedTask(store, 'P1', 'L1', 'parent');
        await seedTask(
          store,
          's1',
          'L1',
          'alpha',
          parent: 'P1',
          position: '00000000000001',
        );
        await seedTask(
          store,
          's2',
          'L1',
          'beta',
          parent: 'P1',
          position: '00000000000002',
          status: TaskStatus.completed,
        );
        await seedTask(
          store,
          's3',
          'L1',
          'gamma',
          parent: 'P1',
          position: '00000000000003',
        );

        // Drag "gamma" above "alpha": alpha is the visible neighbour above and
        // was first, so gamma drops at the FRONT, crossing the hidden "beta".
        await commands.reorderTaskAfter('s3', null);

        final subs = (await store.listTasks(
          'L1',
        )).where((t) => t.task.parent == 'P1').map((t) => t.task.id).toList();
        expect(subs, [
          's3',
          's1',
          's2',
        ], reason: 'gamma first, alpha second, completed beta retained last');
      },
    );

    // A drop leaving the row after the sibling it already follows is a no-op:
    // no position change, nothing queued. An anchor that is not a sibling (or
    // the row itself) resolves the same way.
    test('a drop after the current predecessor is a no-op', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'first', position: '00000000000001');
      await seedTask(store, 'T2', 'L1', 'second', position: '00000000000002');

      await commands.reorderTaskAfter('T1', null); // T1 is already first

      final order = (await store.listTasks(
        'L1',
      )).map((t) => t.task.id).toList();
      expect(order, ['T1', 'T2'], reason: 'order unchanged at the boundary');
      expect(await store.pendingMoves(), isEmpty);
    });

    // A multi-slot move records ONE pending move naming the sibling the task now
    // follows — the collapsed form of what used to be N per-step recordings.
    test('records a single move naming the new predecessor', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'a', position: '00000000000001');
      await seedTask(store, 'T2', 'L1', 'b', position: '00000000000002');
      await seedTask(store, 'T3', 'L1', 'c', position: '00000000000003');
      await seedTask(store, 'T4', 'L1', 'd', position: '00000000000004');

      // T4 (last) drops after T1: crosses T3 and T2 in one command.
      await commands.reorderTaskAfter('T4', 'T1');

      final order = (await store.listTasks(
        'L1',
      )).map((t) => t.task.id).toList();
      expect(order, ['T1', 'T4', 'T2', 'T3']);
      final moves = await store.pendingMoves();
      expect(
        moves.where((m) => m.taskId == 'T4'),
        hasLength(1),
        reason: 'one collapsed move, not one per slot crossed',
      );
      expect(
        moves.firstWhere((m) => m.taskId == 'T4').previousId,
        'T1',
        reason: 'T4 now follows T1',
      );
    });

    // Kill-window (#202): the position rewrites and the pending-move record are
    // ONE transaction. A crash between them would leave the stored order and the
    // queued move disagreeing. Forcing recordMove to fault (standing in for the
    // process dying right after the position writes) proves the pair rolls back
    // together — the order is untouched and nothing is queued.
    test('a crash recording the move rolls the position writes back', () async {
      final store = _CrashRecordingMoveStore(await AppDatabase.openMemory());
      addTearDown(store.db.close);
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'a', position: '00000000000001');
      await seedTask(store, 'T2', 'L1', 'b', position: '00000000000002');
      await seedTask(store, 'T3', 'L1', 'c', position: '00000000000003');

      await expectLater(
        commands.reorderTaskAfter('T3', 'T1'), // would land T1, T3, T2
        throwsA(anything),
        reason: 'the move record faults, standing in for a crash',
      );

      final order = (await store.listTasks(
        'L1',
      )).map((t) => t.task.id).toList();
      expect(order, [
        'T1',
        'T2',
        'T3',
      ], reason: 'the position rewrites rolled back with the failed record');
      expect(
        await store.pendingMoves(),
        isEmpty,
        reason: 'no half-applied move survives the rollback',
      );
    });
  });

  group('moveTaskToList', () {
    // move_to_list_creates_in_target_and_tombstones_old (GH#16)
    test(
      'clones a synced task into the target and tombstones the original',
      () async {
        final store = await freshStore();
        var n = 0;
        final commands = Commands(store, newId: () => 'new-${n++}');
        await seedList(store, 'L1');
        await seedList(store, 'L2');
        await seedTask(store, 'T1', 'L1', 'Task to move'); // has etag e1

        final newId = (await commands.moveTaskToList('T1', 'L2'))!.newRootId;
        expect(newId, isNot('T1'), reason: 'the moved task gets a fresh id');

        // Old list no longer shows the task (tombstoned, not visible).
        expect(await store.listTasks('L1'), isEmpty);
        // New list holds a fresh create with the same title.
        final l2 = await store.listTasks('L2');
        expect(l2, hasLength(1));
        expect(l2.single.task.title, 'Task to move');
        expect(l2.single.task.id, newId);
        expect(l2.single.pendingOp, 'create');
        // The push sees both a create and a delete.
        final ops = (await store.drainDirty()).map((t) => t.pendingOp).toSet();
        expect(ops, containsAll(<String?>['create', 'delete']));
      },
    );

    // move_to_list_local_only_task_hard_deletes_old
    test('hard-deletes a never-synced original — no delete tombstone', () async {
      final store = await freshStore();
      var n = 0;
      final commands = Commands(store, newId: () => 'new-${n++}');
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await seedLocalTask(store, 'local-1', 'L1', 'unsynced'); // no etag

      final newId = (await commands.moveTaskToList('local-1', 'L2'))!.newRootId;
      expect(newId, isNot('local-1'));

      // The original is gone entirely — never synced, so nothing to tombstone.
      expect(await store.findTaskAny('local-1'), isNull);
      final l2 = await store.listTasks('L2');
      expect(l2, hasLength(1));
      expect(l2.single.task.id, newId);
      final ops = (await store.drainDirty()).map((t) => t.pendingOp).toSet();
      expect(ops, isNot(contains('delete')));
    });

    // move_to_list_takes_subtasks_along (local half; the sync round-trip is T5.7)
    test('takes the whole subtree along under fresh ids', () async {
      final store = await freshStore();
      var n = 0;
      final commands = Commands(store, newId: () => 'new-${n++}');
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C1', 'L1', 'sub one', parent: 'P');
      await seedTask(store, 'C2', 'L1', 'sub two', parent: 'P');

      await commands.moveTaskToList('P', 'L2');

      // Whole subtree in L2 with its shape intact under the clone's new id.
      final l2 = await store.listTasks('L2');
      expect(l2, hasLength(3), reason: 'parent + both subtasks moved');
      final parent = l2.firstWhere((t) => t.task.title == 'parent');
      final c1 = l2.firstWhere((t) => t.task.title == 'sub one');
      final c2 = l2.firstWhere((t) => t.task.title == 'sub two');
      expect(c1.task.parent, parent.task.id);
      expect(c2.task.parent, parent.task.id);
      // The originals are gone from L1.
      expect(await store.listTasks('L1'), isEmpty);
    });

    test('moving to the same list is a no-op with no undo token', () async {
      final store = await freshStore();
      var n = 0;
      final commands = Commands(store, newId: () => 'new-${n++}');
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'stay');

      // Nothing moved → no token (the UI shows no toast, offers no undo).
      expect(await commands.moveTaskToList('T1', 'L1'), isNull);
      final l1 = await store.listTasks('L1');
      expect(l1, hasLength(1), reason: 'no clone created');
      expect(l1.single.task.id, 'T1');
    });

    test('moving a missing task throws the not-found shape', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await expectLater(
        commands.moveTaskToList('ghost', 'L2'),
        throwsA(
          isA<CommandError>().having(
            (e) => e.message,
            'message',
            'task ghost not found',
          ),
        ),
      );
    });

    // The clone is a brand-new remote row (invariant #4): it must carry NO etag
    // and NO web link, or a push would patch the original's remote id.
    test('the clone carries no etag and no web link', () async {
      final store = await freshStore();
      var n = 0;
      final commands = Commands(store, newId: () => 'new-${n++}');
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await seedTask(
        store,
        'T1',
        'L1',
        'movable',
        webViewLink: 'https://tasks.google.com/task/T1',
      );

      final newId = (await commands.moveTaskToList('T1', 'L2'))!.newRootId;
      final clone = (await store.findTaskAny(newId))!;
      expect(clone.task.etag, isNull);
      expect(clone.task.webViewLink, isNull);
    });

    // §J command-level (a_cross_list_move_of_a_crashed_create_leaves_nothing_
    // behind, #113/P8): the original's insert may have committed under an id we
    // never recorded (an in-flight-create marker), so hard-deleting it on the
    // move would strand that committed row — the next pull resurrects it in the
    // OLD list. serverMayHold sees the marker, so the original is tombstoned
    // (its own delete queued), never hard-deleted.
    test(
      'tombstones an in-flight-create original instead of resurrecting it',
      () async {
        final store = await freshStore();
        var n = 0;
        final commands = Commands(store, newId: () => 'new-${n++}');
        await seedList(store, 'L1');
        await seedList(store, 'L2');
        await seedLocalTask(
          store,
          'local-1',
          'L1',
          'maybe-on-server',
        ); // no etag
        await store.recordInflightCreate('local-1', 'L1');

        await commands.moveTaskToList('local-1', 'L2');

        // The original is tombstoned, not gone: its delete must reach the orphan.
        final orig = await store.findTaskAny('local-1');
        expect(orig, isNotNull);
        expect(orig!.syncState, SyncState.deleted);
        expect(orig.pendingOp, 'delete');
        // The clone still landed in L2.
        expect(await store.listTasks('L2'), hasLength(1));
      },
    );

    // F11/#185: a cross-list move is reversible. Undo removes the clone from the
    // target and restores the original row in its source list under its own id.
    test('undo restores the moved task in its original list', () async {
      final store = await freshStore();
      var n = 0;
      final commands = Commands(store, newId: () => 'new-${n++}');
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      await seedTask(store, 'T1', 'L1', 'movable');

      final token = (await commands.moveTaskToList('T1', 'L2'))!;
      expect(await store.listTasks('L1'), isEmpty);
      expect(await store.listTasks('L2'), hasLength(1));

      await commands.undoMoveToList(token);
      // Clone gone from the target; original back in the source under its id.
      expect(await store.listTasks('L2'), isEmpty);
      final l1 = await store.listTasks('L1');
      expect(l1, hasLength(1));
      expect(l1.single.task.id, 'T1');
      expect(l1.single.task.title, 'movable');
    });

    // Undo restores the WHOLE subtree the move carried along, with the original
    // ids and parent links intact.
    test(
      'undo restores the whole subtree with original ids and parents',
      () async {
        final store = await freshStore();
        var n = 0;
        final commands = Commands(store, newId: () => 'new-${n++}');
        await seedList(store, 'L1');
        await seedList(store, 'L2');
        await seedTask(store, 'P', 'L1', 'parent');
        await seedTask(
          store,
          'C1',
          'L1',
          'sub one',
          parent: 'P',
          position: '1',
        );
        await seedTask(
          store,
          'C2',
          'L1',
          'sub two',
          parent: 'P',
          position: '2',
        );

        final token = (await commands.moveTaskToList('P', 'L2'))!;
        expect(await store.listTasks('L2'), hasLength(3));

        await commands.undoMoveToList(token);
        expect(await store.listTasks('L2'), isEmpty);
        final l1 = await store.listTasks('L1');
        expect(l1.map((t) => t.task.id).toSet(), <String>{'P', 'C1', 'C2'});
        expect(l1.firstWhere((t) => t.task.id == 'C1').task.parent, 'P');
        expect(l1.firstWhere((t) => t.task.id == 'C2').task.parent, 'P');
      },
    );

    // Non-happy path: the clone was already removed (e.g. its delete pushed and
    // Google cascaded it away) before undo. Undo must still restore the original,
    // not throw on the missing clone.
    test(
      'undo still restores the original when the clone is already gone',
      () async {
        final store = await freshStore();
        var n = 0;
        final commands = Commands(store, newId: () => 'new-${n++}');
        await seedList(store, 'L1');
        await seedList(store, 'L2');
        await seedLocalTask(store, 'local-1', 'L1', 'unsynced');

        final token = (await commands.moveTaskToList('local-1', 'L2'))!;
        // Simulate the clone vanishing before undo runs.
        await store.deleteTaskHard(token.newRootId);

        await commands.undoMoveToList(token);
        final l1 = await store.listTasks('L1');
        expect(l1, hasLength(1));
        expect(l1.single.task.id, 'local-1');
        expect(l1.single.task.title, 'unsynced');
      },
    );
  });

  group('freshSync', () {
    // fresh_sync drops synced local data so the next pull rebuilds it; local-only
    // lists exist nowhere else, so they must survive. (The re-pull itself is the
    // sync engine's job, wired in T5.5+.)
    test('drops synced lists and tasks but spares local-only lists', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1'); // synced
      await seedTask(store, 'T1', 'L1', 'from google');
      await seedLocalList(store, 'LOCAL');
      await seedLocalTask(store, 'l-1', 'LOCAL', 'my private note');

      await commands.freshSync();

      final listIds = (await store.allLists()).map((l) => l.list.id).toSet();
      expect(listIds, isNot(contains('L1')), reason: 'synced list wiped');
      expect(listIds, contains('LOCAL'), reason: 'local-only list survives');
      expect(
        await store.findTaskAny('T1'),
        isNull,
        reason: 'synced task wiped',
      );
      expect(
        await store.findTaskAny('l-1'),
        isNotNull,
        reason: 'local-only task survives',
      );
    });
  });

  group('setEditing / held create', () {
    // The held-create id names the one create whose push is deferred while its
    // row is being edited (prevents an id remap mid-edit). The deferral itself
    // is exercised against the sync engine in T5.5; here we pin the seam.
    test('records the held create id and clears it', () async {
      final store = await freshStore();
      final commands = Commands(store);
      expect(commands.heldCreateId, isNull, reason: 'nothing held at start');

      commands.setEditing('local-1');
      expect(commands.heldCreateId, 'local-1');

      commands.setEditing(null);
      expect(commands.heldCreateId, isNull, reason: 'editing finished');
    });

    // The hold is pure process state: it must not dirty or otherwise persist the
    // row it holds (that would defeat the point of deferring only the push).
    test('never touches the store — the held row stays clean', () async {
      final store = await freshStore();
      final commands = Commands(store);
      await seedList(store, 'L1');
      await seedTask(store, 'T1', 'L1', 'held'); // clean

      commands.setEditing('T1');

      expect((await store.findTaskAny('T1'))!.syncState, SyncState.clean);
      expect(await store.drainDirty(), isEmpty);
    });

    // Process memory only: a relaunch (a fresh Commands over the same store)
    // starts with nothing held, so a create the panel was holding is released
    // and pushes on the next sync (restart_drops_the_held_create).
    test('a fresh Commands (restart) starts with no held create', () async {
      final store = await freshStore();
      final before = Commands(store);
      before.setEditing('local-1');

      final afterRestart = Commands(store);
      expect(afterRestart.heldCreateId, isNull);
    });
  });

  // #209: every successful mutating command must fire the onMutation seam —
  // the composition root points it at the sync scheduler's trigger, which is
  // what makes a local change sync within seconds instead of waiting out the
  // periodic cycle. The reference fires schedule_sync() after every mutating
  // command; this pins the Dart equivalent, including the no-op paths that
  // must stay silent.
  group('onMutation trigger (#209)', () {
    test('fires once per successful mutating command', () async {
      final store = await freshStore();
      await seedList(store, 'L1');
      await seedList(store, 'L2');
      var fired = 0;
      final commands = Commands(store, onMutation: () => fired++);

      // At-least-once per command: composed undos (undoMoveToList replays a
      // delete + restore) legitimately notify per inner command, and the
      // scheduler's notify coalesces them into one trigger anyway.
      Future<void> expectFires(String label, Future<void> Function() op) async {
        final before = fired;
        await op();
        expect(fired, greaterThan(before), reason: '$label must notify');
      }

      late StoredTask created;
      await expectFires('createTask', () async {
        created = await commands.createTask(listId: 'L1', title: 'a');
      });
      await expectFires(
        'renameTask',
        () => commands.renameTask(created.task.id, 'b'),
      );
      await expectFires(
        'setNotes',
        () => commands.setNotes(created.task.id, 'n'),
      );
      await expectFires(
        'setDueRaw',
        () => commands.setDueRaw(created.task.id, '2026-08-20'),
      );
      late CompleteToken completeToken;
      await expectFires('toggleComplete', () async {
        completeToken = await commands.toggleComplete(created.task.id);
      });
      await expectFires(
        'undoToggleComplete',
        () => commands.undoToggleComplete(completeToken),
      );
      late MoveToListToken? moveToken;
      await expectFires('moveTaskToList', () async {
        moveToken = await commands.moveTaskToList(created.task.id, 'L2');
      });
      await expectFires(
        'undoMoveToList',
        () => commands.undoMoveToList(moveToken!),
      );
      late DeleteToken deleteToken;
      await expectFires('deleteTask', () async {
        deleteToken = await commands.deleteTask(created.task.id);
      });
      await expectFires('undoDelete', () => commands.undoDelete(deleteToken));
      // The other undoDelete branch: a row the server already holds is
      // TOMBSTONED, and undo revives it in place. That path returned without
      // notifying, so the revive waited out the 60s periodic cycle instead of
      // the 3-5s debounce every other mutation gets (#267).
      await seedTask(store, 'synced-1', 'L1', 'server-backed');
      late DeleteToken revivedToken;
      await expectFires('deleteTask (tombstone)', () async {
        revivedToken = await commands.deleteTask('synced-1');
      });
      expect(
        (await store.findTaskAny('synced-1'))!.syncState,
        SyncState.deleted,
        reason:
            'this arm must exercise the REVIVE branch, not the recreate one',
      );
      await expectFires(
        'undoDelete (revive in place)',
        () => commands.undoDelete(revivedToken),
      );
      late StoredTaskList createdList;
      await expectFires('createList', () async {
        createdList = await commands.createList('New list');
      });
      await expectFires(
        'renameList',
        () => commands.renameList(createdList.list.id, 'Renamed'),
      );
      await expectFires(
        'deleteList',
        () => commands.deleteList(createdList.list.id),
      );
    });

    test(
      'reorder and clear-completed fire on change, stay silent on no-ops',
      () async {
        final store = await freshStore();
        await seedList(store, 'L1');
        await seedTask(store, 'A', 'L1', 'first', position: '1');
        await seedTask(store, 'B', 'L1', 'second', position: '2');
        var fired = 0;
        final commands = Commands(store, onMutation: () => fired++);

        await commands.reorderTaskAfter('A', 'B');
        expect(fired, 1, reason: 'a real reorder notifies');

        await commands.reorderTaskAfter('A', 'B');
        expect(
          fired,
          1,
          reason: 'reorder to the current slot is a silent no-op',
        );

        await commands.clearCompleted('L1');
        expect(fired, 1, reason: 'clearing zero completed rows is a no-op');

        await commands.toggleComplete('A');
        final beforeClear = fired;
        await commands.clearCompleted('L1');
        expect(
          fired,
          greaterThan(beforeClear),
          reason: 'a real clear notifies',
        );
      },
    );

    test('a refused command does not notify', () async {
      final store = await freshStore();
      await seedList(store, 'L1');
      await seedTask(store, 'P', 'L1', 'parent');
      await seedTask(store, 'C', 'L1', 'child', parent: 'P');
      var fired = 0;
      final commands = Commands(store, onMutation: () => fired++);

      await expectLater(
        commands.createTask(listId: 'L1', title: 'x', parentId: 'C'),
        throwsA(isA<CommandError>()),
      );
      expect(fired, 0, reason: 'nothing was written, nothing to sync');
    });
  });
}

/// A store whose [recordMove] always faults — stands in for the process dying
/// (or a write erroring) immediately after a reorder's position rewrites,
/// exercising the reorderSiblings transaction's rollback.
class _CrashRecordingMoveStore extends Store {
  _CrashRecordingMoveStore(super.db);

  @override
  Future<void> recordMove(
    String taskId,
    String listId,
    String? parentId,
    String? previousId,
  ) async {
    throw StateError('simulated crash after reorder position writes');
  }
}
