// Port of `api/in_memory.rs`'s in-file `mod tests`, PART 2 (T3.3): positioning
// & ordering, `move` (parent/position/cycle/unknown-id/completed-parent
// cascade), real pagination, and the full fault-injection surface — untargeted
// FIFO faults, per-id and per-page targeted faults, `commit_then_fail`
// lost-response faults, the `on_call` interleave hook, `clear_faults`, and call
// counting. Together with PART 1 (T3.2) this covers the entire `in_memory.rs`
// inventory.
//
// Each test pins a server behavior verified against the LIVE Google Tasks API
// (RFC-009). The fake mirrors that strictness on purpose: a permissive fake
// lets the whole sync suite pass while production sync is broken. Never loosen
// it to make a test go green.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('positioning & ordering', () {
    test('list_tasks returns position order, not insertion order', () async {
      // Seed out of position order; list_tasks must sort by the opaque
      // lexicographic position string the live API sorts by.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T-c', 'third', '00000000000003');
      c.seedTask('L1', 'T-a', 'first', '00000000000001');
      c.seedTask('L1', 'T-b', 'second', '00000000000002');
      final ids = (await c.listTasks('L1')).items.map((t) => t.id).toList();
      expect(ids, ['T-a', 'T-b', 'T-c']);
    });
  });

  group('move', () {
    test('move updates parent and position (top slot)', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'parent', '00000000000001');
      c.seedTask('L1', 'T2', 'child', '00000000000002');
      final moved = await c.moveTask('L1', 'T2', parent: 'T1');
      expect(moved.parent, 'T1');
      // No `previous` → placed at the top of its siblings; `'!'` sorts below
      // every digit-led seeded position.
      expect(
        moved.position.compareTo('00000000000001') < 0,
        isTrue,
        reason: 'top slot sorts before existing positions: ${moved.position}',
      );
    });

    test('move with a previous sets a between-siblings position', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'first', '00000000000001');
      c.seedTask('L1', 'T2', 'second', '00000000000002');
      final moved = await c.moveTask('L1', 'T2', previous: 'T1');
      // Placed immediately after T1: sorts after T1, before T2's original slot.
      expect(moved.position.compareTo('00000000000001') > 0, isTrue);
      expect(moved.position.compareTo('00000000000002') < 0, isTrue);
      expect(moved.parent, isNull);
    });

    test('move with an unknown previous sibling is NotFound', () async {
      // Live-API behavior (RFC-009 probe 2): a move naming a `previous` that no
      // longer exists answers 404 — NOT the 400 an unknown SUBJECT id draws.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'only', '00000000000001');
      final err = await _caught(
        () => c.moveTask('L1', 'T1', previous: 'ghost'),
      );
      expect(err, isA<NotFound>());
      expect((err as ApiError).isTransient, isFalse);
    });

    test('move rejects an unknown parent and leaves the task put', () async {
      // The same strictness `insert_task` applies to the same field. Without it
      // the fake can hold a task whose parent it does not have — a state Google
      // cannot be in, one our pull re-detaches on every run (#113).
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'child', '00000000000001');
      final err = await _caught(() => c.moveTask('L1', 'T1', parent: 'gone'));
      expect((err as ApiError).isTransient, isFalse);
      final after = (await c.listTasks('L1')).items;
      expect(
        after.single.parent,
        isNull,
        reason: 'the rejected move left the task where it was',
      );
    });

    test('move rejects a cycle (self-parent and deeper) and does not '
        'mutate the tree', () async {
      // A task cannot become its own descendant (Google's forest model, #155).
      // Reparenting T1 under its own child T2 would form T1→T2→T1 — a state
      // Google never holds and one our pull cannot topologically order. A
      // permanent 400; the tree is left exactly as it was.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'parent', '00000000000001');
      c.seedTask('L1', 'T2', 'child', '00000000000002');
      await c.moveTask('L1', 'T2', parent: 'T1'); // T2 under T1

      final cycleErr = await _caught(
        () => c.moveTask('L1', 'T1', parent: 'T2'),
      );
      expect((cycleErr as ApiError).isTransient, isFalse);

      // Direct self-parent is rejected the same way.
      final selfErr = await _caught(() => c.moveTask('L1', 'T1', parent: 'T1'));
      expect((selfErr as ApiError).isTransient, isFalse);

      // Nothing moved: T1 stayed top-level, T2 stayed under T1.
      final after = (await c.listTasks('L1')).items;
      expect(after.firstWhere((t) => t.id == 'T1').parent, isNull);
      expect(after.firstWhere((t) => t.id == 'T2').parent, 'T1');
    });

    test('move bumps the task etag', () async {
      // RFC-009 probe 1: a move DOES issue a fresh etag, so a concurrent local
      // content edit 412s on a row whose content never changed.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final anchor = c.seedTask('L1', 'A', 'anchor', '00000000000001');
      final subject = c.seedTask('L1', 'B', 'subject', '00000000000002');
      final moved = await c.moveTask('L1', subject.id, previous: anchor.id);
      expect(moved.etag, isNotNull);
      expect(
        moved.etag,
        isNot(subject.etag),
        reason: 'a move must issue a fresh etag, like the live API',
      );
    });

    test('move creating a third level is accepted (no depth cap)', () async {
      // RFC-009 probe 3: the API does NOT cap nesting depth. Our app self-limits
      // to one level; the SERVER does not enforce it, so the fake must not
      // either or the engine is tested against a fiction.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'L1T', 'level-1', '00000000000001');
      c.seedTaskWithParent('L1', 'L2T', 'level-2', '00000000000002', 'L1T');
      c.seedTask('L1', 'X', 'to-demote', '00000000000003');
      final moved = await c.moveTask('L1', 'X', parent: 'L2T');
      expect(moved.parent, 'L2T');
    });

    test('moving an open task under a completed parent completes it', () async {
      // RFC-009 probe 4: the move is accepted (200) and the parent's completion
      // cascade takes the newly attached child — the move RESPONSE already
      // shows it completed.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final p = c.seedTask('L1', 'P', 'done-parent', '00000000000001');
      await c.patchTask(
        'L1',
        'P',
        const TaskPatch(status: TaskStatus.completed),
        etag: p.etag,
      );
      c.seedTask('L1', 'X', 'open-task', '00000000000002');

      final moved = await c.moveTask('L1', 'X', parent: 'P');
      expect(moved.parent, 'P');
      expect(
        moved.status,
        TaskStatus.completed,
        reason: 'the move response already shows the cascaded completion',
      );
      final refetched = await c.getTask('L1', 'X');
      expect(refetched.status, TaskStatus.completed);
      expect(refetched.completed, isNotNull);
    });

    test('moving a task under an open parent leaves it open', () async {
      // The non-happy-path guard for the row above: the cascade must key off the
      // DESTINATION parent's status, not fire on every reparent.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'P', 'open-parent', '00000000000001');
      c.seedTask('L1', 'X', 'open-task', '00000000000002');
      final moved = await c.moveTask('L1', 'X', parent: 'P');
      expect(moved.status, TaskStatus.needsAction);
      expect(moved.completed, isNull);
    });

    test('move of an unknown id is a permanent 400 (not 404)', () async {
      // Live-API behavior: moving an unknown id is 400 "Invalid task ID" — the
      // asymmetry with an unknown `previous` (which is a 404) is verified live.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final err = await _caught(() => c.moveTask('L1', 'nope'));
      expect(err, isA<OtherApiError>());
      expect((err as ApiError).isTransient, isFalse);
    });

    test('move to a nonexistent list is NotFound', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'x', '00000000000001');
      await expectLater(c.moveTask('no-list', 'T1'), throwsA(isA<NotFound>()));
    });

    test('move reorders the task in the subsequent list_tasks', () async {
      // A real lexicographic move must change where the task appears on the NEXT
      // list_tasks, not just stamp an opaque field.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'A', 'a', '00000000000001');
      c.seedTask('L1', 'B', 'b', '00000000000002');
      c.seedTask('L1', 'C', 'c', '00000000000003');
      // Move C to sit right after A → order becomes A, C, B.
      await c.moveTask('L1', 'C', previous: 'A');
      final ids = (await c.listTasks('L1')).items.map((t) => t.id).toList();
      expect(ids, ['A', 'C', 'B']);
    });
  });

  group('pagination', () {
    test('list_tasks paginates with real tokens that concatenate to the '
        'full list', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      for (var i = 1; i <= 5; i++) {
        c.seedTask('L1', 'T$i', 't', i.toString().padLeft(14, '0'));
      }
      c.setPageSize(2);

      final p0 = await c.listTasks('L1');
      expect(p0.items, hasLength(2));
      final tok0 = p0.nextPageToken;
      expect(tok0, isNotNull, reason: 'more pages after page 0');

      final p1 = await c.listTasks('L1', pageToken: tok0);
      expect(p1.items, hasLength(2));
      final tok1 = p1.nextPageToken;
      expect(tok1, isNotNull, reason: 'more pages after page 1');

      final p2 = await c.listTasks('L1', pageToken: tok1);
      expect(p2.items, hasLength(1));
      expect(p2.nextPageToken, isNull, reason: 'last page has no token');

      // Pages concatenate to the full list, in position order, no dupes.
      final ids = [
        ...p0.items,
        ...p1.items,
        ...p2.items,
      ].map((t) => t.id).toList();
      expect(ids, ['T1', 'T2', 'T3', 'T4', 'T5']);
      expect(ids.toSet(), hasLength(5), reason: 'no task appears on two pages');
    });

    test('an unparseable page token is a permanent 400', () async {
      // The tokens are our own opaque `page-N`; anything else is a client bug
      // the live API would reject with a 400.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 't', '00000000000001');
      final err = await _caught(() => c.listTasks('L1', pageToken: 'garbage'));
      expect(err, isA<OtherApiError>());
      expect((err as ApiError).isTransient, isFalse);
    });
  });

  group('fault injection', () {
    test('fail_next injects exactly one error, then recovers', () async {
      final c = FakeTasksApi();
      c.failNext(Method.listTasklists, () => const ServerError(503));
      final err = await _caught(() => c.listTasklists());
      expect(err, const ServerError(503));
      // The second call succeeds — the fault fired once and was consumed.
      expect(await c.listTasklists(), isEmpty);
    });

    test(
      'fail_next is FIFO per method and only fires for its own method',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        // Arm two list_tasks faults; an unrelated method is untouched.
        c.failNext(Method.listTasks, () => const ServerError(500));
        c.failNext(Method.listTasks, () => const ServerError(503));
        expect(
          await c.listTasklists(),
          hasLength(1),
          reason: 'other method ok',
        );

        final first = await _caught(() => c.listTasks('L1'));
        expect(
          first,
          const ServerError(500),
          reason: 'FIFO: first armed first',
        );
        final second = await _caught(() => c.listTasks('L1'));
        expect(second, const ServerError(503));
        expect(
          (await c.listTasks('L1')).items,
          isEmpty,
          reason: 'queue drained',
        );
      },
    );

    test('call_count tracks each method independently', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      await c.listTasklists();
      await c.listTasklists();
      expect(c.callCount(Method.listTasklists), 2);
      expect(c.callCount(Method.insertTask), 0);
      // A faulted call still counts as an invocation.
      c.failNext(Method.listTasklists, () => const ServerError(503));
      await _caught(() => c.listTasklists());
      expect(c.callCount(Method.listTasklists), 3);
    });

    test(
      'fail_next_for_id targets only that task, order-independent',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'T1', 'one', '00000000000001');
        c.seedTask('L1', 'T2', 'two', '00000000000002');
        // Arm a fault for patching T2; patching T1 first must pass through.
        c.failNextForId(Method.patchTask, 'T2', () => const ServerError(500));

        final ok = await c.patchTask(
          'L1',
          'T1',
          const TaskPatch(title: 'edited'),
        );
        expect(
          ok.title,
          'edited',
          reason: 'unrelated task unaffected by the id fault',
        );

        final err = await _caught(
          () => c.patchTask('L1', 'T2', const TaskPatch(title: 'edited')),
        );
        expect(err, const ServerError(500));
        // Consumed on fire: the next patch of T2 succeeds.
        final again = await c.patchTask(
          'L1',
          'T2',
          const TaskPatch(title: 'again'),
        );
        expect(again.title, 'again');
      },
    );

    test('fail_list_tasks_page targets one page only', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      for (var i = 1; i <= 4; i++) {
        c.seedTask('L1', 'T$i', 't', i.toString().padLeft(14, '0'));
      }
      c.setPageSize(2);
      // Drop the network on the SECOND page (index 1); page 0 must still load.
      c.failListTasksPage(1, () => const ServerError(503));

      final p0 = await c.listTasks('L1');
      final tok0 = p0.nextPageToken;
      final err = await _caught(() => c.listTasks('L1', pageToken: tok0));
      expect(err, const ServerError(503));
      // The fault is consumed: a retry of page 1 now succeeds.
      final retry = await c.listTasks('L1', pageToken: tok0);
      expect(retry.items, hasLength(2));
    });

    test(
      'clear_faults disarms untargeted, targeted, and commit-then-fail',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'T1', 'one', '00000000000001');
        c.failNext(Method.listTasklists, () => const ServerError(503));
        c.failNextForId(Method.patchTask, 'T1', () => const ServerError(500));
        c.commitThenFailNext(Method.deleteTask);

        c.clearFaults();

        // Every armed fault is gone: all three calls now succeed cleanly.
        expect(await c.listTasklists(), hasLength(1));
        final patched = await c.patchTask(
          'L1',
          'T1',
          const TaskPatch(title: 'ok'),
        );
        expect(patched.title, 'ok');
        await c.deleteTask(
          'L1',
          'T1',
        ); // no thrown Network from commit-then-fail
        expect((await c.listTasks('L1')).items, isEmpty);
      },
    );
  });

  group('commit-then-fail lost responses', () {
    test('an insert commits server-side, then the response is lost', () async {
      // The at-least-once hazard: the row IS created, but the caller sees a
      // Network error. A re-list proves the mutation landed.
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.commitThenFailNext(Method.insertTask);
      final err = await _caught(
        () => c.insertTask('L1', const NewTask(title: 'ghost-create')),
      );
      expect(err, isA<Network>());
      final items = (await c.listTasks('L1')).items;
      expect(
        items.map((t) => t.title),
        ['ghost-create'],
        reason: 'the insert committed before its response was dropped',
      );
    });

    test('commit_then_fail_next_insert is the insert-only shorthand', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.commitThenFailNextInsert();
      final err = await _caught(
        () => c.insertTask('L1', const NewTask(title: 'x')),
      );
      expect(err, isA<Network>());
      expect((await c.listTasks('L1')).items, hasLength(1));
    });

    test(
      'a patch commits (new content + etag), then the response is lost',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        final t = c.seedTask('L1', 'T1', 'orig', '00000000000001');
        c.commitThenFailNext(Method.patchTask);
        final err = await _caught(
          () => c.patchTask(
            'L1',
            'T1',
            const TaskPatch(title: 'edited'),
            etag: t.etag,
          ),
        );
        expect(err, isA<Network>());
        final stored = await c.getTask('L1', 'T1');
        expect(
          stored.title,
          'edited',
          reason: 'the edit committed before the drop',
        );
        expect(
          stored.etag,
          isNot(t.etag),
          reason: 'the etag advanced server-side',
        );
      },
    );

    test('a delete commits (row gone), then the response is lost', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'x', '00000000000001');
      c.commitThenFailNext(Method.deleteTask);
      final err = await _caught(() => c.deleteTask('L1', 'T1'));
      expect(err, isA<Network>());
      expect(
        (await c.listTasks('L1')).items,
        isEmpty,
        reason: 'the soft-delete committed before its response was dropped',
      );
    });
  });

  group('on_call interleave hook', () {
    test('the hook fires once per trait call, in order', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final seen = <Method>[];
      c.setOnCall((client, m) => seen.add(m));
      await c.listTasklists();
      await c.insertTask('L1', const NewTask(title: 'x'));
      expect(seen, [Method.listTasklists, Method.insertTask]);
    });

    test('clear_on_call stops further firing', () async {
      final c = FakeTasksApi();
      final seen = <Method>[];
      c.setOnCall((client, m) => seen.add(m));
      await c.listTasklists();
      c.clearOnCall();
      await c.listTasklists();
      expect(seen, [Method.listTasklists], reason: 'only the first call fired');
    });

    test(
      'the hook interleaves another device mutation before the call runs',
      () async {
        // The reason on_call exists: interleave a server-side change at a precise
        // point INSIDE a run. Here another device inserts a task the instant
        // before our list_tasks — it must be visible on that very list.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'T1', 'one', '00000000000001');
        var done = false;
        c.setOnCall((client, m) {
          if (m == Method.listTasks && !done) {
            done = true;
            client.seedTaskIfListExists(
              'L1',
              'T2',
              'raced-in',
              '00000000000002',
            );
          }
        });
        final ids = (await c.listTasks('L1')).items.map((t) => t.id).toList();
        expect(ids, [
          'T1',
          'T2',
        ], reason: 'the raced-in task is visible on this very list');
      },
    );

    test(
      'a re-entrant client call from inside the hook does not re-fire it',
      () async {
        // The hook is taken out of its slot while running, so a trait call it
        // makes does not recurse. Guard against an infinite loop / double-fire.
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        var fires = 0;
        c.setOnCall((client, m) {
          fires += 1;
          // Re-enter with a trait call; it must NOT re-fire the hook.
          client.callCount(Method.listTasks); // read-only, no fire
          client.seedTaskIfListExists('L1', 'X', 'x', '00000000000009');
        });
        await c.listTasks('L1');
        expect(
          fires,
          1,
          reason: 'the hook fired exactly once for one outer call',
        );
      },
    );
  });

  group('server-side state helpers (drive races without a call or fault)', () {
    test(
      'delete_task_from_state soft-deletes without recording a call',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'T1', 'x', '00000000000001');
        c.deleteTaskFromState('L1', 'T1');
        expect((await c.listTasks('L1')).items, isEmpty);
        // Still soft-deleted (gettable), and no DeleteTask call was recorded.
        expect((await c.getTask('L1', 'T1')).deleted, isTrue);
        expect(c.callCount(Method.deleteTask), 0);
      },
    );

    test(
      'seed_task_if_list_exists adds to a live list, no-ops on a missing one',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTaskIfListExists('L1', 'T1', 'added', '00000000000001');
        c.seedTaskIfListExists('gone', 'T2', 'dropped', '00000000000002');
        final ids = (await c.listTasks('L1')).items.map((t) => t.id).toList();
        expect(ids, ['T1'], reason: 'the missing-list insert was a safe no-op');
      },
    );

    test('delete_list_from_state removes the list and its tasks', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'x', '00000000000001');
      c.deleteListFromState('L1');
      expect(await c.listTasklists(), isEmpty);
      // A subsequent op on the vanished list is a NotFound.
      await expectLater(
        c.insertTask('L1', const NewTask(title: 'y')),
        throwsA(isA<NotFound>()),
      );
    });
  });
}

/// Run [action] and return whatever [ApiError] it throws, or `null` on success —
/// used where a test needs the error VALUE (to assert equality / `isTransient`),
/// not just its type.
Future<Object?> _caught(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } on ApiError catch (e) {
    return e;
  }
}
