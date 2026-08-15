import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:flutter_test/flutter_test.dart';

typedef GoogleTasksContractServiceFactory = GoogleTasksService Function();

void defineGoogleTasksServiceContract(
  String implementation,
  GoogleTasksContractServiceFactory createService,
) {
  group('$implementation shared Google Tasks contract', () {
    late GoogleTasksService service;

    setUp(() => service = createService());
    tearDown(() => service.close());

    test('paginates duplicate list creates in deterministic order', () async {
      final first = await service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic duplicate'),
      );
      final second = await service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic duplicate'),
      );
      final third = await service.createTaskList(
        const CreateTaskListOperation(title: 'Synthetic third'),
      );

      final firstList = (first as CommittedMutation<RemoteTaskList>).value;
      final secondList = (second as CommittedMutation<RemoteTaskList>).value;
      expect(secondList.id, isNot(firstList.id));
      expect(third, isA<CommittedMutation<RemoteTaskList>>());

      final pageOne = _success(await service.listTaskLists());
      final pageTwo = _success(
        await service.listTaskLists(pageToken: pageOne.nextPageToken),
      );
      expect(
        <String>[
          ...pageOne.items.map((item) => item.title),
          ...pageTwo.items.map((item) => item.title),
        ],
        <String>[
          'Synthetic duplicate',
          'Synthetic duplicate',
          'Synthetic third',
        ],
      );
      expect(pageOne.items, hasLength(2));
      expect(pageOne.nextPageToken, isNotNull);
      expect(pageTwo.items, hasLength(1));
      expect(pageTwo.nextPageToken, isNull);
    });

    test(
      'changes etags and preserves identity through hierarchy moves',
      () async {
        final source = _committed(
          await service.createTaskList(
            const CreateTaskListOperation(title: 'Synthetic source'),
          ),
        );
        final destination = _committed(
          await service.createTaskList(
            const CreateTaskListOperation(title: 'Synthetic destination'),
          ),
        );
        final renamed = _committed(
          await service.renameTaskList(
            RenameTaskListOperation(
              taskListId: source.id,
              title: 'Synthetic renamed source',
            ),
          ),
        );
        expect(renamed.id, source.id);
        expect(renamed.etag, isNot(source.etag));

        final parent = _task(
          await service.createTask(
            CreateTaskOperation(
              taskListId: source.id,
              title: 'Synthetic parent',
              status: RemoteTaskStatus.needsAction,
            ),
          ),
        );
        final child = _task(
          await service.createTask(
            CreateTaskOperation(
              taskListId: source.id,
              title: 'Synthetic child',
              status: RemoteTaskStatus.needsAction,
              parentId: parent.id,
            ),
          ),
        );
        final sibling = _task(
          await service.createTask(
            CreateTaskOperation(
              taskListId: source.id,
              title: 'Synthetic sibling',
              status: RemoteTaskStatus.needsAction,
              previousId: parent.id,
            ),
          ),
        );

        final completedParent = _task(
          await service.patchTask(
            PatchTaskOperation(
              taskListId: source.id,
              taskId: parent.id,
              etag: parent.etag!,
              title: parent.title,
              notes: const OptionalFieldWrite<String>.clear(),
              status: RemoteTaskStatus.completed,
              due: const OptionalFieldWrite<RemoteDate>.clear(),
            ),
          ),
        );
        expect(
          (_success(
                    await service.listTasks(source.id),
                  ).items.singleWhere((task) => task.id == child.id)
                  as RemoteLiveTask)
              .status,
          RemoteTaskStatus.completed,
        );
        final reopenedParent = _task(
          await service.patchTask(
            PatchTaskOperation(
              taskListId: source.id,
              taskId: parent.id,
              etag: completedParent.etag!,
              title: parent.title,
              notes: const OptionalFieldWrite<String>.clear(),
              status: RemoteTaskStatus.needsAction,
              due: const OptionalFieldWrite<RemoteDate>.clear(),
            ),
          ),
        );
        expect(
          (_success(
                    await service.listTasks(source.id),
                  ).items.singleWhere((task) => task.id == child.id)
                  as RemoteLiveTask)
              .status,
          RemoteTaskStatus.completed,
        );

        final patched = _task(
          await service.patchTask(
            PatchTaskOperation(
              taskListId: source.id,
              taskId: sibling.id,
              etag: sibling.etag!,
              title: 'Synthetic patched sibling',
              notes: const OptionalFieldWrite<String>.clear(),
              status: RemoteTaskStatus.completed,
              due: const OptionalFieldWrite<RemoteDate>.set(
                RemoteDate(2026, 8, 15),
              ),
            ),
          ),
        );
        expect(patched.id, sibling.id);
        expect(patched.etag, isNot(sibling.etag));
        expect(patched.status, RemoteTaskStatus.completed);
        expect(patched.due, const RemoteDate(2026, 8, 15));

        final moved = _task(
          await service.moveTask(
            MoveTaskOperation(
              sourceTaskListId: source.id,
              destinationTaskListId: destination.id,
              taskId: parent.id,
              etag: reopenedParent.etag!,
              pathFreshness: MutationPathFreshness.current,
            ),
          ),
        );
        expect(moved.id, parent.id);
        expect(moved.etag, isNot(parent.etag));

        final destinationTasks = _success(
          await service.listTasks(destination.id),
        );
        expect(
          destinationTasks.items.map((task) => task.id).toSet(),
          <RemoteTaskId>{parent.id, child.id},
        );
        expect(
          (destinationTasks.items.singleWhere((task) => task.id == child.id)
                  as RemoteLiveTask)
              .parentId,
          parent.id,
        );
      },
    );

    test('uses task tombstones and removes deleted lists', () async {
      final list = _committed(
        await service.createTaskList(
          const CreateTaskListOperation(title: 'Synthetic deletion'),
        ),
      );
      final parent = _task(
        await service.createTask(
          CreateTaskOperation(
            taskListId: list.id,
            title: 'Synthetic parent',
            notes: 'Synthetic notes',
            status: RemoteTaskStatus.needsAction,
          ),
        ),
      );
      final child = _task(
        await service.createTask(
          CreateTaskOperation(
            taskListId: list.id,
            title: 'Synthetic child',
            status: RemoteTaskStatus.needsAction,
            parentId: parent.id,
          ),
        ),
      );

      expect(
        await service.deleteTask(
          DeleteTaskOperation(
            taskListId: list.id,
            taskId: parent.id,
            etag: parent.etag!,
            pathFreshness: MutationPathFreshness.current,
          ),
        ),
        isA<CommittedMutation<void>>(),
      );
      final deletedPage = _success(await service.listTasks(list.id));
      expect(deletedPage.items, hasLength(2));
      expect(deletedPage.items, everyElement(isA<RemoteTaskTombstone>()));
      expect(deletedPage.items.map((task) => task.id).toSet(), <RemoteTaskId>{
        parent.id,
        child.id,
      });
      expect(
        await service.deleteTask(
          DeleteTaskOperation(
            taskListId: list.id,
            taskId: parent.id,
            etag: parent.etag!,
            pathFreshness: MutationPathFreshness.current,
          ),
        ),
        isA<CommittedMutation<void>>(),
      );
      final afterRepeatedDelete = _success(await service.listTasks(list.id));
      expect(
        afterRepeatedDelete.items.map((task) => task.etag),
        deletedPage.items.map((task) => task.etag),
      );

      expect(
        await service.deleteTaskList(DeleteTaskListOperation(list.id)),
        isA<CommittedMutation<void>>(),
      );
      expect(
        await service.deleteTaskList(DeleteTaskListOperation(list.id)),
        isA<CommittedMutation<void>>(),
      );
      final lists = _success(await service.listTaskLists());
      expect(lists.items, isEmpty);
      expect(
        await service.listTasks(list.id),
        isA<Failed<RemotePage<RemoteTask>>>(),
      );
    });

    test(
      'rejects stale task etags and invalid hierarchy without mutation',
      () async {
        final list = _committed(
          await service.createTaskList(
            const CreateTaskListOperation(title: 'Synthetic validation'),
          ),
        );
        final parent = _task(
          await service.createTask(
            CreateTaskOperation(
              taskListId: list.id,
              title: 'Synthetic parent',
              status: RemoteTaskStatus.needsAction,
            ),
          ),
        );
        final child = _task(
          await service.createTask(
            CreateTaskOperation(
              taskListId: list.id,
              title: 'Synthetic child',
              status: RemoteTaskStatus.needsAction,
              parentId: parent.id,
            ),
          ),
        );

        final stale = await service.patchTask(
          PatchTaskOperation(
            taskListId: list.id,
            taskId: parent.id,
            etag: 'stale-etag',
            title: 'Must not land',
            notes: const OptionalFieldWrite<String>.clear(),
            status: RemoteTaskStatus.completed,
            due: const OptionalFieldWrite<RemoteDate>.clear(),
          ),
        );
        expect(stale, isA<RejectedMutation<RemoteTask>>());
        expect(
          (stale as RejectedMutation<RemoteTask>).error.kind,
          GoogleTasksErrorKind.conditional,
        );

        final tooDeep = await service.createTask(
          CreateTaskOperation(
            taskListId: list.id,
            title: 'Must not exist',
            status: RemoteTaskStatus.needsAction,
            parentId: child.id,
          ),
        );
        expect(tooDeep, isA<RejectedMutation<RemoteTask>>());
        expect(_success(await service.listTasks(list.id)).items, hasLength(2));
      },
    );
  });
}

