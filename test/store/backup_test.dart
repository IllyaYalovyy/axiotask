// Port of `export.rs`'s in-file tests (inventory-core.md §src/export.rs). The
// backup layer is pure (no IO): it assembles a lossless JSON snapshot of the
// local store — every list, every task, every sync-metadata field — and the
// exact inverse restore. These tests assert what the produced document HOLDS
// and that a build→JSON→restore round-trip is byte-identical; the specific
// failure each prevents is silent data loss on backup/restore.
import 'dart:convert';

import 'package:axiotask/src/model/base_snapshot.dart';
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

/// The one task map inside a produced document, as a human reader (or a
/// restore on another machine) would see it.
Map<String, Object?> _taskJson(Backup b) {
  final list0 = _listJson(b);
  return (list0['tasks']! as List).first as Map<String, Object?>;
}

/// The one list map inside a produced document.
Map<String, Object?> _listJson(Backup b) {
  final doc = jsonDecode(b.toJsonPretty()) as Map<String, Object?>;
  return (doc['lists']! as List).first as Map<String, Object?>;
}

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

  // What the SERIALIZER writes. Everything above asserts the parse direction or
  // in-memory values; these assert the produced document itself, field by
  // field. The failure they prevent is the worst one this module has: an export
  // that quietly omits notes, dates or queued push state, restoring EMPTIED
  // tasks on a new machine while every other test stays green.
  group('Backup JSON — optional fields', () {
    test('json_carries_every_optional_field_when_set', () {
      final st = StoredTask(
        task: const Task(
          id: 'T1',
          parent: 'P0',
          position: '00000000000099',
          title: 'Pay rent',
          notes: 'transfer to landlord',
          status: TaskStatus.completed,
          due: '2026-07-01T00:00:00.000Z',
          completed: '2026-06-30T12:00:00.000Z',
          etag: 'etag-xyz',
          updated: '2026-06-30T12:00:00Z',
        ),
        listId: 'L1',
        syncState: SyncState.dirty,
        localUpdated: '2026-06-30T12:05:00Z',
        pendingOp: 'update',
        remoteId: 'g-task-1',
      );
      final l = StoredTaskList(
        list: const TaskList(
          id: 'L1',
          title: 'Inbox',
          etag: 'etag-l',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.dirty,
        localUpdated: '2026-01-02T00:00:00Z',
        pendingOp: 'update',
        remoteId: 'g-list-1',
      );
      final b = Backup.build(
        'now',
        [
          (l, [st]),
        ],
        bases: {
          'T1': const BaseSnapshot(
            title: 'Pay the rent',
            notes: 'old note',
            due: '2026-06-01T00:00:00.000Z',
            status: TaskStatus.needsAction,
          ),
        },
        moves: {
          'T1': const PendingMove(
            taskId: 'T1',
            listId: 'L1',
            parentId: 'P0',
            previousId: 'T0',
          ),
        },
        inflight: {'T1': '2026-06-30T12:04:00Z'},
      );

      final t = _taskJson(b);
      expect(t['remote_id'], 'g-task-1');
      expect(t['parent'], 'P0');
      expect(t['notes'], 'transfer to landlord');
      expect(t['due'], '2026-07-01T00:00:00.000Z');
      expect(t['completed'], '2026-06-30T12:00:00.000Z');
      expect(t['etag'], 'etag-xyz');
      expect(t['pending_op'], 'update');
      // The push queue that lives outside the row (#272), nested under it.
      expect(t['base_title'], 'Pay the rent');
      expect(t['base_notes'], 'old note');
      expect(t['base_due'], '2026-06-01T00:00:00.000Z');
      expect(t['base_status'], 'needsAction');
      expect(t['pending_move'], {'parent': 'P0', 'previous': 'T0'});
      expect(t['inflight_create'], {
        'base_local_updated': '2026-06-30T12:04:00Z',
      });

      final lj = _listJson(b);
      expect(lj['remote_id'], 'g-list-1');
      expect(lj['etag'], 'etag-l');
      expect(lj['pending_op'], 'update');

      // And the document reads back as the same value — nothing lost in
      // either direction.
      expect(Backup.fromJson(b.toJsonPretty()), b);
    });

    test('json_omits_every_optional_field_when_null', () {
      // Non-happy path: a clean, local, never-synced row with nothing set.
      // Optional fields are ABSENT, not present-and-null: absence is what the
      // readers use as a sentinel (`base_title` means "this row has a base")
      // and what keeps an old document loadable in a new reader.
      const bareTask = StoredTask(
        task: Task(
          id: 'T1',
          position: '00000000000001',
          title: 'Buy milk',
          status: TaskStatus.needsAction,
          updated: '2026-01-01T00:00:00Z',
        ),
        listId: 'L1',
        syncState: SyncState.clean,
        localUpdated: '2026-01-02T00:00:00Z',
      );
      const bareList = StoredTaskList(
        list: TaskList(
          id: 'L1',
          title: 'Inbox',
          updated: '2026-01-01T00:00:00Z',
        ),
        syncState: SyncState.clean,
        localUpdated: '2026-01-02T00:00:00Z',
      );
      final b = Backup.build('now', [
        (bareList, [bareTask]),
      ]);

      final t = _taskJson(b);
      for (final key in const [
        'remote_id',
        'parent',
        'notes',
        'due',
        'completed',
        'etag',
        'pending_op',
        'base_title',
        'base_notes',
        'base_due',
        'base_status',
        'pending_move',
        'inflight_create',
      ]) {
        expect(t.containsKey(key), isFalse, reason: 'task carries "$key"');
      }
      // The required fields are of course still there.
      expect(t['id'], 'T1');
      expect(t['title'], 'Buy milk');

      final lj = _listJson(b);
      for (final key in const ['remote_id', 'etag', 'pending_op']) {
        expect(lj.containsKey(key), isFalse, reason: 'list carries "$key"');
      }
      // Visible to a human reading the file: no null-valued keys at all.
      expect(b.toJsonPretty(), isNot(contains('": null')));

      // Restoring keeps them empty rather than inventing values.
      final rt = Backup.fromJson(b.toJsonPretty()).lists[0].tasks[0];
      expect(rt.notes, isNull);
      expect(rt.due, isNull);
      expect(rt.base, isNull);
      expect(rt.move, isNull);
      expect(rt.inflight, isNull);
    });

    test('json_keeps_empty_queue_records_but_drops_their_null_fields', () {
      // Non-happy path: the queue records exist but carry nothing — a base
      // with neither notes nor due, a move to the top of the top level, an
      // in-flight marker written before the drain snapshot was recorded. Their
      // PRESENCE is the fact that must survive a round-trip; their empty
      // fields must not be written as nulls.
      final st = _task('T1', 'L1', 'Buy milk');
      final b = Backup.build(
        'now',
        [
          (_list('L1', 'Inbox'), [st]),
        ],
        bases: {
          'T1': const BaseSnapshot(
            title: 'Buy milk',
            status: TaskStatus.needsAction,
          ),
        },
        moves: {'T1': const PendingMove(taskId: 'T1', listId: 'L1')},
        inflight: {'T1': null},
      );

      final t = _taskJson(b);
      expect(t['base_title'], 'Buy milk');
      expect(t['base_status'], 'needsAction');
      expect(t.containsKey('base_notes'), isFalse);
      expect(t.containsKey('base_due'), isFalse);
      expect(t['pending_move'], isEmpty);
      expect(t['inflight_create'], isEmpty);

      final rt = Backup.fromJson(b.toJsonPretty()).lists[0].tasks[0];
      expect(
        rt.base,
        const BaseSnapshot(title: 'Buy milk', status: TaskStatus.needsAction),
      );
      expect(rt.move, isNotNull);
      expect(rt.move!.parent, isNull);
      expect(rt.move!.previous, isNull);
      expect(rt.inflight, isNotNull);
      expect(rt.inflight!.baseLocalUpdated, isNull);
    });
  });

  // Value equality is what the round-trip assertions above rest on: if two
  // DIFFERENT backups compared equal, every `expect(parsed, original)` in this
  // file would pass against a serializer that lost data.
  group('value equality', () {
    Backup backupOf(List<StoredTask> tasks, {String title = 'Inbox'}) =>
        Backup.build('now', [(_list('L1', title), tasks)]);

    test('backups differing in one task are not equal', () {
      final same = backupOf([_task('T1', 'L1', 'Buy milk')]);
      expect(backupOf([_task('T1', 'L1', 'Buy milk')]), same);
      // Same length, one element different — at the level the difference
      // lives on (the list's tasks) and at the root that contains it.
      expect(
        backupOf([_task('T1', 'L1', 'Buy bread')]).lists[0],
        isNot(same.lists[0]),
      );
      expect(backupOf([_task('T1', 'L1', 'Buy bread')]), isNot(same));
      // Same first element, different length.
      expect(
        backupOf([
          _task('T1', 'L1', 'Buy milk'),
          _task('T2', 'L1', 'Buy milk'),
        ]),
        isNot(same),
      );
      // Empty vs non-empty.
      expect(backupOf(const []), isNot(same));
      // A difference above the list level is caught too.
      expect(
        backupOf([_task('T1', 'L1', 'Buy milk')], title: 'Work'),
        isNot(same),
      );
    });

    test('a task differing in one optional field is not equal', () {
      const base = BackupTask(
        id: 'T1',
        position: 'p',
        title: 'Buy milk',
        status: 'needsAction',
        updated: 'u',
        syncState: 'clean',
        localUpdated: 'lu',
      );
      expect(
        const BackupTask(
          id: 'T1',
          position: 'p',
          title: 'Buy milk',
          status: 'needsAction',
          updated: 'u',
          syncState: 'clean',
          localUpdated: 'lu',
        ),
        base,
      );
      expect(
        const BackupTask(
          id: 'T1',
          position: 'p',
          title: 'Buy milk',
          notes: 'and bread',
          status: 'needsAction',
          updated: 'u',
          syncState: 'clean',
          localUpdated: 'lu',
        ),
        isNot(base),
      );
      // The queue records participate in equality, so a lost move or marker
      // fails a round-trip assertion instead of passing silently.
      expect(
        const BackupTask(
          id: 'T1',
          position: 'p',
          title: 'Buy milk',
          status: 'needsAction',
          updated: 'u',
          syncState: 'clean',
          localUpdated: 'lu',
          move: BackupMove(parent: 'P0'),
        ),
        isNot(base),
      );
      expect(
        const BackupTask(
          id: 'T1',
          position: 'p',
          title: 'Buy milk',
          status: 'needsAction',
          updated: 'u',
          syncState: 'clean',
          localUpdated: 'lu',
          inflight: BackupInflight(),
        ),
        isNot(base),
      );
      // Different values inside a queue record are different too.
      expect(
        const BackupMove(parent: 'P0', previous: 'T0'),
        isNot(const BackupMove(parent: 'P0')),
      );
      expect(
        const BackupInflight(baseLocalUpdated: 'x'),
        isNot(const BackupInflight()),
      );
    });
  });
}
