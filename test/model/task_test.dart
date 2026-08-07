// Unit layer — the enumerated `model.rs` tests ported 1:1.
//
// Protects the wire contract shared by the API and store: status round-trips
// through Google's exact strings, a sparse patch knows when it is empty, and a
// task (de)serializes with Google's field names — camelCase status, `webViewLink`
// rename, and skipped-when-absent optionals. If any of these drift, every
// synced task silently mis-serializes and the server rejects or mis-stores it.

import 'dart:convert';

import 'package:axiotask/src/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskStatus wire strings', () {
    // model.rs: task_status_round_trips_through_api_strings
    test('round-trips through api strings; unknown is rejected', () {
      expect(
        TaskStatus.parseApi(TaskStatus.needsAction.apiStr),
        TaskStatus.needsAction,
      );
      expect(
        TaskStatus.parseApi(TaskStatus.completed.apiStr),
        TaskStatus.completed,
      );
      expect(TaskStatus.needsAction.apiStr, 'needsAction');
      expect(TaskStatus.completed.apiStr, 'completed');
      // Non-happy path: an unknown wire value does not silently pick a status.
      expect(TaskStatus.parseApi('nonsense'), isNull);
    });
  });

  group('TaskPatch.isEmpty', () {
    // model.rs: empty_patch_is_detected_as_empty
    test('true only for the default (all-null) patch', () {
      expect(const TaskPatch().isEmpty, isTrue);
      expect(const TaskPatch(title: 'x').isEmpty, isFalse);
      expect(const TaskPatch(notes: '').isEmpty, isFalse);
      expect(const TaskPatch(due: '').isEmpty, isFalse);
      expect(const TaskPatch(status: TaskStatus.completed).isEmpty, isFalse);
    });
  });

  group('Task serialization', () {
    // model.rs: task_serializes_with_camel_case_status
    test('camelCase status; None parent skipped', () {
      const t = Task(
        id: '1',
        position: '00000000000001',
        title: 'Buy milk',
        status: TaskStatus.needsAction,
        updated: '2026-05-23T00:00:00Z',
      );
      final json = jsonEncode(t.toJson());
      expect(json, contains('"status":"needsAction"'));
      expect(
        json,
        isNot(contains('"parent"')),
        reason: 'parent should be skipped when null',
      );
      // A false `deleted` is skipped exactly as serde skips it.
      expect(json, isNot(contains('"deleted"')));
    });

    // model.rs: task_deserializes_web_view_link_from_google_field
    test('deserializes webViewLink from Google field; absent → null', () {
      final t = Task.fromJson(
        jsonDecode('''{
          "id": "abc",
          "title": "Monthly update",
          "status": "needsAction",
          "position": "0001",
          "updated": "2026-05-31T00:00:00Z",
          "webViewLink": "https://tasks.google.com/task/xyz"
        }''')
            as Map<String, Object?>,
      );
      expect(t.webViewLink, 'https://tasks.google.com/task/xyz');

      final t2 = Task.fromJson(
        jsonDecode(
              '{"id":"a","title":"t","status":"needsAction","position":"1","updated":"x"}',
            )
            as Map<String, Object?>,
      );
      expect(t2.webViewLink, isNull);
    });

    test('a soft-delete tombstone round-trips through JSON when true', () {
      // `deleted` is meaningful on a by-id refetch; when the wire says true it
      // must survive the round-trip (powers P4 delete-wins).
      final t = Task.fromJson(
        jsonDecode(
              '{"id":"a","title":"t","status":"needsAction","position":"1","updated":"x","deleted":true}',
            )
            as Map<String, Object?>,
      );
      expect(t.deleted, isTrue);
      expect(jsonEncode(t.toJson()), contains('"deleted":true'));
    });

    test('full task round-trips through JSON preserving every field', () {
      const t = Task(
        id: '1',
        parent: 'p',
        position: '09',
        title: 'Buy milk',
        notes: 'skim',
        status: TaskStatus.completed,
        due: '2026-05-23T00:00:00.000Z',
        completed: '2026-05-24T10:00:00.000Z',
        etag: 'etag123',
        updated: '2026-05-23T00:00:00Z',
        webViewLink: 'https://tasks.google.com/task/xyz',
      );
      final round = Task.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, Object?>,
      );
      expect(round, t);
    });
  });

  group('value equality', () {
    test('Task == compares by value, differs on any field', () {
      const a = Task(
        id: '1',
        position: '1',
        title: 'x',
        status: TaskStatus.needsAction,
        updated: 'u',
      );
      const b = Task(
        id: '1',
        position: '1',
        title: 'x',
        status: TaskStatus.needsAction,
        updated: 'u',
      );
      const c = Task(
        id: '1',
        position: '1',
        title: 'y',
        status: TaskStatus.needsAction,
        updated: 'u',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('TaskPatch and NewTask compare by value', () {
      expect(const TaskPatch(title: 'x'), const TaskPatch(title: 'x'));
      expect(const TaskPatch(title: 'x'), isNot(const TaskPatch(title: 'y')));
      expect(
        const NewTask(title: 'x', due: 'd'),
        const NewTask(title: 'x', due: 'd'),
      );
      expect(
        const NewTask(title: 'x'),
        isNot(const NewTask(title: 'x', due: 'd')),
      );
    });
  });

  group('NewTask / TaskPatch serialization', () {
    test(
      'NewTask skips unset optionals and serializes status as wire string',
      () {
        const n = NewTask(
          title: 'T',
          status: TaskStatus.completed,
          parent: 'p',
        );
        final m = n.toJson();
        expect(m['title'], 'T');
        expect(m['status'], 'completed');
        expect(m['parent'], 'p');
        expect(m.containsKey('notes'), isFalse);
        expect(m.containsKey('due'), isFalse);
        expect(m.containsKey('previous'), isFalse);
      },
    );

    test('TaskPatch sends only set fields; empty string clears', () {
      const p = TaskPatch(notes: '', status: TaskStatus.needsAction);
      final m = p.toJson();
      expect(m['notes'], '');
      expect(m['status'], 'needsAction');
      expect(m.containsKey('title'), isFalse);
      expect(m.containsKey('due'), isFalse);
    });
  });
}
