// Port of `export.rs`'s in-file tests (inventory-core.md §src/export.rs). The
// backup layer is pure (no IO): it assembles a lossless JSON snapshot of the
// local store — every list, every task, every sync-metadata field — and the
// exact inverse restore. These tests assert what the produced document HOLDS
// and that a build→JSON→restore round-trip is byte-identical; the specific
// failure each prevents is silent data loss on backup/restore.
import 'dart:convert';

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/backup.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTaskList _list(String id, String title, {bool localOnly = false}) =>
    StoredTaskList(
      list: TaskList(
        id: id,
        title: title,
        etag: 'etag-l',
        updated: '2026-01-01T00:00:00Z',
      ),
      syncState: SyncState.clean,
      localUpdated: '2026-01-02T00:00:00Z',
      localOnly: localOnly,
    );

StoredTask _task(String id, String listId, String title) => StoredTask(
  task: Task(
    id: id,
    position: '00000000000001',
    title: title,
    status: TaskStatus.needsAction,
    etag: 'etag-t',
    updated: '2026-01-01T00:00:00Z',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: '2026-01-02T00:00:00Z',
);

void main() {
  group('Backup.build', () {
    test('build_sets_envelope_metadata', () {
      final b = Backup.build('2026-06-08T00:00:00Z', const []);
      expect(b.version, backupVersion);
      expect(b.app, 'axiotask');
      expect(b.exportedAt, '2026-06-08T00:00:00Z');
      expect(b.lists, isEmpty);
      expect(b.taskCount, 0);
    });

    test('build_preserves_lists_and_nested_tasks_in_order', () {
      final b = Backup.build('now', [
        (
          _list('L1', 'Inbox'),
          [_task('T1', 'L1', 'first'), _task('T2', 'L1', 'second')],
        ),
        (_list('L2', 'Local', localOnly: true), const <StoredTask>[]),
      ]);
      expect(b.lists.length, 2);
      expect(b.lists[0].id, 'L1');
      expect(b.lists[0].localOnly, isFalse);
      expect(b.lists[0].tasks.length, 2);
      expect(b.lists[0].tasks[0].title, 'first');
      expect(b.lists[0].tasks[1].title, 'second');
      expect(b.lists[1].id, 'L2');
      expect(b.lists[1].localOnly, isTrue);
      expect(b.lists[1].tasks, isEmpty);
      expect(b.taskCount, 2);
    });

    test('task_exports_every_field_with_no_loss', () {
      final st = StoredTask(
        task: const Task(
          id: 'T1',
          parent: 'P0',
          position: '00000000000099',
          title: 'Pay rent',
          notes: 'transfer to landlord',
          status: TaskStatus.completed,
          due: '2026-07-01T00:00:00Z',
          completed: '2026-06-30T12:00:00Z',
          etag: 'etag-xyz',
          updated: '2026-06-30T12:00:00Z',
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: '2026-06-30T12:05:00Z',
        pendingOp: 'update',
      );
      final b = Backup.build('now', [
        (_list('L1', 'Inbox'), [st]),
      ]);
      final t = b.lists[0].tasks[0];
      expect(t.id, 'T1');
      expect(t.parent, 'P0');
      expect(t.position, '00000000000099');
      expect(t.title, 'Pay rent');
      expect(t.notes, 'transfer to landlord');
      expect(t.status, 'completed');
      expect(t.due, '2026-07-01T00:00:00Z');
      expect(t.completed, '2026-06-30T12:00:00Z');
      expect(t.etag, 'etag-xyz');
      expect(t.updated, '2026-06-30T12:00:00Z');
      expect(t.syncState, 'dirty');
      expect(t.localUpdated, '2026-06-30T12:05:00Z');
      expect(t.pendingOp, 'update');
    });

    test('list_exports_all_sync_metadata', () {
      final l = StoredTaskList(
        list: const TaskList(
          id: 'L1',
          title: 'Work',
          etag: 'etag-l',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.deleted,
        localUpdated: '2026-01-02T00:00:00Z',
        pendingOp: 'delete',
      );
      final b = Backup.build('now', [(l, const <StoredTask>[])]);
      final bl = b.lists[0];
      expect(bl.title, 'Work');
      expect(bl.etag, 'etag-l');
      expect(bl.updated, '2026-01-01T00:00:00Z');
      expect(bl.syncState, 'deleted');
      expect(bl.localUpdated, '2026-01-02T00:00:00Z');
      expect(bl.pendingOp, 'delete');
    });

    test('task_notes_are_kept_verbatim', () {
      final st = StoredTask(
        task: const Task(
          id: 'T1',
          position: '00000000000001',
          title: 'Water plants',
          notes: 'Water the plants\nremember the fertilizer',
          status: TaskStatus.needsAction,
          updated: '2026-01-01T00:00:00Z',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: '2026-01-02T00:00:00Z',
      );
      final b = Backup.build('now', [
        (_list('L1', 'Inbox'), [st]),
      ]);
      expect(
        b.lists[0].tasks[0].notes,
        'Water the plants\nremember the fertilizer',
      );
    });
  });

  group('Backup JSON', () {
    test('json_is_pretty_and_round_trips', () {
      final b = Backup.build('2026-06-08T00:00:00Z', [
        (_list('L1', 'Inbox'), [_task('T1', 'L1', 'Buy milk')]),
      ]);
      final json = b.toJsonPretty();
      // Pretty-printed: contains newlines and indentation.
      expect(json, contains('\n'));
      expect(json, contains('  '));
      // Self-describing envelope is visible to a human reader.
      expect(json, contains('"version": 2'));
      expect(json, contains('"app": "axiotask"'));
      // Lossless: deserializing yields the same structure.
      expect(Backup.fromJson(json), b);
    });

    test('unknown_future_fields_are_ignored_on_read', () {
      // Forward-compatibility: a backup written by a newer axiotask with extra
      // fields must still load in an older reader.
      const json = '''
{
  "version": 1,
  "app": "axiotask",
  "exported_at": "2026-06-08T00:00:00Z",
  "future_top_level": {"anything": true},
  "lists": [
    {
      "id": "L1",
      "title": "Inbox",
      "updated": "2026-01-01T00:00:00Z",
      "local_only": false,
      "sync_state": "clean",
      "local_updated": "2026-01-02T00:00:00Z",
      "future_list_field": 42,
      "tasks": []
    }
  ]
}''';
      final b = Backup.fromJson(json);
      expect(b.version, 1);
      expect(b.lists.length, 1);
      expect(b.lists[0].id, 'L1');
    });

    test('from_json_parses_a_backup_document', () {
      final b = Backup.build('2026-06-08T00:00:00Z', [
        (_list('L1', 'Inbox'), [_task('T1', 'L1', 'Buy milk')]),
      ]);
      final parsed = Backup.fromJson(b.toJsonPretty());
      expect(parsed, b);
    });

    // Non-happy path: garbage input must fail loudly, not silently degrade.
    test('from_json_rejects_malformed_input', () {
      expect(() => Backup.fromJson('not json at all'), throwsFormatException);
    });
  });

  group('Backup.intoStored (restore)', () {
    test('into_stored_is_the_inverse_of_build', () {
      final st = StoredTask(
        task: const Task(
          id: 'T1',
          parent: 'P0',
          position: '00000000000099',
          title: 'Pay rent',
          notes: 'transfer\nremember the paperwork',
          status: TaskStatus.completed,
          due: '2026-07-01T00:00:00Z',
          completed: '2026-06-30T12:00:00Z',
          etag: 'etag-t',
          updated: '2026-01-01T00:00:00Z',
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: '2026-01-02T00:00:00Z',
        pendingOp: 'update',
      );
      final l = StoredTaskList(
        list: const TaskList(
          id: 'L1',
          title: 'Inbox',
          etag: 'etag-l',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.deleted,
        localUpdated: '2026-01-02T00:00:00Z',
        pendingOp: 'delete',
        localOnly: true,
      );

      final restored = Backup.build('now', [
        (l, [st]),
      ]).intoStored();

      expect(restored.length, 1);
      final (rlist, rtasks) = restored[0];
      expect(rlist, l);
      expect(rtasks.length, 1);
      expect(rtasks[0], st);
    });

    test('into_stored_round_trips_through_json', () {
      final backup = Backup.build('now', [
        (
          _list('L1', 'Inbox'),
          [_task('T1', 'L1', 'a'), _task('T2', 'L1', 'b')],
        ),
        (_list('L2', 'Work', localOnly: true), const <StoredTask>[]),
      ]);
      final restored = Backup.fromJson(backup.toJsonPretty()).intoStored();

      expect(restored.length, 2);
      expect(restored[0].$1.list.id, 'L1');
      expect(restored[0].$2.length, 2);
      // Each restored task is tagged with the list it belongs to.
      expect(restored[0].$2[0].listId, 'L1');
      expect(restored[0].$2[1].listId, 'L1');
      expect(restored[1].$1.list.id, 'L2');
      expect(restored[1].$1.localOnly, isTrue);
      expect(restored[1].$2, isEmpty);
    });

    test('into_stored_degrades_unknown_enums_safely', () {
      // A backup from a newer axiotask may carry enum strings this reader does
      // not know. They must degrade to safe defaults, never throw.
      const json = '''
{
  "version": 1, "app": "axiotask", "exported_at": "now",
  "lists": [{
    "id": "L1", "title": "Inbox", "updated": "u",
    "local_only": false, "sync_state": "weird", "local_updated": "lu",
    "tasks": [{
      "id": "T1", "position": "p", "title": "t",
      "status": "bogus", "updated": "u",
      "sync_state": "nonsense", "local_updated": "lu"
    }]
  }]
}''';
      final restored = Backup.fromJson(json).intoStored();
      final (rlist, rtasks) = restored[0];
      expect(rlist.syncState, SyncState.clean);
      expect(rtasks[0].syncState, SyncState.clean);
      expect(rtasks[0].task.status, TaskStatus.needsAction);
    });

    test('restore_sets_web_view_link_null_and_deleted_false', () {
      // export.rs NOTES: restore sets web_view_link=None and deleted=false
      // (neither is exported). Guards against a restored row carrying a stale
      // web link or a spurious tombstone flag.
      final st = StoredTask(
        task: const Task(
          id: 'T1',
          position: '00000000000001',
          title: 'has a link',
          status: TaskStatus.needsAction,
          updated: '2026-01-01T00:00:00Z',
          webViewLink: 'https://tasks.google.com/task/abc',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: '2026-01-02T00:00:00Z',
      );
      final restored = Backup.build('now', [
        (_list('L1', 'Inbox'), [st]),
      ]).intoStored();
      final rt = restored[0].$2[0].task;
      expect(rt.webViewLink, isNull);
      expect(rt.deleted, isFalse);
      // Sanity: the JSON never carried the link in the first place.
      final b = Backup.build('now', [
        (_list('L1', 'Inbox'), [st]),
      ]);
      expect(b.toJsonPretty(), isNot(contains('webViewLink')));
      expect(b.toJsonPretty(), isNot(contains('web_view_link')));
    });
  });

  // Guard: the JSON key names are wire-stable (snake_case, mirroring serde).
  test('json_uses_snake_case_wire_keys', () {
    final b = Backup.build('2026-06-08T00:00:00Z', [
      (_list('L1', 'Inbox'), [_task('T1', 'L1', 'Buy milk')]),
    ]);
    final decoded = jsonDecode(b.toJsonPretty()) as Map<String, Object?>;
    expect(
      decoded.keys,
      containsAll(<String>['version', 'app', 'exported_at', 'lists']),
    );
    final list0 = (decoded['lists']! as List).first as Map<String, Object?>;
    expect(
      list0.keys,
      containsAll(<String>[
        'id',
        'title',
        'updated',
        'local_only',
        'sync_state',
        'local_updated',
        'tasks',
      ]),
    );
    final task0 = (list0['tasks']! as List).first as Map<String, Object?>;
    expect(
      task0.keys,
      containsAll(<String>[
        'id',
        'position',
        'title',
        'status',
        'updated',
        'sync_state',
        'local_updated',
      ]),
    );
  });
}
