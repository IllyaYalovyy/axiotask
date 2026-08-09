// Port of the create/rename/toggle groups of `commands_test.rs` (the T2.3
// partition): Task CRUD basics (create inserts a dirty create, rename marks
// dirty preserving create-vs-update, toggle flips + completion cascade) plus
// the dirty_op / offline-create-then-edit regressions. Assertions read the
// STATE the store persists (rows returned by list_tasks / all_tasks), never
// which method ran — a stubbed no-op Commands fails every one of these.

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

/// A synced (server-backed) list to create tasks in.
Future<void> seedList(Store store, String id) => store.upsertList(
  StoredTaskList(
    list: TaskList(id: id, title: 'Inbox', etag: 'e1', updated: _t0),
    syncState: SyncState.clean,
    localUpdated: _t0,
  ),
);

/// Seed an already-pushed task (has an etag) — the "synced" starting point for
/// rename/toggle, so their pending_op should become `update`, not `create`.
Future<void> seedTask(
  Store store,
  String id,
  String listId,
  String title, {
  String? parent,
  String? due,
  TaskStatus status = TaskStatus.needsAction,
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: '1',
      title: title,
      status: status,
      due: due,
      etag: 'e1',
      updated: _t0,
    ),
    listId: listId,
    syncState: SyncState.clean,
    localUpdated: _t0,
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
      await store.recordInflightCreate('local-1', 'L1', _t0);

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
}
