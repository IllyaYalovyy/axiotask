import '../../core/outcome.dart';
import '../../data/auth/authorization.dart';
import '../../data/google_tasks/dto.dart';
import '../../data/google_tasks/mutation.dart';
import '../../data/google_tasks/request.dart';
import '../../data/google_tasks/service.dart';
import 'app_composition.dart';

ReadSliceTransport createSyntheticReadTransport(AccountSubject subject) =>
    ReadSliceTransport(
      authorization: SyntheticAuthorization(subject),
      googleTasks: _SyntheticReadService(),
    );

final class _SyntheticReadService implements GoogleTasksService {
  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => Outcome<RemotePage<RemoteTaskList>>.success(
    RemotePage<RemoteTaskList>(
      items: <RemoteTaskList>[
        RemoteTaskList(
          id: const RemoteTaskListId('synthetic-remote-list'),
          etag: 'synthetic-list-etag',
          title: 'Synthetic inbox',
          updated: DateTime.utc(2026, 1, 1, 12),
          selfLink: null,
        ),
      ],
      collectionEtag: 'synthetic-list-collection-etag',
      nextPageToken: null,
    ),
  );

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => Outcome<RemotePage<RemoteTask>>.success(
    RemotePage<RemoteTask>(
      items: <RemoteTask>[
        RemoteLiveTask(
          id: const RemoteTaskId('synthetic-remote-task'),
          etag: 'synthetic-task-etag',
          updated: DateTime.utc(2026, 1, 1, 12),
          selfLink: null,
          title: 'Verified synthetic task',
          parentId: null,
          position: '00000000000000000001',
          notes: 'This isolated composition never contacts Google.',
          status: RemoteTaskStatus.needsAction,
          due: null,
          completed: null,
          hidden: false,
          links: const <RemoteTaskLink>[],
          webViewLink: null,
        ),
      ],
      collectionEtag: 'synthetic-task-collection-etag',
      nextPageToken: null,
    ),
  );

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) => throw UnsupportedError('Synthetic read composition is read-only.');

  @override
  void close() {}
}
