// The fake's LIST SCOPING and mutation-stamp strictness (#269).
//
// Every task endpoint on the live API is addressed as
// `/lists/{tasklist}/tasks/{task}` — the pair, not the id alone. The fake used
// to resolve the task id and ignore the list, so a cross-list id (the #224 bug
// class) sailed through, an unknown list read back as an empty page rather than
// a 404, and `previous`/`parent` could name a row from another list or another
// parent entirely. A fake that lenient lets the sync suite go green while
// production sync is broken, so each of these is now a rejection.
//
// Also pinned here: a mutation moves the row's `updated` stamp. A frozen
// `updated` hides every "did the server really change this row?" question the
// engine and the dual-device convergence checks ask.
//
// NEVER loosen these to make another test pass — the fake mirrors the live API
// (RFC-009), and a test that goes red against it is a real defect.

import 'package:axiotask/src/api/api_error.dart';
import 'package:axiotask/src/api/fake_tasks_api.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two seeded lists, each holding one task.
FakeTasksApi twoLists() {
  final c = FakeTasksApi();
  c.seedList('L1', 'Inbox');
  c.seedList('L2', 'Work');
  c.seedTask('L1', 'T1', 'in L1', '00000000000001');
  c.seedTask('L2', 'T2', 'in L2', '00000000000001');
  return c;
}

