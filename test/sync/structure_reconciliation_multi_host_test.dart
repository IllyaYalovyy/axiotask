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
  test(
    'REC-010 two hosts converge on Google order without oscillation',
    () async {
      const subject = AccountSubject('synthetic-structure-multi-host-subject');
      final google = FakeGoogleTasksService();
      addTearDown(google.close);
      final list = switch (await google.createTaskList(
        const CreateTaskListOperation(title: 'Shared order'),
      )) {
        CommittedMutation<RemoteTaskList>(:final value) => value,
        _ => throw StateError('Synthetic list setup failed.'),
      };
      final remoteTasks = <RemoteLiveTask>[];
      for (final title in <String>['First', 'Second', 'Third']) {
        remoteTasks.add(switch (await google.createTask(
          CreateTaskOperation(
            taskListId: list.id,
            title: title,
            status: RemoteTaskStatus.needsAction,
          ),
        )) {
          CommittedMutation<RemoteTask>(value: final RemoteLiveTask value) =>
            value,
          _ => throw StateError('Synthetic task setup failed.'),
        });
      }
      final harness = await MultiHostHarness.create(
        hostCount: 2,
        googleTasks: google,
        accountSubject: subject,
        initialWallTime: DateTime.utc(2026, 8, 15, 15),
        seed: 18002,
      );
      addTearDown(harness.close);
      final accountIds = <AccountId>[];
      for (final host in harness.hosts) {
        accountIds.add(
          AccountId(await host.store.createAccount(subject.value)),
        );
      }
      for (var index = 0; index < 2; index += 1) {
        expect(
          (await _run(harness.hosts[index], accountIds[index])).outcome,
          SyncRunOutcome.succeeded,
        );
      }

      final snapshots = <CachedTasksSnapshot>[];
      for (var index = 0; index < 2; index += 1) {
        snapshots.add(
          await DatabaseTasksRepository(
            harness.hosts[index].store,
          ).watchTasks(TasksQuery(accountId: accountIds[index])).first,
        );
      }
      TaskId localTask(int host, int remoteIndex) => snapshots[host].tasks
          .singleWhere(
            (task) => task.remoteId?.value == remoteTasks[remoteIndex].id.value,
          )
          .id;
      TaskListId localList(int host) => snapshots[host].taskLists.single.id;

      expect(
        await DatabaseTasksRepository(
          harness.hosts[0].store,
          clock: harness.hosts[0].clock,
        ).apply(
          MoveTaskCommand(
            accountId: accountIds[0],
            taskId: localTask(0, 0),
            destinationTaskListId: localList(0),
            previousTaskId: localTask(0, 2),
          ),
        ),
        isA<Success<void>>(),
      );
      expect(
        await DatabaseTasksRepository(
          harness.hosts[1].store,
          clock: harness.hosts[1].clock,
        ).apply(
          MoveTaskCommand(
            accountId: accountIds[1],
            taskId: localTask(1, 0),
            destinationTaskListId: localList(1),
          ),
        ),
        isA<Success<void>>(),
      );

      expect((await _run(harness.hosts[0], accountIds[0])).moveOperations, 1);
      final losingReport = await _run(harness.hosts[1], accountIds[1]);
      expect(losingReport.googleWonStructures, 1);
      expect(losingReport.moveOperations, 0);
      expect(
        (await _run(harness.hosts[0], accountIds[0])).outcome,
        SyncRunOutcome.succeeded,
      );
      final writesAtConvergence = google.callCount(
        FakeGoogleTasksMethod.moveTask,
      );

      List<String> remoteOrder(CachedTasksSnapshot snapshot) => snapshot.tasks
          .map((task) => task.remoteId!.value)
          .toList(growable: false);
      final converged = <List<String>>[];
      for (var index = 0; index < 2; index += 1) {
        final snapshot = await DatabaseTasksRepository(
          harness.hosts[index].store,
        ).watchTasks(TasksQuery(accountId: accountIds[index])).first;
        converged.add(remoteOrder(snapshot));
        expect(
          (await _run(harness.hosts[index], accountIds[index])).outcome,
          SyncRunOutcome.succeeded,
        );
      }
      expect(converged[0], converged[1]);
      expect(
        google.callCount(FakeGoogleTasksMethod.moveTask),
        writesAtConvergence,
      );
    },
  );
}

Future<SyncRunReport> _run(MultiHost host, AccountId accountId) => SyncEngine(
  store: DatabaseReadSyncStore(host.store),
  googleTasks: host.googleTasks,
  authorization: host.authorization,
  clock: host.clock,
  random: host.random,
).run(SyncRunRequest(accountId: accountId));
