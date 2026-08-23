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
import 'package:axiotask/src/model/task_list.dart';
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
/// A clean, server-backed stored row. Clean means Google acknowledged it, so
/// it carries a `remote_id` — the id the wire actually names (#224). These
/// helpers pin it equal to the (opaque) local id.
StoredTask stored(Task t) => StoredTask(
  task: t,
  listId: 'L',
  syncState: SyncState.clean,
  localUpdated: t.updated,
  remoteId: t.id,
);

Set<String> idSet(List<String> v) => v.toSet();

/// A remote task list (mirrors the reference `list` helper).
TaskList list(String id, String title) =>
    TaskList(id: id, title: title, etag: 'etag-$id', updated: 'u');

/// A clean stored list wrapping [l].
StoredTaskList storedList(TaskList l) => StoredTaskList(
  list: l,
  syncState: SyncState.clean,
  localUpdated: l.updated,
);

/// A task with an explicit parent, for the move / depth tests.
Task childTask(String id, String? parent) => task(id).copyWith(parent: parent);

/// A move ref-set with everything unset but [task]/[parent]/[previous].
MoveRefs refs(RefState taskState, RefState? parent, RefState? previous) =>
    MoveRefs(task: taskState, parent: parent, previous: previous);

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

    test('ref_state reads whether the server acknowledged the row', () {
      expect(RefState.of(null), RefState.missing);
      expect(RefState.of(stored(task('a'))), RefState.synced);
      // An unpushed row has no remote id, so there is nothing to name it by.
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
      // Unsynced sibling: it has no remote id, so it cannot be named at all.
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
      expect(
        createPreviousAnchor(child, rows),
        'b',
        reason: 'the anchor is the sibling\'s WIRE id',
      );

      final top = stored(task('top'));
      expect(createPreviousAnchor(top, rows), isNull);
    });

    test('create_payload canonicalizes due and carries the anchor', () {
      final row = stored(task('t1').copyWith(due: '2026-03-04', parent: 'p'));
      final payload = createPayload(row, 'b', 'remote-p');
      expect(payload.due, '2026-03-04T00:00:00.000Z');
      expect(
        payload.parent,
        'remote-p',
        reason: 'the wire payload names Google\'s parent id, not the local one',
      );
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

  group('§E/§F moves', () {
    test('move with all ids synced is sent whole', () {
      expect(
        planMove(refs(RefState.synced, RefState.synced, RefState.synced)),
        const MoveSend(keepPrevious: true),
      );
      // A bare reorder to the top of a list names neither ref.
      expect(
        planMove(refs(RefState.synced, null, null)),
        const MoveSend(keepPrevious: false),
      );
    });

    test('move whose target parent vanished is dropped', () {
      expect(
        planMove(refs(RefState.synced, RefState.missing, RefState.synced)),
        const MoveDrop(),
      );
    });

    test('move whose previous vanished degrades to the reparent', () {
      // P5: degrade, never wedge — the reparent is still expressible.
      expect(
        planMove(refs(RefState.synced, RefState.synced, RefState.missing)),
        const MoveSend(keepPrevious: false),
      );
    });

    test('move waits while any named id is still local', () {
      expect(planMove(refs(RefState.local, null, null)), const MoveWait());
      expect(planMove(refs(RefState.missing, null, null)), const MoveWait());
      expect(
        planMove(refs(RefState.synced, RefState.local, null)),
        const MoveWait(),
      );
      expect(
        planMove(refs(RefState.synced, null, RefState.local)),
        const MoveWait(),
      );
    });

    test('a vanished previous does not rescue an unsynced parent', () {
      // Degradation drops the ordering, but the reparent still names a
      // local-only id — that must still wait, not be sent as a 400.
      expect(
        planMove(refs(RefState.synced, RefState.local, RefState.missing)),
        const MoveWait(),
      );
    });

    test('move_previous_id follows the plan', () {
      const mv = PendingMove(
        taskId: 't',
        listId: 'L',
        parentId: 'p',
        previousId: 'b',
      );
      expect(movePreviousId(mv, const MoveSend(keepPrevious: true)), 'b');
      expect(movePreviousId(mv, const MoveSend(keepPrevious: false)), isNull);
      expect(movePreviousId(mv, const MoveWait()), isNull);
    });

    test('move adopts the body only for a clean row', () {
      expect(moveAdoption(stored(task('t'))), MoveAdoption.body);
      // A pending content edit must survive the move response.
      final dirty = StoredTask(
        task: task('t'),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
        pendingOp: 'update',
      );
      expect(moveAdoption(dirty), MoveAdoption.metaOnly);
      expect(moveAdoption(null), MoveAdoption.metaOnly);
    });

    test('move failures', () {
      // No `previous` was sent, so a 404 can only mean the subject is gone.
      expect(onMoveError(const NotFound(), false), MoveFailure.dropIntent);
      expect(onMoveError(const ServerError(500), false), MoveFailure.retry);
      expect(onMoveError(const Unauthorized(), false), MoveFailure.abort);
      // A rejected move drops its intent so it can't retry forever (P5).
      expect(
        onMoveError(const OtherApiError('400 invalid'), false),
        MoveFailure.rejectAndDrop,
      );
    });

    test('a move 404 is ambiguous only while a previous was sent', () {
      // §E gap: the move endpoint answers 404 for BOTH "previous task id not
      // found" (probe 2, verified live) and a subject the server no longer has.
      // The ladder resolves the ambiguity by experiment: drop the ordering
      // half, retry.
      expect(
        onMoveError(const NotFound(), true),
        MoveFailure.dropPreviousAndRetry,
      );
      // The retry names no `previous`, so its 404 is unambiguous.
      expect(onMoveError(const NotFound(), false), MoveFailure.dropIntent);
      // Only 404 is ambiguous — every other status means the same either way,
      // so nothing else may enter the ladder.
      for (final sentPrevious in [true, false]) {
        expect(
          onMoveError(
            const OtherApiError('400: Invalid task ID'),
            sentPrevious,
          ),
          MoveFailure.rejectAndDrop,
        );
        expect(
          onMoveError(const ServerError(503), sentPrevious),
          MoveFailure.retry,
        );
        expect(
          onMoveError(const Unauthorized(), sentPrevious),
          MoveFailure.abort,
        );
      }
    });

    test('a demote that would create a third level is refused', () {
      // §F gap: Google ACCEPTS a move that nests a task three deep (probe 3,
      // 200 — there is no depth cap), so invariant #1 is ours to enforce. The
      // moved task already has subtasks of its own — a pull can hand it one
      // after the demote was recorded.
      expect(
        planMove(
          const MoveRefs(
            task: RefState.synced,
            parent: RefState.synced,
            taskHasChildren: true,
          ),
        ),
        const MoveRefuse(),
      );
      // The mirror: the target parent is itself a subtask.
      expect(
        planMove(
          const MoveRefs(
            task: RefState.synced,
            parent: RefState.synced,
            parentIsSubtask: true,
          ),
        ),
        const MoveRefuse(),
      );
    });

    test('a promote or reorder of a parent task is still allowed', () {
      // The refusal is about DEPTH, not about having children: detaching a task
      // with subtasks (parent cleared) leaves the tree one level deep, and so
      // does reordering it among its siblings.
      expect(
        planMove(
          const MoveRefs(
            task: RefState.synced,
            previous: RefState.synced,
            taskHasChildren: true,
          ),
        ),
        const MoveSend(keepPrevious: true),
      );
      // And a childless demote under a top-level parent is the normal path.
      expect(
        planMove(refs(RefState.synced, RefState.synced, null)),
        const MoveSend(keepPrevious: false),
      );
    });
  });

  group('§I list ops', () {
    test('list create adopts a same-title remote list once', () {
      final remote = [list('r1', 'My Tasks'), list('r2', 'Work')];
      expect(adoptableList('My Tasks', remote, <String>{})?.id, 'r1');
      // Already tracked → insert a new remote list instead of colliding.
      expect(adoptableList('My Tasks', remote, idSet(['r1'])), isNull);
      expect(adoptableList('Errands', remote, <String>{}), isNull);
    });

    test('list rename failures', () {
      expect(
        onListRenameError(const NotFound()),
        const ListRenameDeleteLocal(),
      );
      expect(
        onListRenameError(const Network('x')),
        const ListRenameFailed(PushFailure.retry),
      );
      expect(
        onListRenameError(const Unauthorized()),
        const ListRenameFailed(PushFailure.abort),
      );
    });

    test('list delete outcomes', () {
      expect(planListDelete(null), ListDeleteAction.deleteLocal);
      expect(planListDelete(const NotFound()), ListDeleteAction.deleteLocal);
      expect(planListDelete(const ServerError(503)), ListDeleteAction.retry);
      expect(planListDelete(const Unauthorized()), ListDeleteAction.abort);
      // Refused (e.g. the account's default list) — revive rather than nag
      // forever with a tombstone that can never push.
      expect(
        planListDelete(const OtherApiError('403 forbidden')),
        ListDeleteAction.revive,
      );
    });
  });

  group('§G3 / D2 re-home target', () {
    test('rehome_target prefers the default list', () {
      final lists = [
        storedList(list('r1', 'Work')),
        storedList(list('r2', 'My Tasks')),
        storedList(list('r3', 'Dying')),
      ];
      expect(rehomeTarget(lists, 'r3')?.list.id, 'r2');
    });

    test('rehome_target falls back to the first list deterministically', () {
      // No "My Tasks": alphabetical by title, ties broken by id, so the answer
      // never depends on store iteration order.
      final lists = [
        storedList(list('r2', 'Work')),
        storedList(list('r1', 'Work')),
        storedList(list('r3', 'Admin')),
      ];
      expect(rehomeTarget(lists, 'zz')?.list.id, 'r3');
      final ties = [
        storedList(list('r2', 'Work')),
        storedList(list('r1', 'Work')),
      ];
      expect(rehomeTarget(ties, 'zz')?.list.id, 'r1');
    });

    test('rehome_target skips lists that cannot keep the work', () {
      // A local-only list never pushes (the re-homed create would never sync)
      // and a tombstoned list is about to take its rows down again.
      final localOnly = StoredTaskList(
        list: list('r1', 'My Tasks'),
        syncState: SyncState.clean,
        localUpdated: 'u',
        localOnly: true,
      );
      final doomed = StoredTaskList(
        list: list('r2', 'Archive'),
        syncState: SyncState.deleted,
        localUpdated: 'u',
        pendingOp: 'delete',
      );
      final good = storedList(list('r3', 'Work'));

      expect(rehomeTarget([localOnly, doomed, good], 'dying')?.list.id, 'r3');
      // Nothing usable at all — the caller must keep the dying list.
      expect(rehomeTarget([localOnly, doomed], 'dying'), isNull);
      expect(rehomeTarget(<StoredTaskList>[], 'dying'), isNull);
    });

    test('rehome_target never returns the dying list', () {
      expect(rehomeTarget([storedList(list('r1', 'My Tasks'))], 'r1'), isNull);
    });
  });

  group('§A pull', () {
    test('pull_batch skips dirty rows and in-flight orphans', () {
      // The committed orphan carries the base content under a server id.
      final committed = task('server-id').copyWith(title: 'task local-uuid');
      const inflight = InflightBase(
        base: BaseSnapshot(
          title: 'task local-uuid',
          status: TaskStatus.needsAction,
        ),
      );
      final batch = pullBatch(
        [task('a'), task('b'), committed],
        idSet(['a']),
        [inflight],
      );
      expect(batch.map((t) => t.id).toList(), ['b']);
    });

    test('pull_batch skips an in-flight orphan edited during the window', () {
      // #122 at the pull layer: the local row drifted, but the base still
      // matches the committed orphan, so the pull leaves it for recovery.
      final committed = task('server-id').copyWith(title: 'buy milk');
      const inflight = InflightBase(
        base: BaseSnapshot(title: 'buy milk', status: TaskStatus.needsAction),
      );
      final batch = pullBatch([committed], <String>{}, [inflight]);
      expect(batch, isEmpty, reason: 'the committed orphan is not pulled');
    });

    test('pull_batch skips a completed subtask orphan under a completed '
        'parent', () {
      // RFC-009 §G at the pull layer: the committed child was stored completed
      // by the cascade, but the parent-completed tolerance still recognizes it.
      final parent = task(
        'remote-parent',
      ).copyWith(status: TaskStatus.completed);
      final child = task('remote-child').copyWith(
        title: 'sub',
        parent: 'remote-parent',
        status: TaskStatus.completed,
      );
      const inflight = InflightBase(
        // Payload was open — the cascade completed it server-side.
        base: BaseSnapshot(title: 'sub', status: TaskStatus.needsAction),
        parent: 'remote-parent',
      );
      final batch = pullBatch([parent, child], <String>{}, [inflight]);
      expect(batch.map((t) => t.id).toList(), [
        'remote-parent',
      ], reason: 'only the parent is pulled');
    });

    test('pull_batch orders parents before children at any depth', () {
      final child = task('c').copyWith(parent: 'b');
      final mid = task('b').copyWith(parent: 'a');
      final batch = pullBatch([child, mid, task('a')], <String>{}, []);
      expect(batch.map((t) => t.id).toList(), ['a', 'b', 'c']);
    });

    test('order_parents_first appends a cycle instead of dropping it', () {
      final a = task('a').copyWith(parent: 'b');
      final b = task('b').copyWith(parent: 'a');
      expect(
        orderParentsFirst([a, b]).length,
        2,
        reason: 'a cycle must not silently drop rows',
      );
    });

    test('pull_row skips only on a matching etag', () {
      final batchIds = idSet(['t1']);
      final known = <String>{};
      final ctx = PullRowContext(
        localEtags: {'t1': 'etag-t1'},
        batchIds: batchIds,
        knownLocal: known,
      );
      expect(planPullRow(task('t1'), ctx), PullRowAction.skip);

      final changed = task('t1').copyWith(etag: 'newer');
      expect(planPullRow(changed, ctx), PullRowAction.upsert);

      // A row whose local etag is NULL (e.g. web_view_link backfill) is never
      // skipped.
      final ctx2 = PullRowContext(
        localEtags: {'t1': null},
        batchIds: batchIds,
        knownLocal: known,
      );
      expect(planPullRow(task('t1'), ctx2), PullRowAction.upsert);
    });

    test('pull_row detaches a child whose parent is nowhere yet', () {
      final child = task('c').copyWith(parent: 'p');
      // Parent neither in the batch nor already local → detach so the FK holds.
      expect(
        planPullRow(
          child,
          PullRowContext(
            localEtags: const {},
            batchIds: idSet(['c']),
            knownLocal: <String>{},
          ),
        ),
        PullRowAction.upsertDetached,
      );
      // Parent in the same batch → plain upsert.
      expect(
        planPullRow(
          child,
          PullRowContext(
            localEtags: const {},
            batchIds: idSet(['c', 'p']),
            knownLocal: <String>{},
          ),
        ),
        PullRowAction.upsert,
      );
      // Parent already local (its row was skipped as dirty) → plain upsert.
      expect(
        planPullRow(
          child,
          PullRowContext(
            localEtags: const {},
            batchIds: idSet(['c']),
            knownLocal: idSet(['p']),
          ),
        ),
        PullRowAction.upsert,
      );
    });

    test('list pull preserves a locally renamed list', () {
      final local = StoredTaskList(
        list: list('r1', 'renamed here'),
        syncState: SyncState.dirty,
        localUpdated: 'u',
        pendingOp: 'update',
      );
      expect(
        planListPull(list('r1', 'server title'), [local]),
        const ListPullKeepLocal(),
      );
    });

    test('list pull adopts an unpushed local create by title', () {
      final orphan = StoredTaskList(
        list: const TaskList(id: 'local-uuid', title: 'Work', updated: 'u'),
        syncState: SyncState.dirty,
        localUpdated: 'u',
        pendingOp: 'create',
      );
      expect(
        planListPull(list('r2', 'Work'), [orphan]),
        const ListPullAdoptLocalCreate('local-uuid'),
      );
    });

    test('list pull adopts a remote rename even when the etag is unchanged', () {
      // §I / D6: a list rename resolves REMOTE-WINS, and a stale etag must not
      // freeze the local title out of the pull (P6 at list level). Tasks are
      // skipped on a matching etag; lists deliberately are NOT — the title is
      // compared, so a server rename lands even if etag and `updated` match.
      final storedRow = storedList(list('r1', 'Work'));
      final renamed = TaskList(
        id: 'r1',
        title: 'Career',
        etag: storedRow.list.etag,
        updated: storedRow.list.updated,
      );
      expect(
        planListPull(renamed, [storedRow]),
        const ListPullUpsert(changed: true),
        reason: 'the remote title wins; no conflicted copy exists for lists',
      );
    });

    test('list pull reports whether anything changed', () {
      final storedRow = storedList(list('r1', 'Work'));
      expect(
        planListPull(list('r1', 'Work'), [storedRow]),
        const ListPullUpsert(changed: false),
      );
      expect(
        planListPull(list('r1', 'Renamed remotely'), [storedRow]),
        const ListPullUpsert(changed: true),
      );
      expect(
        planListPull(list('r1', 'Work'), <StoredTaskList>[]),
        const ListPullUpsert(changed: true),
      );
      // A local-only list shadowing the same id still counts as a change.
      final localOnly = StoredTaskList(
        list: list('r1', 'Work'),
        syncState: SyncState.clean,
        localUpdated: 'u',
        localOnly: true,
      );
      expect(
        planListPull(list('r1', 'Work'), [localOnly]),
        const ListPullUpsert(changed: true),
      );
    });
  });

  group('§F/§G D7 third-level detection', () {
    /// A clean stored row [id] with parent [parent].
    StoredTask cleanChild(String id, String? parent) =>
        stored(childTask(id, parent));

    test('third_level_ids flags only the grandchild', () {
      // P (top) > T (subtask) > C (grandchild). Only C sits a third level deep.
      final rows = [
        cleanChild('P', null),
        cleanChild('T', 'P'),
        cleanChild('C', 'T'),
      ];
      expect(thirdLevelIds(rows), ['C']);
    });

    test('third_level_ids is empty for a legal one-level tree', () {
      final rows = [
        cleanChild('P', null),
        cleanChild('A', 'P'),
        cleanChild('B', 'P'),
      ];
      expect(thirdLevelIds(rows), isEmpty);
    });

    test('third_level_ids ignores a row whose parent is absent', () {
      // A detached child (parent not present) is not a grandchild.
      expect(thirdLevelIds([cleanChild('C', 'gone')]), isEmpty);
    });

    test('third_level_ids skips an optimistic demote of the middle row', () {
      // The false-positive guard: T looks like a subtask purely because of an
      // un-pushed optimistic demote, so its row is still DIRTY. Its parent link
      // is not server-confirmed, so C must NOT be treated as a real third level.
      final t = StoredTask(
        task: childTask('T', 'P'),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
      );
      final rows = [cleanChild('P', null), t, cleanChild('C', 'T')];
      expect(thirdLevelIds(rows), isEmpty);
    });

    test('third_level_ids flags a still-queued subtask create under a clean '
        'subtask', () {
      // §G before the create pushes: C is a queued subtask create (no etag)
      // whose parent T is a clean, server-confirmed subtask. It IS a third
      // level — the leaf's state only changes HOW it is promoted.
      final c = StoredTask(
        task: Task(
          id: 'C',
          parent: 'T',
          position: '00000000000000000000',
          title: 'task C',
          status: TaskStatus.needsAction,
          updated: 'u',
        ),
        listId: 'L',
        syncState: SyncState.dirty,
        localUpdated: 'u',
        pendingOp: 'create',
      );
      final rows = [cleanChild('P', null), cleanChild('T', 'P'), c];
      expect(thirdLevelIds(rows), ['C']);
    });

    test('third_level_ids flags every clean row below the first level', () {
      // A pathological four-deep chain P > T > C > D, all clean. Both C and D
      // have a parent that is itself a subtask, so both are flagged.
      final rows = [
        cleanChild('P', null),
        cleanChild('T', 'P'),
        cleanChild('C', 'T'),
        cleanChild('D', 'C'),
      ];
      expect(thirdLevelIds(rows)..sort(), ['C', 'D']);
    });
  });
}
