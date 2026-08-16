import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/mutation.dart';
import 'package:axiotask/src/data/google_tasks/request.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Expected one isolated database path.');
    exitCode = 64;
    return;
  }
  const subject = AccountSubject('synthetic-process-death-subject');
  final database = await AppDatabase.openFile(File(arguments.single));
  final account = AccountId(await database.createAccount(subject.value));
  final engine = SyncEngine(
    store: DatabaseReadSyncStore(database),
    googleTasks: _WorkerReadService(),
    authorization: const SyntheticAuthorization(subject),
    clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
    random: SequenceRandomSource(List<int>.generate(16, (index) => index)),
    control: const _StopAfterCommittedPage(),
  );
  await engine.run(SyncRunRequest(accountId: account));
  await database.close();
}

final class _StopAfterCommittedPage implements SyncRunControl {
  const _StopAfterCommittedPage();

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async {
    if (boundary ==
        const SyncRunBoundary(
          kind: SyncRunBoundaryKind.afterPagePublication,
          scope: 'task_lists',
          pageIndex: 0,
        )) {
      stdout.writeln('PAGE_COMMITTED');
      await stdout.flush();
      await Completer<void>().future;
    }
    return SyncRunControlDecision.proceed;
  }
}

final class _WorkerReadService implements GoogleTasksService {
  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => Outcome<RemotePage<RemoteTaskList>>.success(
    RemotePage<RemoteTaskList>(
      items: <RemoteTaskList>[
        RemoteTaskList(
          id: const RemoteTaskListId('process-list'),
          etag: 'process-etag',
          title: 'Committed process page',
          updated: DateTime.utc(2026, 8, 15, 11),
          selfLink: Uri.parse('https://example.invalid/process-list'),
        ),
      ],
      collectionEtag: 'process-collection-etag',
      nextPageToken: const PageToken('unreached-page'),
    ),
  );

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => Outcome<RemotePage<RemoteTask>>.failure(_unexpectedFailure);

  Never _mutation() => throw StateError('Crash worker issued a mutation.');

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> createTaskList(
    CreateTaskListOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<RemoteTaskList>> renameTaskList(
    RenameTaskListOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<void>> deleteTaskList(
    DeleteTaskListOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> createTask(
    CreateTaskOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> patchTask(
    PatchTaskOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<void>> deleteTask(
    DeleteTaskOperation operation,
  ) async => _mutation();

  @override
  Future<GoogleTasksMutationResult<RemoteTask>> moveTask(
    MoveTaskOperation operation,
  ) async => _mutation();

  @override
  void close() {}
}

const Failure _unexpectedFailure = Failure(
  code: 'synthetic.process_worker_unexpected_read',
  category: FailureCategory.internal,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'The process worker reached an unexpected read.',
  safeSummary: 'Unexpected synthetic worker read.',
);
