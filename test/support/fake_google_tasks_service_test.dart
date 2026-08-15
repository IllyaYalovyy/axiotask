import 'dart:convert';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_google_tasks_service.dart';

void main() {
  group('FakeGoogleTasksService qualification', () {
    test('records exact canonical calls and supports exact counts', () async {
      final fake = FakeGoogleTasksService();

      final created = await fake.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic list'),
      );
      await fake.listTaskLists();
      await fake.listTaskLists();

      expect(created, isA<CommittedMutation<RemoteTaskList>>());
      expect(fake.callCount(FakeGoogleTasksMethod.createTaskList), 1);
      expect(fake.callCount(FakeGoogleTasksMethod.listTaskLists), 2);
      expect(fake.calls, hasLength(3));
      expect(fake.calls.first.method, 'POST');
      expect(fake.calls.first.path, '/tasks/v1/users/@me/lists');
      expect(fake.calls.first.body, <String, Object?>{
        'title': 'Synthetic list',
      });
      expect(fake.calls[1].query, <String, String>{'maxResults': '1000'});
    });

    test(
      'page tokens and canonical order are deterministic and strict',
      () async {
        final fake = FakeGoogleTasksService(taskListPageSize: 2);
        for (final title in <String>[
          'Synthetic A',
          'Synthetic B',
          'Synthetic C',
        ]) {
          await fake.createTaskList(CreateTaskListOperation(title: title));
        }

        final first =
            (await fake.listTaskLists() as Success<RemotePage<RemoteTaskList>>)
                .value;
        final second =
            (await fake.listTaskLists(pageToken: first.nextPageToken)
                    as Success<RemotePage<RemoteTaskList>>)
                .value;

        expect(first.items.map((item) => item.title), <String>[
          'Synthetic A',
          'Synthetic B',
        ]);
        expect(second.items.map((item) => item.title), <String>['Synthetic C']);
        final invalid = await fake.listTaskLists(
          pageToken: const PageToken('not-a-fake-page-token'),
        );
        expect(invalid, isA<Failed<RemotePage<RemoteTaskList>>>());
        final fabricated = await fake.listTaskLists(
          pageToken: const PageToken('fake:lists:1'),
        );
        expect(fabricated, isA<Failed<RemotePage<RemoteTaskList>>>());
      },
    );

    test('orders parents, children, and siblings by opaque position', () async {
      final fake = FakeGoogleTasksService(taskPageSize: 2);
      final list =
          (await fake.createTaskList(
                    const CreateTaskListOperation(title: 'Synthetic ordering'),
                  )
                  as CommittedMutation<RemoteTaskList>)
              .value;
      final parent =
          (await fake.createTask(
                    CreateTaskOperation(
                      taskListId: list.id,
                      title: 'Synthetic parent',
                      status: RemoteTaskStatus.needsAction,
                    ),
                  )
                  as CommittedMutation<RemoteTask>)
              .value;
      await fake.createTask(
        CreateTaskOperation(
          taskListId: list.id,
          title: 'Synthetic child',
          status: RemoteTaskStatus.needsAction,
          parentId: parent.id,
        ),
      );
      await fake.createTask(
        CreateTaskOperation(
          taskListId: list.id,
          title: 'Synthetic sibling',
          status: RemoteTaskStatus.needsAction,
          previousId: parent.id,
        ),
      );

      final first =
          (await fake.listTasks(list.id) as Success<RemotePage<RemoteTask>>)
              .value;
      final second =
          (await fake.listTasks(list.id, pageToken: first.nextPageToken)
                  as Success<RemotePage<RemoteTask>>)
              .value;

      expect(
        <String>[
          ...first.items.cast<RemoteLiveTask>().map((task) => task.title),
          ...second.items.cast<RemoteLiveTask>().map((task) => task.title),
        ],
        <String>['Synthetic parent', 'Synthetic child', 'Synthetic sibling'],
      );
    });

    test(
      'raw HTTP transport rejects invalid methods, paths, flags, and parents',
      () async {
        final fake = FakeGoogleTasksService();
        await fake.createTaskList(
          const CreateTaskListOperation(title: 'Synthetic list'),
        );
        final client = FakeGoogleTasksHttpClient(fake);
        addTearDown(client.close);

        final wrongMethod = await client.send(
          http.Request(
            'PUT',
            Uri.parse('https://fake.googleapis.test/tasks/v1/users/@me/lists'),
          ),
        );
        final wrongPath = await client.send(
          http.Request(
            'GET',
            Uri.parse('https://fake.googleapis.test/tasks/v1/not-supported'),
          ),
        );
        final wrongFlags = await client.send(
          http.Request(
            'GET',
            Uri.parse(
              'https://fake.googleapis.test/tasks/v1/lists/list-1/tasks'
              '?maxResults=100&showCompleted=true&showHidden=false'
              '&showDeleted=true&showAssigned=false',
            ),
          ),
        );
        final invalidParentRequest =
            http.Request(
                'POST',
                Uri.parse(
                  'https://fake.googleapis.test/tasks/v1/lists/list-1/tasks'
                  '?parent=missing-task',
                ),
              )
              ..headers['content-type'] = 'application/json; charset=utf-8'
              ..body = jsonEncode(<String, Object?>{
                'title': 'Must not exist',
                'status': 'needsAction',
              });
        final invalidParent = await client.send(invalidParentRequest);

        expect(wrongMethod.statusCode, 405);
        expect(wrongPath.statusCode, 404);
        expect(wrongFlags.statusCode, 400);
        expect(invalidParent.statusCode, 404);
        expect(fake.callCount(FakeGoogleTasksMethod.createTask), 1);
        expect(fake.taskCount, 0);
      },
    );
  });
}
