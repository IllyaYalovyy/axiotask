// Duplicate through the shared repository boundary: the v1.5.3 copy rule
// (title "<title> (copy)", same list and parent, no notes, no due date, open
// status, no subtasks), distinct local identity with no remote identity, an
// untouched source, and one transaction that stores the whole copy or nothing.

import 'dart:io';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/duplication_fixture.dart';
import '../../support/fake_google_tasks_service.dart';

void main() {
  late FakeGoogleTasksService google;
  late DuplicationFixture fixture;
  late SyncedSources sources;

  setUp(() async {
    google = FakeGoogleTasksService();
    fixture = await DuplicationFixture.open(google: google);
    sources = await fixture.seedSyncedSources();
  });

  tearDown(() async {
    await fixture.close();
    google.close();
  });

  Future<TaskDuplicateReceipt> duplicate(TaskId source) async =>
      switch (await fixture.duplicate(source)) {
        Success<TaskDuplicateReceipt>(:final value) => value,
        Failed<TaskDuplicateReceipt>(:final failure) => fail(failure.code),
      };

  test('a completed leaf is copied open, without notes or date', () async {
    final source = await fixture.task(sources.leaf);
    expect(source.status, TaskStatus.completed);
    expect(source.notes, 'Leaf notes');
    expect(source.due, isNotNull);

    final receipt = await duplicate(sources.leaf);
    final copy = await fixture.task(receipt.taskId);

    expect(receipt.sourceTaskId, sources.leaf);
    expect(receipt.title, 'Call plumber (copy)');
    expect(copy.id, isNot(sources.leaf));
    expect(copy.title, 'Call plumber (copy)');
    expect(copy.notes, isNull);
    expect(copy.due, isNull);
    expect(copy.status, TaskStatus.needsAction);
    expect(copy.taskListId, sources.list);
    expect(copy.parentTaskId, isNull);
    expect(copy.remoteId, isNull);
    expect(copy.webViewLink, isNull);
  });

  test('a subtask is copied under the same parent', () async {
    final receipt = await duplicate(sources.child);
    final copy = await fixture.task(receipt.taskId);

    expect(copy.title, 'Milk (copy)');
    expect(copy.parentTaskId, sources.parent);
    expect(copy.taskListId, sources.list);
    expect(copy.notes, isNull);
    expect(copy.due, isNull);
  });

  test('a parent is copied as one childless task', () async {
    final before = await fixture.snapshot();
    final receipt = await duplicate(sources.parent);
    final after = await fixture.snapshot();

    expect(after.tasks, hasLength(before.tasks.length + 1));
    final copy = after.tasks.singleWhere((task) => task.id == receipt.taskId);
    expect(copy.title, 'Groceries (copy)');
    expect(copy.parentTaskId, isNull);
    expect(
      after.tasks.where((task) => task.parentTaskId == receipt.taskId),
      isEmpty,
      reason: 'v1.5.3 never copies subtasks',
    );
    expect(
      after.tasks
          .where((task) => task.parentTaskId == sources.parent)
          .map((task) => task.id),
      unorderedEquals(<TaskId>[sources.child, sources.completedChild]),
    );
  });

  test('the source projection, remote base and desired state are unchanged '
      'and the copy carries none of its remote identity', () async {
    final storedSource = await fixture.storedSource(sources.parent);
    final remoteBaseCount = await fixture.count('task_remote_bases');
    expect(
      (storedSource['task_remote_bases']! as List<Object?>),
      hasLength(1),
      reason: 'the synced source has a remote base with an ETag',
    );

    final receipt = await duplicate(sources.parent);

    expect(await fixture.storedSource(sources.parent), storedSource);
    expect(await fixture.count('task_remote_bases'), remoteBaseCount);
    final copyRows = await fixture.storedSource(receipt.taskId);
    expect(copyRows['task_remote_bases'], isEmpty);
    final copyRow = (copyRows['tasks']! as List<Map<String, Object?>>).single;
    expect(copyRow['remote_id'], isNull);
    final sourceRow =
        (storedSource['tasks']! as List<Map<String, Object?>>).single;
    expect(copyRow['id'], isNot(sourceRow['id']));

    final desired = (await fixture.desired.readTask(
      fixture.accountId,
      receipt.taskId,
    ))!;
    expect(desired.state, DesiredStateLifecycle.pending);
    expect(desired.desiredLifecycle, DesiredLifecycle.present);
    expect(desired.baseRemoteId, isNull);
    expect(desired.baseEtag, isNull);
    expect(desired.title, 'Groceries (copy)');
    expect(desired.notes, isNull);
    expect(desired.due, isNull);
    expect(desired.status, TaskStatus.needsAction);
    expect(desired.taskListId, sources.list);
    expect(desired.parentTaskId, isNull);
    expect(desired.previousTaskId, isNull);
  });

  test(
    'every Duplicate creates a distinct copy of the stored source',
    () async {
      final first = await duplicate(sources.leaf);
      final second = await duplicate(sources.leaf);
      final ofCopy = await duplicate(first.taskId);

      expect(<TaskId>{
        first.taskId,
        second.taskId,
        ofCopy.taskId,
        sources.leaf,
      }, hasLength(4));
      expect(second.title, 'Call plumber (copy)');
      expect(ofCopy.title, 'Call plumber (copy) (copy)');
    },
  );

  test('a failure at any write boundary stores nothing, and a retry stores '
      'exactly one copy', () async {
    for (final boundary in <DesiredStateTransactionBoundary>[
      DesiredStateTransactionBoundary.afterProjectionWrite,
      DesiredStateTransactionBoundary.afterDesiredStateWrite,
      DesiredStateTransactionBoundary.beforeLocalCommit,
    ]) {
      final tasksBefore = await fixture.count('tasks');
      final desiredBefore = await fixture.count('desired_states');
      final source = await fixture.storedSource(sources.parent);
      final failing = DatabaseTasksRepository(
        fixture.database,
        clock: fixture.clock,
        transactionControl: (reached) {
          if (reached == boundary) {
            throw const DesiredStatePersistenceException(
              'synthetic_duplicate_failure',
            );
          }
        },
      );

      final failed = await failing.duplicateTask(
        DuplicateTaskCommand(
          accountId: fixture.accountId,
          sourceTaskId: sources.parent,
        ),
      );

      expect(failed, isA<Failed<TaskDuplicateReceipt>>(), reason: '$boundary');
      expect(await fixture.count('tasks'), tasksBefore, reason: '$boundary');
      expect(
        await fixture.count('desired_states'),
        desiredBefore,
        reason: '$boundary',
      );
      expect(await fixture.storedSource(sources.parent), source);
    }

    final tasksBefore = await fixture.count('tasks');
    final retry = await duplicate(sources.parent);
    final copies = (await fixture.snapshot()).tasks
        .where((task) => task.title == 'Groceries (copy)')
        .toList();
    expect(copies.single.id, retry.taskId);
    expect(await fixture.count('tasks'), tasksBefore + 1);
  });

  test('a missing, deleted or other-account source stores nothing', () async {
    final deleted = await fixture.tasks.deleteTask(
      DeleteTaskCommand(accountId: fixture.accountId, taskId: sources.leaf),
    );
    expect(deleted, isA<Success<TaskDeleteReceipt>>());
    final otherAccount = AccountId(
      await fixture.database.createAccount('synthetic-other-subject'),
    );
    final tasksBefore = await fixture.count('tasks');
    final desiredBefore = await fixture.count('desired_states');

    for (final command in <DuplicateTaskCommand>[
      DuplicateTaskCommand(
        accountId: fixture.accountId,
        sourceTaskId: const TaskId(999999),
      ),
      DuplicateTaskCommand(
        accountId: fixture.accountId,
        sourceTaskId: sources.leaf,
      ),
      DuplicateTaskCommand(
        accountId: otherAccount,
        sourceTaskId: sources.child,
      ),
    ]) {
      final result = await fixture.tasks.duplicateTask(command);
      expect(
        (result as Failed<TaskDuplicateReceipt>).failure.code,
        'task.not_found',
      );
    }
    expect(await fixture.count('tasks'), tasksBefore);
    expect(await fixture.count('desired_states'), desiredBefore);
  });

  test(
    'a copy title over the field bound is rejected, storing nothing',
    () async {
      final long = await fixture.createTask(sources.list, 'x' * 1020);
      final tasksBefore = await fixture.count('tasks');

      final result = await fixture.duplicate(long);

      expect(
        (result as Failed<TaskDuplicateReceipt>).failure.code,
        'task.title_too_long',
      );
      expect(await fixture.count('tasks'), tasksBefore);
    },
  );

  test('an unpublished source copies under its unpublished parent', () async {
    final localParent = await fixture.createTask(sources.list, 'Local parent');
    final localChild = await fixture.createTask(
      sources.list,
      'Local child',
      parentTaskId: localParent,
    );

    final receipt = await duplicate(localChild);
    final copy = await fixture.task(receipt.taskId);

    expect(copy.parentTaskId, localParent);
    expect(copy.title, 'Local child (copy)');
  });

  test(
    'the copy and its publication intent survive a database reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('axiotask-duplicate-');
      addTearDown(() => root.delete(recursive: true));
      final fileGoogle = FakeGoogleTasksService();
      addTearDown(fileGoogle.close);
      final durable = await DuplicationFixture.open(
        google: fileGoogle,
        file: File('${root.path}/isolated.sqlite'),
      );
      final seeded = await durable.seedSyncedSources();
      final receipt = switch (await durable.duplicate(seeded.child)) {
        Success<TaskDuplicateReceipt>(:final value) => value,
        Failed<TaskDuplicateReceipt>(:final failure) => fail(failure.code),
      };

      await durable.reopen();
      addTearDown(durable.close);

      final copy = await durable.task(receipt.taskId);
      expect(copy.title, 'Milk (copy)');
      expect(copy.parentTaskId, seeded.parent);
      expect(copy.remoteId, isNull);
      expect(
        (await durable.desired.readTask(
          durable.accountId,
          receipt.taskId,
        ))?.state,
        DesiredStateLifecycle.pending,
      );
    },
  );
}
