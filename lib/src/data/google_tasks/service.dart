import '../../core/outcome.dart';
import 'dto.dart';
import 'request.dart';

abstract interface class GoogleTasksService {
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  });

  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  });

  void close();
}