void main() {
  group('an unknown list is a 404, never an empty answer', () {
    test('list_tasks of a list the server does not have', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      await expectLater(c.listTasks('gone'), throwsA(isA<NotFound>()));
    });

    test('list_tasks of a list DELETED mid-session', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'T1', 'a', '00000000000001');
      await c.deleteTasklist('L1');
      await expectLater(c.listTasks('L1'), throwsA(isA<NotFound>()));
    });

    test('a still-live list still answers', () async {
      final c = twoLists();
      expect((await c.listTasks('L1')).items.single.id, 'T1');
    });
  });

  group('a task id from another list is not addressable', () {
    test('get_task', () async {
      final c = twoLists();
      await expectLater(c.getTask('L1', 'T2'), throwsA(isA<NotFound>()));
      expect((await c.getTask('L2', 'T2')).title, 'in L2');
    });

    test('patch_task', () async {
      final c = twoLists();
      await expectLater(
        c.patchTask('L1', 'T2', const TaskPatch(title: 'hijacked')),
        throwsA(isA<NotFound>()),
      );
      expect(
        (await c.getTask('L2', 'T2')).title,
        'in L2',
        reason: 'and the row in the other list is untouched',
      );
    });

    test('delete_task', () async {
      final c = twoLists();
      await expectLater(c.deleteTask('L1', 'T2'), throwsA(isA<NotFound>()));
      expect((await c.listTasks('L2')).items.single.id, 'T2');
    });

    test('move_task — an unaddressable SUBJECT is the 400, as for an '
        'unknown id', () async {
      final c = twoLists();
      await expectLater(
        c.moveTask('L1', 'T2'),
        throwsA(isA<OtherApiError>()),
        reason: 'the verified asymmetry: unknown subject → 400, not 404',
      );
    });

    test('a soft-deleted row is only reachable through its OWN list', () async {
      final c = twoLists();
      await c.deleteTask('L2', 'T2');
      // Its own list still answers a direct get, flagged deleted…
      expect((await c.getTask('L2', 'T2')).deleted, isTrue);
      // …but the other list has never held it.
      await expectLater(c.getTask('L1', 'T2'), throwsA(isA<NotFound>()));
      await expectLater(
        c.patchTask('L1', 'T2', const TaskPatch(title: 'x')),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('previous and parent must be siblings in the same list', () {
    test('insert naming a parent from another list is rejected', () async {
      final c = twoLists();
      await expectLater(
        c.insertTask('L1', const NewTask(title: 'child', parent: 'T2')),
        throwsA(isA<OtherApiError>()),
      );
      expect((await c.listTasks('L1')).items, hasLength(1));
    });

    test('insert naming a previous from another list is a 404', () async {
      final c = twoLists();
      await expectLater(
        c.insertTask('L1', const NewTask(title: 'after', previous: 'T2')),
        throwsA(isA<NotFound>()),
      );
      expect((await c.listTasks('L1')).items, hasLength(1));
    });

    test(
      'insert naming a previous under a DIFFERENT parent is a 404',
      () async {
        final c = FakeTasksApi();
        c.seedList('L1', 'Inbox');
        c.seedTask('L1', 'P', 'parent', '00000000000001');
        c.seedTaskWithParent('L1', 'C', 'child', '00000000000002', 'P');
        // A top-level insert cannot follow a SUBTASK, and vice versa.
        await expectLater(
          c.insertTask('L1', const NewTask(title: 'top', previous: 'C')),
          throwsA(isA<NotFound>()),
        );
        await expectLater(
          c.insertTask(
            'L1',
            const NewTask(title: 'sub', parent: 'P', previous: 'P'),
          ),
          throwsA(isA<NotFound>()),
        );
        // The sibling case is accepted.
        final ok = await c.insertTask(
          'L1',
          const NewTask(title: 'sub2', parent: 'P', previous: 'C'),
        );
        expect(ok.parent, 'P');
        expect(ok.position.compareTo('00000000000002'), greaterThan(0));
      },
    );

    test('move naming a parent from another list is rejected', () async {
      final c = twoLists();
      await expectLater(
        c.moveTask('L1', 'T1', parent: 'T2'),
        throwsA(isA<OtherApiError>()),
      );
      expect((await c.getTask('L1', 'T1')).parent, isNull);
    });

    test('move naming a previous from another list is a 404', () async {
      final c = twoLists();
      await expectLater(
        c.moveTask('L1', 'T1', previous: 'T2'),
        throwsA(isA<NotFound>()),
      );
    });
  });

  group('a mutation moves the updated stamp', () {
    test('patch_task', () async {
      final c = twoLists();
      final before = await c.getTask('L1', 'T1');
      final after = await c.patchTask(
        'L1',
        'T1',
        const TaskPatch(title: 'renamed'),
      );
      expect(after.updated.compareTo(before.updated), greaterThan(0));
      expect((await c.getTask('L1', 'T1')).updated, after.updated);
    });

    test('move_task', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      c.seedTask('L1', 'A', 'a', '00000000000001');
      c.seedTask('L1', 'B', 'b', '00000000000002');
      final before = await c.getTask('L1', 'B');
      final after = await c.moveTask('L1', 'B');
      expect(after.updated.compareTo(before.updated), greaterThan(0));
    });

    test('the completion cascade stamps every descendant', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'Inbox');
      final p = c.seedTask('L1', 'P', 'parent', '00000000000001');
      c.seedTaskWithParent('L1', 'C', 'child', '00000000000002', 'P');
      await c.patchTask(
        'L1',
        'P',
        const TaskPatch(status: TaskStatus.completed),
      );
      final child = await c.getTask('L1', 'C');
      expect(child.status, TaskStatus.completed);
      expect(child.updated.compareTo(p.updated), greaterThan(0));
    });

    test('patch_tasklist', () async {
      final c = FakeTasksApi();
      final l = c.seedList('L1', 'Inbox');
      final renamed = await c.patchTasklist('L1', 'Errands');
      expect(renamed.updated.compareTo(l.updated), greaterThan(0));
    });
  });

  group('a list the account refuses to delete', () {
    test('delete_tasklist is permanently refused and the list survives with '
        'its tasks', () async {
      final c = FakeTasksApi();
      c.seedList('L1', 'My Tasks');
      c.seedTask('L1', 'T1', 'a', '00000000000001');
      c.setUndeletableList('L1');

      await expectLater(c.deleteTasklist('L1'), throwsA(isA<OtherApiError>()));
      expect((await c.listTasklists()).single.id, 'L1');
      expect((await c.listTasks('L1')).items.single.id, 'T1');
      // The refusal is permanent, not transient: the engine must not retry it
      // forever (it revives the list instead).
      await expectLater(
        c.deleteTasklist('L1'),
        throwsA(
          isA<OtherApiError>().having(
            (e) => e.isTransient,
            'isTransient',
            false,
          ),
        ),
      );
    });

    test('every other list still deletes', () async {
      final c = twoLists();
      c.setUndeletableList('L1');
      await c.deleteTasklist('L2');
      expect((await c.listTasklists()).single.id, 'L1');
    });
  });
}
