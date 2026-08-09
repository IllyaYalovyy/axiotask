// Unit layer — the pure sync decision core, push-side half (RFC-009
// §B/§C/§D/§G + failure classification). The Dart port of the enumerated
// `reconcile.rs` tests for those sections; each is the SPEC for one decision
// function, so a divergence from the reference matrix fails here rather than
// silently corrupting a user's data during a sync run (MIGRATION-PLAN §5 T5.3).
//
// Every assertion is on the returned DECISION (the value a pure function
// produces), never on plumbing — these functions have no IO to mock.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/model/base_snapshot.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/sync/reconcile.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synced task with a server etag (mirrors the reference `task` helper).
Task task(String id) => Task(
  id: id,
  position: '00000000000000000000',
  title: 'task $id',
  status: TaskStatus.needsAction,
  etag: 'etag-$id',
  updated: '2026-01-01T00:00:00.000Z',
  webViewLink: 'https://tasks.google.com/$id',
);

/// A clean stored row wrapping [t].
StoredTask stored(Task t) => StoredTask(
  task: t,
  listId: 'L',
  syncState: SyncState.clean,
  localUpdated: t.updated,
);

Set<String> idSet(List<String> v) => v.toSet();

void main() {
  group('failure classification', () {
    test('push_failure classifies transient / auth / rejection', () {
      expect(pushFailure(const ServerError(503)), PushFailure.retry);
      expect(pushFailure(const RateLimited()), PushFailure.retry);
      expect(pushFailure(const Network('reset')), PushFailure.retry);
      expect(pushFailure(const Unauthorized()), PushFailure.abort);
      expect(
        pushFailure(const AuthExpired('invalid_grant')),
        PushFailure.abort,
      );
      // A poisoned row is counted and skipped, never fatal.
      expect(
        pushFailure(const OtherApiError('400 bad request')),
        PushFailure.reject,
      );
    });

    test('ref_state reads etag presence', () {
      expect(RefState.of(null), RefState.missing);
      expect(RefState.of(stored(task('a'))), RefState.synced);
      // An unpushed row carries no etag — build it directly, since copyWith
      // cannot clear etag back to null.
      final local = StoredTask(
        task: const Task(
          id: 'a',
          position: '0',
          title: 'a',
          status: TaskStatus.needsAction,
          updated: 'u',
        ),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
      );
      expect(RefState.of(local), RefState.local);
    });
  });

  group('§B/§C content update', () {
    test('update 412 resolves a conflict', () {
      expect(
        onUpdateError(const PreconditionFailed()),
        const UpdateResolveConflict(),
      );
    });

    test('update 404 hard-deletes local (delete wins)', () {
      // A task PATCH only 404s when its whole LIST was deleted; delete wins (P4).
      expect(onUpdateError(const NotFound()), const UpdateDeleteLocal());
    });

    test('update other errors defer to push_failure', () {
      expect(
        onUpdateError(const ServerError(500)),
        const UpdateFailed(PushFailure.retry),
      );
      expect(
        onUpdateError(const Unauthorized()),
        const UpdateFailed(PushFailure.abort),
      );
      expect(
        onUpdateError(const OtherApiError('bad due')),
        const UpdateFailed(PushFailure.reject),
      );
    });

    test('conflict with identical content adopts remote (no copy)', () {
      final local = task('t1');
      final remote = task('t1').copyWith(etag: 'newer');
      expect(resolveConflict(local, remote), ConflictResolution.adoptRemote);
    });

    test('conflict ignores due normalization and empty notes', () {
      final local = task('t1').copyWith(due: '2026-03-04T00:00:00Z', notes: '');
      final remote = task('t1').copyWith(due: '2026-03-04T00:00:00.000Z');
      expect(resolveConflict(local, remote), ConflictResolution.adoptRemote);
    });

    test('conflict ignores position/parent so a remote move makes no copy', () {
      // §B × moved/reparented: content untouched, so a bumped etag must NOT
      // manufacture a conflicted copy (P3).
      final local = task('t1');
      final remote = task(
        't1',
      ).copyWith(parent: 'p9', position: '99999999999999999999', etag: 'moved');
      expect(resolveConflict(local, remote), ConflictResolution.adoptRemote);
    });

    test('conflict with divergent title preserves both', () {
      final local = task('t1').copyWith(title: 'mine');
      final remote = task('t1').copyWith(title: 'theirs');
      expect(resolveConflict(local, remote), ConflictResolution.conflictedCopy);
    });

    test('status-only divergence resolves remote-wins (D1, no copy)', () {
      // §C, D1: only the checkbox differs — remote wins outright, both ways.
      final local = task('t1');
      final remote = task('t1').copyWith(status: TaskStatus.completed);
      expect(resolveConflict(local, remote), ConflictResolution.adoptRemote);

      final localDone = task('t1').copyWith(status: TaskStatus.completed);
      expect(
        resolveConflict(localDone, task('t1')),
        ConflictResolution.adoptRemote,
      );
    });

    test(
      'status divergence alongside content divergence still preserves both',
      () {
        // §C: D1 is narrow. The moment anything the user typed also diverges,
        // P3 applies and the local edit survives as a copy.
        final local = task(
          't1',
        ).copyWith(title: 'mine', status: TaskStatus.completed);
        final remote = task('t1').copyWith(title: 'theirs');
        expect(
          resolveConflict(local, remote),
          ConflictResolution.conflictedCopy,
        );

        final notesLocal = task(
          't1',
        ).copyWith(notes: 'mine', status: TaskStatus.completed);
        expect(
          resolveConflict(notesLocal, task('t1')),
          ConflictResolution.conflictedCopy,
        );

        final dueLocal = task('t1').copyWith(
          due: '2026-03-04T00:00:00.000Z',
          status: TaskStatus.completed,
        );
        expect(
          resolveConflict(dueLocal, task('t1')),
          ConflictResolution.conflictedCopy,
        );
      },
    );

    test('D1 does not leak into orphan adoption', () {
      // D1 relaxes CONFLICT resolution only. The TOP-LEVEL content match
      // (`findOrphan` / `sameContent`) still counts status.
      final local = task('local-uuid');
      final committed = task(
        'server-id',
      ).copyWith(title: local.title, status: TaskStatus.completed);
      expect(findOrphan(local, [committed], <String>{}), isNull);
      expect(
        sameContent(
          local,
          task('x').copyWith(title: local.title, status: TaskStatus.completed),
        ),
        isFalse,
      );
    });

    test('conflict refetch failures', () {
      expect(
        onConflictRefetchError(const NotFound()),
        RefetchFailure.deleteLocal,
      );
      expect(
        onConflictRefetchError(const ServerError(503)),
        RefetchFailure.stayDirty,
      );
      // Non-transient, non-404 aborts and preserves the local edit.
      expect(
        onConflictRefetchError(const OtherApiError('bad json')),
        RefetchFailure.abort,
      );
      expect(
        onConflictRefetchError(const Unauthorized()),
        RefetchFailure.abort,
      );
    });

    test('update_patch canonicalizes due and clears notes', () {
      final row = stored(task('t1').copyWith(due: '2026-03-04', notes: null));
      final patch = updatePatch(row);
      expect(patch.due, '2026-03-04T00:00:00.000Z');
      // Cleared notes go as "" so the server actually clears them.
      expect(patch.notes, '');
      expect(patch.status, TaskStatus.needsAction);
      expect(patch.title, 'task t1');
    });

    test('update_patch degrades an unparseable due to clear', () {
      final row = stored(task('t1').copyWith(due: 'not a date'));
      expect(updatePatch(row).due, '');
    });

    test('#118 only_local_diverged true for a bare remote reorder', () {
      const base = BaseSnapshot(
        title: 't',
        notes: '',
        due: '2026-03-04T00:00:00Z',
        status: TaskStatus.needsAction,
      );
      final reordered = task('t1').copyWith(
        title: 't',
        notes: null,
        due: '2026-03-04T00:00:00.000Z',
        parent: 'p9',
        position: '99999999999999999999',
        etag: 'bumped',
      );
      expect(onlyLocalDiverged(reordered, base), isTrue);

      // Status is EXCLUDED: a completed-parent cascade flips server status.
      final cascaded = reordered.copyWith(status: TaskStatus.completed);
      expect(
        onlyLocalDiverged(cascaded, base),
        isTrue,
        reason: 'a status-only server change is not a typed-content divergence',
      );

      // A genuine remote TYPED edit is a real divergence — not "only local".
      final theirs = reordered.copyWith(title: 'theirs');
      expect(onlyLocalDiverged(theirs, base), isFalse);
    });

    test('conflicted_copy is an unpushed create that keeps the local edit', () {
      final local = stored(
        task(
          't1',
        ).copyWith(title: 'mine', due: '2026-03-04T00:00:00Z', parent: 'p1'),
      );
      final remote = task('t1').copyWith(title: 'theirs');
      final copy = conflictedCopy(local, remote, 'new-uuid');
      expect(copy.task.id, 'new-uuid');
      expect(copy.task.title, 'mine (conflicted copy)');
      expect(copy.task.due, '2026-03-04T00:00:00Z');
      expect(copy.task.parent, 'p1');
      // Unpushed: no etag, dirty, pending create (P2).
      expect(copy.task.etag, isNull);
      expect(copy.syncState, SyncState.dirty);
      expect(copy.pendingOp, 'create');
      // Adopts the remote's updated stamp so a later pull re-checks it.
      expect(copy.task.updated, remote.updated);
      expect(copy.localUpdated, remote.updated);
    });

    test('conflicted_copy stacks its suffix and survives an empty title', () {
      final remote = task('t1');
      final empty = stored(task('t1').copyWith(title: ''));
      expect(
        conflictedCopy(empty, remote, 'id-a').task.title,
        ' (conflicted copy)',
      );
      final once = stored(
        task('t1').copyWith(title: 'buy milk (conflicted copy)'),
      );
      expect(
        conflictedCopy(once, remote, 'id-b').task.title,
        'buy milk (conflicted copy) (conflicted copy)',
      );
    });
  });

  group('§D delete', () {
    test('delete succeeds and 404 counts as success', () {
      expect(planDelete(null), const HardDeleteLocal());
      expect(planDelete(const NotFound()), const HardDeleteLocal());
    });

    test('delete wins in both directions', () {
      // P4: planDelete takes nothing but the error — nothing the server did to
      // the row can talk a pending delete out of landing.
      expect(planDelete(null), const HardDeleteLocal());
      expect(onUpdateError(const NotFound()), const UpdateDeleteLocal());
      expect(
        onConflictRefetchError(const NotFound()),
        RefetchFailure.deleteLocal,
      );
    });

    test('delete failures defer to push_failure', () {
      expect(
        planDelete(const Network('down')),
        const DeleteFailed(PushFailure.retry),
      );
      expect(
        planDelete(const AuthExpired('gone')),
        const DeleteFailed(PushFailure.abort),
      );
      expect(
        planDelete(const OtherApiError('403')),
        const DeleteFailed(PushFailure.reject),
      );
    });
  });

  group('§G create', () {
    test('create eligibility gate', () {
      final none = <String>{};
      expect(createIsEligible('create', 'a', none, none, null), isTrue);
      // Not a create.
      expect(createIsEligible('update', 'a', none, none, null), isFalse);
      expect(createIsEligible(null, 'a', none, none, null), isFalse);
      // Already attempted this run — never twice (duplicate insert).
      expect(
        createIsEligible('create', 'a', idSet(['a']), none, null),
        isFalse,
      );
      // Unresolved in-flight marker — waits for a complete remote view.
      expect(
        createIsEligible('create', 'a', none, idSet(['a']), null),
        isFalse,
      );
      // The one id the UI holds waits; every other create still pushes.
      expect(createIsEligible('create', 'a', none, none, 'a'), isFalse);
      expect(createIsEligible('create', 'b', none, none, 'a'), isTrue);
    });

    test('a mutation waits while its own create is unresolved in-flight', () {
      final none = <String>{};
      expect(mutationIsPushable('a', none), isTrue);
      expect(mutationIsPushable('a', idSet(['a'])), isFalse);
      expect(
        mutationIsPushable('b', idSet(['a'])),
        isTrue,
        reason: 'only the row behind the marker waits',
      );
    });

    test('subtask create waits for an unpushed parent', () {
      expect(parentIsPushable(null), isTrue);
      expect(parentIsPushable(RefState.synced), isTrue);
      expect(parentIsPushable(RefState.local), isFalse);
      expect(parentIsPushable(RefState.missing), isFalse);
    });

    test('subtask create anchors after its last synced sibling', () {
      final child = StoredTask(
        task: Task(
          id: 'new',
          parent: 'p',
          position: '00000000000000000000',
          title: 'task new',
          status: TaskStatus.needsAction,
          updated: 'u',
        ),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
      );
      final sibA = stored(
        task('a').copyWith(parent: 'p', position: '00000000000000000001'),
      );
      final sibB = stored(
        task('b').copyWith(parent: 'p', position: '00000000000000000002'),
      );
      // Unsynced sibling: naming its local UUID would draw a 400.
      final sibC = StoredTask(
        task: Task(
          id: 'c',
          parent: 'p',
          position: '00000000000000000009',
          title: 'task c',
          status: TaskStatus.needsAction,
          updated: 'u',
        ),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
      );
      // Another parent's child must never be used as the anchor.
      final other = stored(
        task('z').copyWith(parent: 'q', position: '00000000000000000099'),
      );

      final rows = [child, sibA, sibB, sibC, other];
      expect(createPreviousAnchor(child, rows), 'b');

      final top = stored(task('top'));
      expect(createPreviousAnchor(top, rows), isNull);
    });

    test('create_payload canonicalizes due and carries the anchor', () {
      final row = stored(task('t1').copyWith(due: '2026-03-04', parent: 'p'));
      final payload = createPayload(row, 'b');
      expect(payload.due, '2026-03-04T00:00:00.000Z');
      expect(payload.parent, 'p');
      expect(payload.previous, 'b');
      expect(payload.status, TaskStatus.needsAction);
      expect(payload.title, 'task t1');
    });

    test('transient create failure keeps the in-flight marker', () {
      expect(onCreateError(const ServerError(502)), const KeepInflight());
      expect(
        onCreateError(const OtherApiError('400')),
        const ClearInflight(PushFailure.reject),
      );
      expect(
        onCreateError(const Unauthorized()),
        const ClearInflight(PushFailure.abort),
      );
    });

    test('orphan adoption is scoped to content and unknown ids', () {
      final local = task('local-uuid');
      final committed = task('server-id').copyWith(title: local.title);
      // Our content under an id we never recorded → adopt it.
      expect(
        findOrphan(local, [committed], idSet(['local-uuid']))?.id,
        'server-id',
      );
      // Already tracked locally → not an orphan.
      expect(findOrphan(local, [committed], idSet(['server-id'])), isNull);
      // Different content → never merged (duplicate titles are legal).
      final unrelated = task('other').copyWith(title: 'something else');
      expect(findOrphan(local, [unrelated], <String>{}), isNull);
    });

    test('find_orphan_by_base adopts despite a mid-flight edit', () {
      // #122: the row was edited during the in-flight window, so its CURRENT
      // content misses — but the base (the payload as sent) still adopts it.
      const base = BaseSnapshot(
        title: 'buy milk',
        status: TaskStatus.needsAction,
      );
      final committed = task('server-id').copyWith(title: 'buy milk');
      final drifted = task('local-uuid').copyWith(title: 'buy oat milk');
      expect(
        findOrphan(drifted, [committed], <String>{}),
        isNull,
        reason: 'current content misses the orphan',
      );
      expect(
        findOrphanByBase(base, null, [committed], <String>{})?.id,
        'server-id',
      );
      // A row we already track locally is never re-adopted.
      expect(
        findOrphanByBase(base, null, [committed], idSet(['server-id'])),
        isNull,
      );
    });

    test('find_orphan_by_base tolerates the completed-parent cascade', () {
      // RFC-009 §G: a subtask inserted under a completed parent is stored
      // already completed; the payload and committed row disagree only on
      // status. Adopt it (subtask); top-level stays strict.
      const base = BaseSnapshot(title: 'sub', status: TaskStatus.needsAction);
      final sub = task(
        'server-sub',
      ).copyWith(title: 'sub', parent: 'P1', status: TaskStatus.completed);
      expect(findOrphanByBase(base, 'P1', [sub], <String>{})?.id, 'server-sub');

      final toplevel = task(
        'server-top',
      ).copyWith(title: 'sub', status: TaskStatus.completed);
      expect(
        findOrphanByBase(base, null, [toplevel], <String>{}),
        isNull,
        reason: 'status stays strict without a completed-parent explanation',
      );
    });

    test('find_orphan requires matching parent (#145)', () {
      final local = task('local-uuid').copyWith(parent: 'P1');
      final foreignTop = task('foreign-top').copyWith(title: local.title);
      expect(
        findOrphan(local, [foreignTop], <String>{}),
        isNull,
        reason: 'a top-level row is not our P1 subtask orphan',
      );

      final foreignP2 = task(
        'foreign-p2',
      ).copyWith(title: local.title, parent: 'P2');
      expect(
        findOrphan(local, [foreignP2], <String>{}),
        isNull,
        reason: 'a different parent is not our orphan',
      );

      final ours = task(
        'server-sub',
      ).copyWith(title: local.title, parent: 'P1');
      expect(
        findOrphan(local, [foreignTop, foreignP2, ours], <String>{})?.id,
        'server-sub',
      );
    });

    test('find_orphan_by_base requires matching parent (#145)', () {
      const base = BaseSnapshot(title: 'sub', status: TaskStatus.needsAction);
      final foreignTop = task('foreign-top').copyWith(title: 'sub');
      expect(findOrphanByBase(base, 'P1', [foreignTop], <String>{}), isNull);

      final foreignP2 = task('foreign-p2').copyWith(title: 'sub', parent: 'P2');
      expect(findOrphanByBase(base, 'P1', [foreignP2], <String>{}), isNull);

      final ours = task('server-sub').copyWith(title: 'sub', parent: 'P1');
      expect(
        findOrphanByBase(base, 'P1', [ours], <String>{})?.id,
        'server-sub',
      );

      // A top-level create must never adopt a parented row.
      final child = task('child').copyWith(title: 'sub', parent: 'P9');
      expect(findOrphanByBase(base, null, [child], <String>{}), isNull);
    });
  });

  group('content comparison', () {
    test('empty notes count as cleared notes', () {
      final cleared = task('t1').copyWith(notes: '');
      final absent = task('t1').copyWith(notes: null);
      expect(sameContent(cleared, absent), isTrue);
      expect(sameTypedContent(cleared, absent), isTrue);

      final real = task('t1').copyWith(notes: 'keep');
      expect(sameContent(cleared, real), isFalse);
      expect(sameTypedContent(cleared, real), isFalse);
    });

    test('same_content covers exactly title/notes/due/status', () {
      final a = task('x');
      final b = task('y').copyWith(title: a.title); // different id and etag
      expect(sameContent(a, b), isTrue);

      expect(sameContent(a, b.copyWith(notes: 'hi')), isFalse);
      expect(
        sameContent(a, b.copyWith(due: '2026-03-04T00:00:00.000Z')),
        isFalse,
      );
      expect(sameContent(a, b.copyWith(status: TaskStatus.completed)), isFalse);
    });
  });
}
