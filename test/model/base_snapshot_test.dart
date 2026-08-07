// Unit layer — BaseSnapshot captures exactly the user-content fields.
//
// Protects RFC-009 §B/§G: the base holds title/notes/due/status and NOTHING
// structural (position, parent, etag). If a structural field leaked in, the
// reconciler's "only WE changed the content" test (#118 bare-reorder etag bump)
// would misfire and manufacture spurious conflicted copies.

import 'package:axiotask/src/model/base_snapshot.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BaseSnapshot.of snapshots only the content fields', () {
    const t = Task(
      id: '1',
      parent: 'p',
      position: '09',
      title: 'Buy milk',
      notes: 'skim',
      status: TaskStatus.completed,
      due: '2026-05-23T00:00:00.000Z',
      etag: 'etag123',
      updated: 'u',
    );
    final base = BaseSnapshot.of(t);
    expect(base.title, 'Buy milk');
    expect(base.notes, 'skim');
    expect(base.due, '2026-05-23T00:00:00.000Z');
    expect(base.status, TaskStatus.completed);
  });

  test('a bare reorder (same content, different position) has an equal base', () {
    // The load-bearing case: position/etag change, content does not → the two
    // snapshots must be equal so the reconciler treats it as a local-only edit.
    const before = Task(
      id: '1',
      position: '01',
      title: 'T',
      status: TaskStatus.needsAction,
      etag: 'e1',
      updated: 'u',
    );
    const afterReorder = Task(
      id: '1',
      position: '99',
      title: 'T',
      status: TaskStatus.needsAction,
      etag: 'e2',
      updated: 'u2',
    );
    expect(BaseSnapshot.of(before), BaseSnapshot.of(afterReorder));
    expect(
      BaseSnapshot.of(before).hashCode,
      BaseSnapshot.of(afterReorder).hashCode,
    );
  });

  test('a content edit produces an unequal base', () {
    const before = Task(
      id: '1',
      position: '01',
      title: 'T',
      status: TaskStatus.needsAction,
      updated: 'u',
    );
    const afterEdit = Task(
      id: '1',
      position: '01',
      title: 'T edited',
      status: TaskStatus.needsAction,
      updated: 'u',
    );
    expect(BaseSnapshot.of(before), isNot(BaseSnapshot.of(afterEdit)));
  });
}
