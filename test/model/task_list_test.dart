// Unit layer — TaskList wire contract (part of model.rs's 1:1 port).
//
// Protects: a task list serializes with a null etag skipped (local-only rows
// carry no etag), and a wire list with a missing `updated` degrades to the
// empty string rather than throwing — the parity the reference `TaskListWire`
// conversion guarantees.

import 'package:axiotask/src/model/task_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serializes id/title/updated and skips a null etag', () {
    const l = TaskList(
      id: 'L1',
      title: 'Work',
      updated: '2026-05-23T00:00:00Z',
    );
    final m = l.toJson();
    expect(m['id'], 'L1');
    expect(m['title'], 'Work');
    expect(m['updated'], '2026-05-23T00:00:00Z');
    expect(m.containsKey('etag'), isFalse);
  });

  test('includes etag when present', () {
    const l = TaskList(
      id: 'L1',
      title: 'Work',
      etag: 'e1',
      updated: '2026-05-23T00:00:00Z',
    );
    expect(l.toJson()['etag'], 'e1');
  });

  test('fromJson maps fields; missing updated becomes empty string', () {
    final l = TaskList.fromJson({'id': 'L1', 'title': 'Work'});
    expect(l.id, 'L1');
    expect(l.title, 'Work');
    expect(l.updated, '');
    expect(l.etag, isNull);
  });

  test('compares by value', () {
    const a = TaskList(id: 'L1', title: 'Work', updated: 'u');
    const b = TaskList(id: 'L1', title: 'Work', updated: 'u');
    const c = TaskList(id: 'L1', title: 'Home', updated: 'u');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
