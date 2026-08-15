import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_google_tasks_service.dart';
import '../support/multi_host.dart';

void main() {
  test('MOD-001/MOD-002 two hosts converge and remain quiescent', () async {
    const subject = AccountSubject('synthetic-content-multi-host-subject');
    final google = FakeGoogleTasksService();
    addTearDown(google.close);
    final list = switch (await google.createTaskList(
      const CreateTaskListOperation(title: 'Shared list'),
    )) {
      CommittedMutation<RemoteTaskList>(:final value) => value,
      _ => throw StateError('Synthetic list setup failed.'),
    };
    final task = switch (await google.createTask(
      CreateTaskOperation(
        taskListId: list.id,
        title: 'Shared base',
        notes: 'Base notes',
        status: RemoteTaskStatus.needsAction,
      ),
    )) {
      CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) => value,
      _ => throw StateError('Synthetic task setup failed.'),
    };
    final harness = await MultiHostHarness.create(
      hostCount: 2,
      googleTasks: google,
      accountSubject: subject,
      initialWallTime: DateTime.utc(2026, 8, 15, 12, 0, 10),
      seed: 16002,
    );
    addTearDown(harness.close);
    final accountIds = <AccountId>[];
    for (final host in harness.hosts) {
      accountIds.add(AccountId(await host.store.createAccount(subject.value)));
    }
    harness.hosts[1].clockControl.setWallTime(
      DateTime.utc(2026, 8, 15, 12, 0, 5),
    );

    for (var index = 0; index < harness.hosts.length; index += 1) {
      expect(
        (await _run(harness.hosts[index], accountIds[index])).outcome,
        SyncRunOutcome.succeeded,
      );
    }
    final taskIds = <TaskId>[];
    for (var index = 0; index < harness.hosts.length; index += 1) {
      final snapshot = await DatabaseTasksRepository(
        harness.hosts[index].store,
      ).watchTasks(TasksQuery(accountId: accountIds[index])).first;
      taskIds.add(
        snapshot.tasks
            .singleWhere(
              (candidate) => candidate.remoteId?.value == task.id.value,
            )
            .id,
      );
    }

    expect(
      await DatabaseTasksRepository(
        harness.hosts[0].store,
        clock: harness.hosts[0].clock,
      ).apply(
        UpdateTaskContentCommand(
          accountId: accountIds[0],
          taskId: taskIds[0],
          title: 'Host one newer',
          notes: null,
          status: TaskStatus.completed,
          due: TaskDate(2026, 8, 25),
        ),
      ),
      isA<Success<void>>(),
    );
    expect(
      await DatabaseTasksRepository(
        harness.hosts[1].store,
        clock: harness.hosts[1].clock,
      ).apply(
        UpdateTaskContentCommand(
          accountId: accountIds[1],
          taskId: taskIds[1],
          title: 'Host two older',
          notes: 'Older notes',
          status: TaskStatus.needsAction,
          due: null,
        ),
      ),
      isA<Success<void>>(),
    );

    expect(
      (await _run(harness.hosts[1], accountIds[1])).outcome,
      SyncRunOutcome.succeeded,
    );
    expect(
      (await _run(harness.hosts[0], accountIds[0])).outcome,
      SyncRunOutcome.succeeded,
    );
    expect(
      (await _run(harness.hosts[1], accountIds[1])).outcome,
      SyncRunOutcome.succeeded,
    );
    final writesAtConvergence = google.callCount(
      FakeGoogleTasksMethod.patchTask,
    );

    for (var index = 0; index < harness.hosts.length; index += 1) {
      final snapshot = await DatabaseTasksRepository(
        harness.hosts[index].store,
      ).watchTasks(TasksQuery(accountId: accountIds[index])).first;
      final projected = snapshot.tasks.single;
      expect(projected.title, 'Host one newer');
      expect(projected.notes, isNull);
      expect(projected.status, TaskStatus.completed);
      expect(projected.due, TaskDate(2026, 8, 25));
      expect(
        (await _run(harness.hosts[index], accountIds[index])).outcome,
        SyncRunOutcome.succeeded,
      );
    }
    expect(
      google.callCount(FakeGoogleTasksMethod.patchTask),
      writesAtConvergence,
    );
  });
}

Future<SyncRunReport> _run(MultiHost host, AccountId accountId) => SyncEngine(
  store: DatabaseReadSyncStore(host.store),
  googleTasks: host.googleTasks,
  authorization: host.authorization,
  clock: host.clock,
  random: host.random,
).run(SyncRunRequest(accountId: accountId));
