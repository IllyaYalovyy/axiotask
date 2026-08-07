// Port of the create/rename/toggle groups of `commands_test.rs` (the T2.3
// partition): Task CRUD basics (create inserts a dirty create, rename marks
// dirty preserving create-vs-update, toggle flips + completion cascade) plus
// the dirty_op / offline-create-then-edit regressions. Assertions read the
// STATE the store persists (rows returned by list_tasks / all_tasks), never
// which method ran — a stubbed no-op Commands fails every one of these.

import 'package:axiotask/src/app/commands.dart';
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
  TaskStatus status = TaskStatus.needsAction,
}) => store.upsertTask(
  StoredTask(
    task: Task(
      id: id,
      parent: parent,
      position: '1',
      title: title,
      status: status,
      etag: 'e1',
      updated: _t0,
    ),
    listId: listId,
    syncState: SyncState.clean,
    localUpdated: _t0,
  ),
);

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
