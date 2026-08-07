// Unit layer — the enumerated `taskTree.test.js` cases ported 1:1.
//
// Protects invariant #1 (strict two levels). Every mutation path routes through
// these predicates; if canNestUnder/canAddSubtask drifted, a subtask could gain
// a subtask (a third level) — the exact corruption the invariant forbids.

import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_tree.dart';
import 'package:flutter_test/flutter_test.dart';

Task t(String id, {String? parent}) => Task(
  id: id,
  parent: parent,
  position: '1',
  title: id,
  status: TaskStatus.needsAction,
  updated: 'u',
);

void main() {
  final parent = t('p');
  final otherParent = t('p2');
  final sub = t('s', parent: 'p');
  final childless = t('c');
  final tasks = [parent, otherParent, sub, childless];

  group('isSubtask', () {
    test('only tasks with a parent are subtasks', () {
      expect(isSubtask(parent), isFalse);
      expect(isSubtask(sub), isTrue);
      expect(isSubtask(null), isFalse);
    });
  });

  group('hasSubtasks', () {
    test('true only when some task points at the id', () {
      expect(hasSubtasks('p', tasks), isTrue);
      expect(hasSubtasks('c', tasks), isFalse);
      expect(hasSubtasks('s', tasks), isFalse);
    });
  });

  group('canAddSubtask — a subtask cannot gain a subtask', () {
    test('allows adding under a top-level task', () {
      expect(canAddSubtask(parent), isTrue);
      expect(canAddSubtask(childless), isTrue);
    });
    test('refuses adding under a subtask (would be a 3rd level)', () {
      expect(canAddSubtask(sub), isFalse);
    });
    test('refuses when the parent is missing', () {
      expect(canAddSubtask(null), isFalse);
    });
  });

  group('canNestUnder — a task with subtasks cannot become a subtask', () {
    test(
      'allows nesting a childless top-level task under another top-level',
      () {
        expect(canNestUnder('c', parent, tasks), isTrue);
      },
    );
    test('refuses nesting a task that already has subtasks', () {
      expect(canNestUnder('p', otherParent, tasks), isFalse);
    });
    test('refuses nesting under a subtask (would be a 3rd level)', () {
      expect(canNestUnder('c', sub, tasks), isFalse);
    });
    test('refuses nesting under a missing parent', () {
      expect(canNestUnder('c', null, tasks), isFalse);
    });
    test('refuses nesting a task under itself', () {
      expect(canNestUnder('p', parent, tasks), isFalse);
    });
  });
}
