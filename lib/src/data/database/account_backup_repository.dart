import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';
import '../preferences/relational_preferences.dart';
import 'app_database.dart';
import 'tasks_repository.dart';

final class DatabaseAccountBackupRepository implements AccountBackupRepository {
  const DatabaseAccountBackupRepository(this._database);

  final AppDatabase _database;

  @override
  Future<AccountBackupSnapshot> readProjectedAccount(
    AccountId accountId,
  ) async {
    final accounts = await _database.allAccounts();
    final account = accounts
        .where((row) => row.id == accountId.value)
        .firstOrNull;
    if (account == null) throw StateError('backup_account_not_found');

    final snapshot = await DatabaseTasksRepository(
      _database,
    ).watchTasks(TasksQuery(accountId: accountId)).first;
    final preferences = await DriftRelationalPreferences(
      _database,
    ).watchAllListPreferences(accountId).first;
    final orderedLists = snapshot.taskLists.toList(growable: false)
      ..sort((left, right) {
        final leftOrder = preferences[left.id]?.sidebarOrder;
        final rightOrder = preferences[right.id]?.sidebarOrder;
        if (leftOrder != null || rightOrder != null) {
          if (leftOrder == null) return 1;
          if (rightOrder == null) return -1;
          final byPreference = leftOrder.compareTo(rightOrder);
          if (byPreference != 0) return byPreference;
        }
        return left.id.value.compareTo(right.id.value);
      });

    final listKeys = <TaskListId, String>{};
    final lists = <AccountBackupList>[];
    for (var index = 0; index < orderedLists.length; index += 1) {
      final list = orderedLists[index];
      final key = _key('list', index + 1);
      listKeys[list.id] = key;
      lists.add(
        AccountBackupList(
          key: key,
          googleId: list.remoteId?.value,
          title: list.title,
          order: index,
        ),
      );
    }

    final orderedTasks = <CachedTask>[];
    for (final list in orderedLists) {
      final roots = snapshot.tasks.where(
        (task) => task.taskListId == list.id && task.parentTaskId == null,
      );
      for (final root in roots) {
        orderedTasks.add(root);
        orderedTasks.addAll(
          snapshot.tasks.where(
            (task) =>
                task.taskListId == list.id && task.parentTaskId == root.id,
          ),
        );
      }
    }
    final taskKeys = <TaskId, String>{
      for (var index = 0; index < orderedTasks.length; index += 1)
        orderedTasks[index].id: _key('task', index + 1),
    };
    final siblingCounts = <String, int>{};
    final tasks = <AccountBackupTask>[];
    for (final task in orderedTasks) {
      final listKey = listKeys[task.taskListId];
      if (listKey == null) throw StateError('backup_task_list_missing');
      final parentKey = task.parentTaskId == null
          ? null
          : taskKeys[task.parentTaskId];
      if (task.parentTaskId != null && parentKey == null) {
        throw StateError('backup_task_parent_missing');
      }
      final siblingKey = '$listKey\u0000${parentKey ?? ''}';
      final order = siblingCounts.update(
        siblingKey,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      tasks.add(
        AccountBackupTask(
          key: taskKeys[task.id]!,
          googleId: task.remoteId?.value,
          listKey: listKey,
          parentKey: parentKey,
          title: task.title,
          notes: task.notes,
          status: task.status,
          due: task.due,
          order: order,
        ),
      );
    }
    return AccountBackupSnapshot(
      sourceGoogleSubject: account.googleSubject,
      lists: lists,
      tasks: tasks,
    );
  }
}

String _key(String prefix, int value) =>
    '$prefix-${value.toString().padLeft(6, '0')}';
