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
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'CRS-012 mid-run unreadable storage stops further Google work',
    () async {
      final database = AppDatabase.inMemory();
      final account = AccountId(
        await database.createAccount('synthetic-storage-failure-subject'),
      );
      final google = _TwoPageGoogleService();
      final engine = SyncEngine(
        store: DatabaseReadSyncStore(database),
        googleTasks: google,
        authorization: const SyntheticAuthorization(
          AccountSubject('synthetic-storage-failure-subject'),
        ),
        clock: ManualClock(DateTime.utc(2026, 8, 15, 12)),
        random: SequenceRandomSource(List<int>.generate(32, (index) => index)),
        control: _CloseStorageBeforePublication(database),
      );

      await expectLater(
        engine.run(SyncRunRequest(accountId: account)),
        throwsA(anything),
      );

      expect(google.listCalls, 1);
      expect(google.mutationCalls, 0);
    },
  );
}

final class _CloseStorageBeforePublication implements SyncRunControl {
  _CloseStorageBeforePublication(this.database);

  final AppDatabase database;
  var closed = false;

  @override
  Future<SyncRunControlDecision> reach(SyncRunBoundary boundary) async {
    if (!closed && boundary.kind == SyncRunBoundaryKind.beforePagePublication) {
      closed = true;
      await database.close();
    }
    return SyncRunControlDecision.proceed;
  }
}

final class _TwoPageGoogleService implements GoogleTasksService {
  var listCalls = 0;
  var mutationCalls = 0;

  @override
  Future<Outcome<RemotePage<RemoteTaskList>>> listTaskLists({
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async {
    listCalls += 1;
    return Outcome<RemotePage<RemoteTaskList>>.success(
      RemotePage<RemoteTaskList>(
        items: const <RemoteTaskList>[],
        collectionEtag: null,
        nextPageToken: pageToken == null ? const PageToken('second') : null,
      ),
    );
  }

  @override
  Future<Outcome<RemotePage<RemoteTask>>> listTasks(
    RemoteTaskListId taskListId, {
    PageToken? pageToken,
    GoogleTasksReadCancellation? cancellation,
  }) async => const Outcome<RemotePage<RemoteTask>>.failure(_unexpectedRead);

  Never _mutation() {
    mutationCalls += 1;
    throw StateError('A mutation was attempted with unsafe storage.');
  }

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

const Failure _unexpectedRead = Failure(
  code: 'synthetic.unexpected_task_read',
  category: FailureCategory.internal,
  operation: FailureOperation.read,
  retry: RetryClassification.permanent,
  impact: 'Synthetic only.',
  safeSummary: 'Synthetic only.',
);
