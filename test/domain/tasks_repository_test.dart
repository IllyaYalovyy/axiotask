import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task queries always require an account partition', () {
    const account = AccountId(7);
    const list = TaskListId(11);

    expect(
      const TasksQuery(accountId: account, taskListId: list),
      const TasksQuery(accountId: account, taskListId: list),
    );
    expect(const TasksQuery(accountId: account).accountId, account);
  });

  test('cached snapshots cannot represent verified freshness', () {
    final snapshot = CachedTasksSnapshot(
      accountId: AccountId(1),
      taskLists: <CachedTaskList>[],
      tasks: <CachedTask>[],
      completeness: CacheCompleteness.complete,
    );

    expect(snapshot.verification, CacheVerification.unverifiedCache);
    expect(snapshot.completeness, CacheCompleteness.complete);
    expect(snapshot.copyWith(), snapshot);
    expect(
      () => snapshot.taskLists.add(
        const CachedTaskList(
          id: TaskListId(2),
          accountId: AccountId(1),
          remoteId: TaskListRemoteId('synthetic-list'),
          title: 'Synthetic',
        ),
      ),
      throwsUnsupportedError,
    );
  });
}
