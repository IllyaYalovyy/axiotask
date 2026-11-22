import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_clock.dart';
import '../support/fake_google_tasks_service.dart';

/// The device's "Read-only sync" setting (v1.5.3 parity): a run reads Google
/// Tasks but publishes nothing, and every held-back change is published
/// unchanged once the setting is turned off.
void main() {
  const subject = AccountSubject('synthetic-read-only-subject');
  final startedAt = DateTime.utc(2026, 11, 21, 12);

  const mutations = <FakeGoogleTasksMethod>{
    FakeGoogleTasksMethod.createTaskList,
    FakeGoogleTasksMethod.createTask,
    FakeGoogleTasksMethod.patchTask,
    FakeGoogleTasksMethod.deleteTask,
    FakeGoogleTasksMethod.deleteTaskList,
    FakeGoogleTasksMethod.moveTask,
  };

  test(
    'a read-only run publishes nothing and keeps local work pending',
    () async {
      final remote = FakeGoogleTasksService();
      addTearDown(remote.close);
      final database = AppDatabase.inMemory();
      addTearDown(database.close);
      final accountId = AccountId(await database.createAccount(subject.value));
      final clock = FakeClock(startedAt);

      SyncEngine engine({required bool publish}) => SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: remote,
        authorization: const SyntheticAuthorization(subject),
        clock: clock,
        random: SequenceRandomSource(List<int>.generate(256, (index) => index)),
        publishLocalChanges: publish,
      );

      final list =
          (await DatabaseTaskListsRepository(
                    database: database,
                    clock: clock,
                  ).createTaskList(
                    CreateTaskListCommand(
                      accountId: accountId,
                      title: 'Held back list',
                    ),
                  )
                  as Success<TaskListId>)
              .value;
      final task =
          (await DatabaseTasksRepository(database, clock: clock).createTask(
            CreateTaskCommand(
              accountId: accountId,
              taskListId: list,
              title: 'Held back task',
            ),
          ) as Success<TaskId>).value;

      final readOnly = await engine(publish: false)
          .run(SyncRunRequest(accountId: accountId));

      expect(readOnly.outcome, SyncRunOutcome.succeeded);
      expect(readOnly.createOperations, 0);
      expect(
        remote.calls.where((call) => mutations.contains(call.operation)),
        isEmpty,
        reason: 'Read-only synchronization must never mutate Google Tasks',
      );
      expect(
        remote.callCount(FakeGoogleTasksMethod.listTaskLists),
        greaterThan(0),
        reason: 'Read-only synchronization still reads Google Tasks',
      );
      final desired = DesiredStateDao(database);
      expect(
        (await desired.readTaskList(accountId, list))?.state,
        DesiredStateLifecycle.pending,
      );
      expect(
        (await desired.readTask(accountId, task))?.state,
        DesiredStateLifecycle.pending,
      );
      final kept = await DatabaseTasksRepository(database)
          .watchTasks(TasksQuery(accountId: accountId))
          .first;
      expect(kept.tasks.single.title, 'Held back task');

      // Turning the setting off publishes exactly what was held back.
      final published = await engine(publish: true)
          .run(SyncRunRequest(accountId: accountId));

      expect(published.outcome, SyncRunOutcome.succeeded);
      expect(published.createOperations, 2);
      expect(
        (await desired.readTask(accountId, task))?.state,
        DesiredStateLifecycle.confirmed,
      );
    },
  );
}
