// Port of `api/in_memory.rs`'s in-file `mod tests`, PART 1 (T3.2): the CRUD
// semantics of the strict in-memory fake — list/task insert/get/patch/delete,
// due-format + char-limit validation, soft-delete tombstones (200-echo, never a
// 412), the delete and completion cascades, and the etag counter + If-Match
// 412. Positioning/move/pagination and the full fault-injection surface are
// covered by T3.3.
//
// Each test pins a server behavior verified against the LIVE Google Tasks API
// (RFC-009). The fake mirrors that strictness on purpose: a permissive fake
// lets the whole sync suite pass while production sync is broken. Never loosen
// it to make a test go green.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 1024/8192 documented limits, kept local so tests don't reach into the
/// implementation's private constants (Google Tasks docs, verified 2026-07-28).
const int maxTitleChars = 1024;
const int maxNotesChars = 8192;

void main() {
  group('task lists — insert / list / patch / delete', () {
    test('seeded lists are returned', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final lists = await c.listTasklists();
      expect(lists, hasLength(1));
      expect(lists.single.title, 'Inbox');
    });

    test(
      'insert_tasklist returns the server view with an id and etag',
      () async {
        final c = FakeTasksApi();
        final created = await c.insertTasklist('Groceries');
        expect(created.title, 'Groceries');
        expect(created.id, isNotEmpty);
        expect(created.etag, isNotNull);
        // …and it is now listable.
        expect((await c.listTasklists()).single.id, created.id);
      },
    );

    test('patch_tasklist renames and bumps the etag', () async {
      final c = FakeTasksApi();
      final l = c.seedList('L1', 'Inbox');
      final renamed = await c.patchTasklist('L1', 'Errands');
      expect(renamed.title, 'Errands');
      expect(renamed.etag, isNot(l.etag));
      expect((await c.listTasklists()).single.title, 'Errands');
    });

    test('patch_tasklist of an unknown list is NotFound', () async {
      final c = FakeTasksApi();
      await expectLater(
        c.patchTasklist('missing', 'x'),
        throwsA(isA<NotFound>()),
      );
    });

    test(
      'delete_tasklist cascades its tasks and is NotFound when missing',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'T1', 'a', '00000000000001');
        await c.deleteTasklist('L1');
        expect(await c.listTasklists(), isEmpty);
        // A second delete of the now-gone list is a NotFound.
        await expectLater(c.deleteTasklist('L1'), throwsA(isA<NotFound>()));
      },
    );
  });

  group('insert / patch / etag', () {
    test('insert then patch changes the etag and applies the edit', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final inserted = await c.insertTask('L1', const NewTask(title: 'foo'));
      final beforeEtag = inserted.etag;
      final patched = await c.patchTask(
        'L1',
        inserted.id,
        const TaskPatch(title: 'bar'),
        etag: beforeEtag,
      );
      expect(patched.title, 'bar');
      expect(patched.etag, isNot(beforeEtag));
    });

    test('a stale etag returns PreconditionFailed', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = await c.insertTask('L1', const NewTask(title: 'x'));
      await expectLater(
        c.patchTask(
          'L1',
          t.id,
          const TaskPatch(title: 'y'),
          etag: 'wrong-etag',
        ),
        throwsA(isA<PreconditionFailed>()),
      );
    });

    test('patch without an etag always succeeds (unconditional)', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = c.seedTask('L1', 'T1', 'orig', '1');
      final patched = await c.patchTask(
        'L1',
        t.id,
        const TaskPatch(title: 'new'),
      );
      expect(patched.title, 'new');
      expect((await c.getTask('L1', 'T1')).title, 'new');
    });

    test('insert to a nonexistent list is NotFound', () async {
      final c = FakeTasksApi();
      await expectLater(
        c.insertTask('no-list', const NewTask(title: 'x')),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('validation — due format', () {
    test('a bare YYYY-MM-DD due is a permanent 400; a full timestamp is '
        'normalized', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');

      // A bare date is rejected (the live API requires a full RFC-3339 stamp).
      final err = await _caught(
        () => c.insertTask('L1', const NewTask(title: 't', due: '2026-08-07')),
      );
      expect(err, isA<OtherApiError>());
      expect(
        (err as ApiError).isTransient,
        isFalse,
        reason: 'a bad due is a permanent rejection, never retried',
      );

      // A full timestamp is accepted and normalized to `.000Z`.
      final ok = await c.insertTask(
        'L1',
        const NewTask(title: 't', due: '2026-08-07T09:30:00Z'),
      );
      expect(
        ok.due,
        '2026-08-07T00:00:00.000Z',
        reason: 'time component discarded, normalized to midnight .000Z',
      );

      // The same rule applies on patch.
      await expectLater(
        c.patchTask(
          'L1',
          ok.id,
          const TaskPatch(due: '2026-08-07'),
          etag: ok.etag,
        ),
        throwsA(isA<OtherApiError>()),
      );
    });

    test('an empty-string due clears the field to null', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = await c.insertTask(
        'L1',
        const NewTask(title: 't', due: '2026-08-07T00:00:00.000Z'),
      );
      expect(t.due, isNotNull);
      final cleared = await c.patchTask(
        'L1',
        t.id,
        const TaskPatch(due: ''),
        etag: t.etag,
      );
      expect(cleared.due, isNull);
      expect((await c.getTask('L1', t.id)).due, isNull);
    });
  });

  group('validation — char limits', () {
    test(
      'oversize title and notes are permanent 400s on insert and patch',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');

        // The exact boundary lengths are accepted.
        final ok = await c.insertTask(
          'L1',
          NewTask(title: 't' * maxTitleChars, notes: 'n' * maxNotesChars),
        );
        expect(ok.title.length, maxTitleChars);

        // One char over the title limit → permanent 400.
        final titleErr = await _caught(
          () => c.insertTask('L1', NewTask(title: 't' * (maxTitleChars + 1))),
        );
        expect(titleErr, isA<OtherApiError>());
        expect((titleErr as ApiError).isTransient, isFalse);

        // One char over the notes limit → permanent 400.
        final notesErr = await _caught(
          () => c.insertTask(
            'L1',
            NewTask(title: 'ok', notes: 'n' * (maxNotesChars + 1)),
          ),
        );
        expect(notesErr, isA<OtherApiError>());
        expect((notesErr as ApiError).isTransient, isFalse);

        // An oversize patch is the same 400 — and it leaves the row (and its
        // etag) untouched: the reject is total.
        await expectLater(
          c.patchTask(
            'L1',
            ok.id,
            TaskPatch(notes: 'n' * (maxNotesChars + 1)),
            etag: ok.etag,
          ),
          throwsA(isA<OtherApiError>()),
        );
        expect(
          (await c.getTask('L1', ok.id)).etag,
          ok.etag,
          reason: 'a rejected oversize patch does not mutate the row',
        );
      },
    );

    test('multi-byte characters count as characters, not bytes', () async {
      // 1024 emoji (~4 bytes each) is within the 1024-CHAR title limit even
      // though the byte length is far over. Google counts characters.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = await c.insertTask('L1', NewTask(title: '😀' * maxTitleChars));
      expect(t.title.runes.length, maxTitleChars);
    });

    test('an empty title is a valid untitled task, not a 400', () async {
      // Google Tasks allows an untitled task; an empty title is a valid value,
      // NOT the "invalid argument" an oversize title is.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = await c.insertTask('L1', const NewTask(title: ''));
      expect(t.title, '');
      // Clearing a title back to empty is likewise accepted.
      final recleared = await c.patchTask(
        'L1',
        t.id,
        const TaskPatch(title: ''),
        etag: t.etag,
      );
      expect(recleared.title, '');
    });
  });

  group('notes clearing', () {
    test('an empty-string notes patch clears the field to null', () async {
      // Live-API rule (RFC-009): `notes: ""` CLEARS the field — the server
      // stores and returns absent notes, never a stored empty string.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = await c.insertTask(
        'L1',
        const NewTask(title: 'has notes', notes: 'something'),
      );
      expect(t.notes, 'something');
      final cleared = await c.patchTask(
        'L1',
        t.id,
        const TaskPatch(notes: ''),
        etag: t.etag,
      );
      expect(cleared.notes, isNull);
      expect((await c.getTask('L1', t.id)).notes, isNull);
    });
  });

  group('soft delete — tombstones', () {
    test(
      'delete soft-deletes: gone from list_tasks but still gettable',
      () async {
        // Live-API soft delete (RFC-009 #106): after DELETE the row vanishes from
        // list_tasks (showDeleted defaults off) but a direct get still answers
        // 200, flagged deleted.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final t = c.seedTask('L1', 'T1', 'first', '00000000000001');
        await c.deleteTask('L1', t.id);

        expect(
          (await c.listTasks('L1')).items,
          isEmpty,
          reason: 'a deleted task is absent from list_tasks',
        );
        final got = await c.getTask('L1', t.id);
        expect(got.id, 'T1');
        expect(
          got.deleted,
          isTrue,
          reason: 'a by-id refetch carries the deleted tombstone flag',
        );
      },
    );

    test('delete of an unknown task is NotFound', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      await expectLater(c.deleteTask('L1', 'ghost'), throwsA(isA<NotFound>()));
    });

    test('delete soft-deletes the whole subtree (server cascade)', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'P', 'parent', '1');
      c.seedTaskWithParent('L1', 'C', 'child', '2', 'P');
      c.seedTaskWithParent('L1', 'G', 'grandchild', '3', 'C');

      await c.deleteTask('L1', 'P');

      expect(
        (await c.listTasks('L1')).items,
        isEmpty,
        reason: 'parent and every descendant leave list_tasks',
      );
      for (final id in ['P', 'C', 'G']) {
        expect(
          (await c.getTask('L1', id)).id,
          id,
          reason: '$id is soft-deleted, not hard-removed',
        );
      }
    });

    test('patch of a deleted task is 200-and-ignored, not a 404', () async {
      // A PATCH to a soft-deleted task returns 200 with a body echoing the
      // edit, but the row stays deleted and never returns to list_tasks; the
      // stored row is untouched.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final t = c.seedTask('L1', 'T1', 'first', '00000000000001');
      await c.deleteTask('L1', t.id);

      final echo = await c.patchTask(
        'L1',
        t.id,
        const TaskPatch(title: 'edit-after-delete'),
      );
      expect(
        echo.title,
        'edit-after-delete',
        reason: 'the 200 body echoes the requested edit',
      );
      // Nothing revived: still gone from list_tasks, stored title unchanged.
      expect((await c.listTasks('L1')).items, isEmpty);
      expect(
        (await c.getTask('L1', t.id)).title,
        'first',
        reason: 'the edit was silently ignored server-side',
      );
    });

    test(
      'patch of a deleted task with a stale etag still 200s, never 412',
      () async {
        // P4 guard: a delete/edit race must never fork. If a stale-etag PATCH to
        // a deleted row 412'd, the 412-resolution path would fabricate a
        // conflicted copy of a row that is actually gone. The live service
        // answers 200-and-ignore regardless of If-Match.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final t = c.seedTask('L1', 'T1', 'first', '00000000000001');
        await c.deleteTask('L1', t.id);

        final resp = await c.patchTask(
          'L1',
          t.id,
          const TaskPatch(title: 'nope'),
          etag: 'definitely-stale-etag',
        );
        expect(
          resp.title,
          'nope',
          reason: 'a stale etag on a deleted row is 200-echo, not a 412',
        );
        expect((await c.listTasks('L1')).items, isEmpty);
      },
    );

    test('a soft-deleted parent rejects new inserts under it', () async {
      // A soft-deleted parent is not a live task, so an insert naming it is a
      // permanent 400 — the same rule an unknown parent draws.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'P', 'parent', '1');
      await c.deleteTask('L1', 'P');
      final err = await _caught(
        () => c.insertTask('L1', const NewTask(title: 'orphan', parent: 'P')),
      );
      expect(
        (err as ApiError).isTransient,
        isFalse,
        reason: 'an unknown/deleted parent is a permanent rejection',
      );
    });
  });

  group('completion cascade', () {
    test(
      'completing a parent completes its whole subtree server-side',
      () async {
        // Live-API cascade: completing a parent auto-completes its descendants,
        // each with a fresh etag and a completed stamp.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final p = c.seedTask('L1', 'P', 'parent', '1');
        c.seedTaskWithParent('L1', 'C1', 'kid', '2', 'P');
        c.seedTaskWithParent('L1', 'C2', 'grandkid', '3', 'C1');

        await c.patchTask(
          'L1',
          p.id,
          const TaskPatch(status: TaskStatus.completed),
          etag: p.etag,
        );

        final all = (await c.listTasks('L1')).items;
        expect(
          all.every((t) => t.status == TaskStatus.completed),
          isTrue,
          reason: 'parent and every descendant are completed',
        );
        expect(
          all.every((t) => t.completed == '2026-01-01T00:00:00Z'),
          isTrue,
          reason: 'each cascaded task carries a completed timestamp',
        );
      },
    );

    test(
      'inserting a subtask under a completed parent returns it completed',
      () async {
        // Live-API probe 5: the insert is accepted and the child comes back
        // ALREADY completed, in the insert response body itself.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final p = c.seedTask('L1', 'P', 'done-parent', '00000000000001');
        await c.patchTask(
          'L1',
          'P',
          const TaskPatch(status: TaskStatus.completed),
          etag: p.etag,
        );

        final child = await c.insertTask(
          'L1',
          const NewTask(title: 'new-subtask', parent: 'P'),
        );
        expect(
          child.status,
          TaskStatus.completed,
          reason: 'insert response already carries the cascaded completion',
        );
        expect(child.completed, isNotNull);
        expect((await c.getTask('L1', child.id)).status, TaskStatus.completed);
      },
    );

    test('inserting a child does not change the parent etag', () async {
      // Live-API probe 6a: another client adding a subtask must not stale our
      // copy of the parent, or a local complete would spuriously 412.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final p = c.seedTask('L1', 'P', 'parent', '00000000000001');
      await c.insertTask('L1', const NewTask(title: 'late-child', parent: 'P'));
      expect(
        (await c.getTask('L1', 'P')).etag,
        p.etag,
        reason: 'a child insert must leave the parent etag alone',
      );
    });

    test('completing a parent cascades to a child we never pulled', () async {
      // Live-API probe 6b: the cascade covers children the client never saw,
      // and completing with the PRE-child etag still lands (no 412).
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final p = c.seedTask('L1', 'P', 'parent', '00000000000001');
      final snapshotEtag = p.etag;
      final unseen = await c.insertTask(
        'L1',
        const NewTask(title: 'unseen-child', parent: 'P'),
      );

      await c.patchTask(
        'L1',
        'P',
        const TaskPatch(status: TaskStatus.completed),
        etag: snapshotEtag,
      );

      expect(
        (await c.getTask('L1', unseen.id)).status,
        TaskStatus.completed,
        reason: 'the cascade takes a child the client never pulled',
      );
    });

    test(
      'reopening a child of a completed parent is silently ignored',
      () async {
        // Live-API behavior: patching a subtask back to needsAction while its
        // parent stays completed returns 200 but is a no-op server-side.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final p = c.seedTask('L1', 'P', 'parent', '1');
        c.seedTaskWithParent('L1', 'C1', 'kid', '2', 'P');
        await c.patchTask(
          'L1',
          p.id,
          const TaskPatch(status: TaskStatus.completed),
          etag: p.etag,
        );

        final child = await c.getTask('L1', 'C1');
        final resp = await c.patchTask(
          'L1',
          'C1',
          const TaskPatch(status: TaskStatus.needsAction),
          etag: child.etag,
        );
        expect(
          resp.status,
          TaskStatus.completed,
          reason: 'reopen of a completed parent child is silently ignored',
        );
        expect((await c.getTask('L1', 'C1')).status, TaskStatus.completed);
      },
    );

    test('reopening a parent does not reopen its children', () async {
      // Live-API behavior: un-completing a parent leaves its children done.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final p = c.seedTask('L1', 'P', 'parent', '1');
      c.seedTaskWithParent('L1', 'C1', 'kid', '2', 'P');
      await c.patchTask(
        'L1',
        p.id,
        const TaskPatch(status: TaskStatus.completed),
        etag: p.etag,
      );

      final parent = await c.getTask('L1', 'P');
      await c.patchTask(
        'L1',
        'P',
        const TaskPatch(status: TaskStatus.needsAction),
        etag: parent.etag,
      );

      expect((await c.getTask('L1', 'P')).status, TaskStatus.needsAction);
      expect(
        (await c.getTask('L1', 'C1')).status,
        TaskStatus.completed,
        reason: 'child stays completed after the parent reopens',
      );
    });
  });
}

/// Run [action] and return whatever [ApiError] it throws, or `null` on success —
/// used where a test needs the error VALUE (to assert `isTransient`), not just
/// its type.
Future<Object?> _caught(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } on ApiError catch (e) {
    return e;
  }
}