Future<List<String>> observeGoogleTasksContract(
  GoogleTasksService service,
) async {
  final list = _committed(
    await service.createTaskList(
      const CreateTaskListOperation(title: 'Synthetic observations'),
    ),
  );
  final first = _task(
    await service.createTask(
      CreateTaskOperation(
        taskListId: list.id,
        title: 'Synthetic first',
        status: RemoteTaskStatus.needsAction,
      ),
    ),
  );
  final second = _task(
    await service.createTask(
      CreateTaskOperation(
        taskListId: list.id,
        title: 'Synthetic second',
        status: RemoteTaskStatus.needsAction,
        previousId: first.id,
      ),
    ),
  );
  final page = _success(await service.listTasks(list.id));
  final deleted = await service.deleteTask(
    DeleteTaskOperation(
      taskListId: list.id,
      taskId: second.id,
      etag: second.etag!,
      pathFreshness: MutationPathFreshness.current,
    ),
  );
  final afterDelete = _success(await service.listTasks(list.id));
  return <String>[
    'list:${list.id.value}:${list.title}:${list.etag}',
    for (final task in page.items)
      'task:${task.id.value}:${(task as RemoteLiveTask).title}:${task.etag}',
    'delete:${deleted.runtimeType}',
    for (final task in afterDelete.items)
      'after:${task.id.value}:${task.deleted}:${task.etag}',
  ];
}

RemotePage<T> _success<T>(Outcome<RemotePage<T>> outcome) =>
    (outcome as Success<RemotePage<T>>).value;

T _committed<T>(GoogleTasksMutationResult<T> result) =>
    (result as CommittedMutation<T>).value;

RemoteLiveTask _task(GoogleTasksMutationResult<RemoteTask> result) =>
    _committed(result) as RemoteLiveTask;
