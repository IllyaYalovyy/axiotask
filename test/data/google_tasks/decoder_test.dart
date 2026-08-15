import 'dart:convert';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/google_tasks/decoder.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GoogleTasksDecoder', () {
    const decoder = GoogleTasksDecoder();

    test('decodes the supported task-list fields and ignores unknowns', () {
      final result = decoder.decodeTaskListPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#taskLists',
            'etag': 'collection-etag',
            'nextPageToken': 'page-2',
            'futureCollectionField': <String, Object>{'safe': true},
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#taskList',
                'id': 'list-1',
                'etag': 'list-etag',
                'title': 'Synthetic inbox',
                'updated': '2026-08-15T18:30:12.123Z',
                'selfLink':
                    'https://tasks.googleapis.com/tasks/v1/users/@me/lists/list-1',
                'futureResourceField': 42,
              },
            ],
          }),
        ),
      );

      expect(result, isA<Success<RemotePage<RemoteTaskList>>>());
      final page = (result as Success<RemotePage<RemoteTaskList>>).value;
      expect(page.collectionEtag, 'collection-etag');
      expect(page.nextPageToken, const PageToken('page-2'));
      expect(page.items, hasLength(1));
      expect(page.items.single.id, const RemoteTaskListId('list-1'));
      expect(page.items.single.etag, 'list-etag');
      expect(page.items.single.title, 'Synthetic inbox');
      expect(
        page.items.single.updated,
        DateTime.utc(2026, 8, 15, 18, 30, 12, 123),
      );
    });

    test('decodes live task metadata, UTC date, and optional fields', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'etag': 'task-collection-etag',
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#task',
                'id': 'task-1',
                'etag': 'task-etag',
                'title': 'Synthetic task',
                'updated': '2026-08-15T18:31:00Z',
                'selfLink':
                    'https://tasks.googleapis.com/tasks/v1/lists/list-1/tasks/task-1',
                'parent': 'parent-1',
                'position': '00000000000000000001',
                'notes': 'Synthetic notes',
                'status': 'completed',
                'due': '2026-08-16T00:00:00.000Z',
                'completed': '2026-08-15T18:31:01.456Z',
                'deleted': false,
                'hidden': true,
                'links': <Object>[
                  <String, Object>{
                    'type': 'email',
                    'description': 'Synthetic link',
                    'link': 'https://example.test/synthetic',
                  },
                ],
                'webViewLink': 'https://tasks.google.com/task/task-1',
                'futureResourceField': <String, Object>{},
              },
            ],
          }),
        ),
      );

      expect(result, isA<Success<RemotePage<RemoteTask>>>());
      final task =
          (result as Success<RemotePage<RemoteTask>>).value.items.single;
      expect(task, isA<RemoteLiveTask>());
      final live = task as RemoteLiveTask;
      expect(live.id, const RemoteTaskId('task-1'));
      expect(live.etag, 'task-etag');
      expect(live.parentId, const RemoteTaskId('parent-1'));
      expect(live.status, RemoteTaskStatus.completed);
      expect(live.due, const RemoteDate(2026, 8, 16));
      expect(live.hidden, isTrue);
      expect(live.links.single.type, 'email');
      expect(live.webViewLink, Uri.https('tasks.google.com', '/task/task-1'));
    });

    test(
      'decodes a sparse positive tombstone without inventing live fields',
      () {
        final result = decoder.decodeTaskPage(
          utf8.encode(
            jsonEncode(<String, Object>{
              'kind': 'tasks#tasks',
              'items': <Object>[
                <String, Object>{
                  'kind': 'tasks#task',
                  'id': 'deleted-task',
                  'deleted': true,
                },
              ],
            }),
          ),
        );

        expect(result, isA<Success<RemotePage<RemoteTask>>>());
        final task =
            (result as Success<RemotePage<RemoteTask>>).value.items.single;
        expect(task, isA<RemoteTaskTombstone>());
        final tombstone = task as RemoteTaskTombstone;
        expect(tombstone.id, const RemoteTaskId('deleted-task'));
        expect(tombstone.etag, isNull);
        expect(tombstone.updated, isNull);
        expect(tombstone.retainedTitle, isNull);
        expect(tombstone.retainedDue, isNull);
      },
    );

    test('preserves optional fields retained by a tombstone', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#task',
                'id': 'deleted-task',
                'etag': 'deleted-etag',
                'updated': '2026-08-15T18:31:00Z',
                'deleted': true,
                'title': 'Retained synthetic title',
                'notes': 'Retained synthetic notes',
                'position': '0001',
                'status': 'needsAction',
                'due': '2026-08-17T00:00:00.000Z',
              },
            ],
          }),
        ),
      );

      final tombstone =
          (result as Success<RemotePage<RemoteTask>>).value.items.single
              as RemoteTaskTombstone;
      expect(tombstone.retainedTitle, 'Retained synthetic title');
      expect(tombstone.retainedNotes, 'Retained synthetic notes');
      expect(tombstone.retainedStatus, RemoteTaskStatus.needsAction);
      expect(tombstone.retainedDue, const RemoteDate(2026, 8, 17));
    });

    test('allows omitted optional live fields without clearing inference', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#task',
                'id': 'task-1',
                'etag': 'task-etag',
                'title': 'Synthetic task',
                'updated': '2026-08-15T18:31:00Z',
                'position': '0001',
                'status': 'needsAction',
              },
            ],
          }),
        ),
      );

      final task =
          (result as Success<RemotePage<RemoteTask>>).value.items.single
              as RemoteLiveTask;
      expect(task.notes, isNull);
      expect(task.due, isNull);
      expect(task.completed, isNull);
      expect(task.webViewLink, isNull);
      expect(task.hidden, isFalse);
    });

    test('keeps absent version hints absent without inventing values', () {
      final listResult = decoder.decodeTaskListPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#taskLists',
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#taskList',
                'id': 'list-1',
                'title': 'Synthetic list',
              },
            ],
          }),
        ),
      );
      final taskResult = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                'kind': 'tasks#task',
                'id': 'task-1',
                'title': 'Synthetic task',
                'position': '0001',
                'status': 'needsAction',
              },
            ],
          }),
        ),
      );

      final list = (listResult as Success<RemotePage<RemoteTaskList>>)
          .value
          .items
          .single;
      final task =
          (taskResult as Success<RemotePage<RemoteTask>>).value.items.single;
      expect(list.etag, isNull);
      expect(list.updated, isNull);
      expect(task.etag, isNull);
      expect(task.updated, isNull);
    });

    for (final malformed in <Map<String, Object?>>[
      <String, Object?>{'kind': 'tasks#taskLists', 'items': 'not-a-list'},
      <String, Object?>{
        'kind': 'tasks#taskLists',
        'items': <Object?>[
          <String, Object?>{'kind': 'tasks#taskList'},
        ],
      },
      <String, Object?>{
        'kind': 'tasks#taskLists',
        'items': <Object?>[
          <String, Object?>{
            'kind': 'tasks#taskList',
            'id': 'list-1',
            'etag': 12,
            'title': 'Synthetic',
            'updated': '2026-08-15T18:30:12Z',
          },
        ],
      },
    ]) {
      test('rejects malformed task-list page or row: $malformed', () {
        final result = decoder.decodeTaskListPage(
          utf8.encode(jsonEncode(malformed)),
        );

        expect(result, isA<Failed<RemotePage<RemoteTaskList>>>());
        expect(
          (result as Failed<RemotePage<RemoteTaskList>>).failure.code,
          'google_tasks.malformed_success',
        );
      });
    }

    test('rejects one malformed task row instead of skipping it', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              _liveTask('task-1'),
              <String, Object>{..._liveTask('task-2'), 'status': 'unknown'},
            ],
          }),
        ),
      );

      expect(result, isA<Failed<RemotePage<RemoteTask>>>());
      expect(
        (result as Failed<RemotePage<RemoteTask>>).failure.code,
        'google_tasks.unsupported_task_status',
      );
    });

    test('REC-007 rejects a malformed conflict timestamp', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                ..._liveTask('task-1'),
                'updated': 'not-a-timestamp',
              },
            ],
          }),
        ),
      );

      expect(result, isA<Failed<RemotePage<RemoteTask>>>());
      expect(
        (result as Failed<RemotePage<RemoteTask>>).failure.code,
        'google_tasks.malformed_success',
      );
    });

    test('rejects malformed JSON as a typed scope failure', () {
      final result = decoder.decodeTaskPage(
        utf8.encode('{"kind":"tasks#tasks","items":['),
      );

      expect(result, isA<Failed<RemotePage<RemoteTask>>>());
      expect(
        (result as Failed<RemotePage<RemoteTask>>).failure.code,
        'google_tasks.malformed_success',
      );
    });

    test('rejects assigned results despite the explicit exclusion flag', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                ..._liveTask('task-1'),
                'assignmentInfo': <String, Object>{'surfaceType': 'SPACE'},
              },
            ],
          }),
        ),
      );

      expect(result, isA<Failed<RemotePage<RemoteTask>>>());
      expect(
        (result as Failed<RemotePage<RemoteTask>>).failure.code,
        'google_tasks.assigned_task_unsupported',
      );
    });

    test('rejects a due value that is not canonical UTC midnight', () {
      final result = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{
                ..._liveTask('task-1'),
                'due': '2026-08-16T01:00:00+01:00',
              },
            ],
          }),
        ),
      );

      expect(result, isA<Failed<RemotePage<RemoteTask>>>());
      expect(
        (result as Failed<RemotePage<RemoteTask>>).failure.code,
        'google_tasks.malformed_due',
      );
    });

    test('rejects invalid resource and collection kinds', () {
      final collection = decoder.decodeTaskPage(
        utf8.encode(jsonEncode(<String, Object>{'kind': 'future#tasks'})),
      );
      final resource = decoder.decodeTaskPage(
        utf8.encode(
          jsonEncode(<String, Object>{
            'kind': 'tasks#tasks',
            'items': <Object>[
              <String, Object>{..._liveTask('task-1'), 'kind': 'future#task'},
            ],
          }),
        ),
      );

      expect(collection, isA<Failed<RemotePage<RemoteTask>>>());
      expect(resource, isA<Failed<RemotePage<RemoteTask>>>());
    });
  });
}

Map<String, Object> _liveTask(String id) => <String, Object>{
  'kind': 'tasks#task',
  'id': id,
  'etag': 'etag-$id',
  'title': 'Synthetic $id',
  'updated': '2026-08-15T18:31:00Z',
  'position': '0001',
  'status': 'needsAction',
};
