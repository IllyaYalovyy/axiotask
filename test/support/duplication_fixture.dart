import 'dart:io';

import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/core/randomness.dart';
import 'package:axiotask/src/data/auth/authorization.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/read_sync_store.dart';
import 'package:axiotask/src/data/database/task_lists_repository.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/data/google_tasks/dto.dart';
import 'package:axiotask/src/data/google_tasks/service.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/commands/task_list_commands.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/sync/engine.dart';
import 'package:axiotask/src/sync/run.dart';
import 'package:drift/drift.dart' show Variable;

import 'fake_clock.dart';
import 'fake_google_tasks_service.dart';

/// One isolated account over a real SQLite store and a synthetic Google Tasks
/// account, for exercising Duplicate through the repository and sync engine.
///
/// [seedSyncedSources] publishes a parent (with notes, a due date and two
/// subtasks, one completed) and a completed leaf, so a duplicate can be taken
/// from tasks that carry real remote IDs, ETags and remote bases.
final class DuplicationFixture {
  DuplicationFixture._({
    required this.database,
    required this.accountId,
    required this.clock,
    required this.google,
    required this.subject,
    required this.file,
    required this.ledger,
  });

  static const defaultSubject = AccountSubject('synthetic-duplicate-subject');

  /// Opens the store in [file] when given (so a test can close and reopen
  /// it), else in memory.
  ///
  /// [ledger] is the synthetic account whose calls are observed when
  /// [google] wraps it; it defaults to [google] itself.
  static Future<DuplicationFixture> open({
    required GoogleTasksService google,
    FakeGoogleTasksService? ledger,
    File? file,
    AccountSubject subject = defaultSubject,
  }) async {
    final database = file == null
        ? AppDatabase.inMemory()
        : await AppDatabase.openFile(file);
    final accountId = AccountId(await database.createAccount(subject.value));
    return DuplicationFixture._(
      database: database,
      accountId: accountId,
      clock: FakeClock(DateTime.utc(2026, 11, 15, 12)),
      google: google,
      subject: subject,
      file: file,
      ledger: ledger ?? (google is FakeGoogleTasksService ? google : null),
    );
  }

  AppDatabase database;
  final AccountId accountId;
  final FakeClock clock;
  final GoogleTasksService google;
  final AccountSubject subject;
  final File? file;
  final FakeGoogleTasksService? ledger;

  DatabaseTasksRepository get tasks =>
      DatabaseTasksRepository(database, clock: clock);

  DesiredStateDao get desired => DesiredStateDao(database);

  /// Closes and reopens the file-backed store, as a process restart would.
  Future<void> reopen() async {
    await database.close();
    database = await AppDatabase.openFile(file!);
  }

  Future<void> close() => database.close();

  Future<SyncRunReport> sync({
    SyncRunControl control = const NoopSyncRunControl(),
  }) {
    clock.advance(const Duration(minutes: 1));
    return SyncEngine(
      store: DatabaseReadSyncStore(database),
      googleTasks: google,
      authorization: SyntheticAuthorization(subject),
      clock: clock,
      random: SequenceRandomSource(
        List<int>.generate(256, (index) => index % 256),
      ),
      control: control,
    ).run(SyncRunRequest(accountId: accountId));
  }

  Future<TaskListId> createList(String title) async => _value(
    await DatabaseTaskListsRepository(
      database: database,
      clock: clock,
    ).createTaskList(CreateTaskListCommand(accountId: accountId, title: title)),
  );

  Future<TaskId> createTask(
    TaskListId taskListId,
    String title, {
    TaskId? parentTaskId,
    String? notes,
    TaskDate? due,
  }) async => _value(
    await tasks.createTask(
      CreateTaskCommand(
        accountId: accountId,
        taskListId: taskListId,
        parentTaskId: parentTaskId,
        title: title,
        notes: notes,
        due: due,
      ),
    ),
  );

  Future<void> complete(TaskId taskId) async => _value(
    await tasks.apply(
      SetTaskCompletionCommand(
        accountId: accountId,
        taskId: taskId,
        status: TaskStatus.completed,
      ),
    ),
  );

  Future<Outcome<TaskDuplicateReceipt>> duplicate(TaskId source) =>
      tasks.duplicateTask(
        DuplicateTaskCommand(accountId: accountId, sourceTaskId: source),
      );

  Future<CachedTasksSnapshot> snapshot() =>
      tasks.watchTasks(TasksQuery(accountId: accountId)).first;

  Future<CachedTask> task(TaskId id) async =>
      (await snapshot()).tasks.singleWhere((task) => task.id == id);

  /// Every stored column of [taskId]'s projection row, remote base and
  /// desired state, for proving that Duplicate leaves the source untouched.
  Future<Map<String, Object?>> storedSource(TaskId taskId) async {
    Future<List<Map<String, Object?>>> rows(String sql) async => [
      for (final row
          in await database
              .customSelect(sql, variables: [Variable<int>(taskId.value)])
              .get())
        Map<String, Object?>.of(row.data),
    ];
    return <String, Object?>{
      'tasks': await rows('SELECT * FROM tasks WHERE id = ?'),
      'task_remote_bases': await rows(
        'SELECT * FROM task_remote_bases WHERE task_id = ?',
      ),
      'desired_states': await rows(
        'SELECT * FROM desired_states WHERE target_task_id = ?',
      ),
    };
  }

  Future<int> count(String table) async =>
      (await database
              .customSelect('SELECT COUNT(*) AS c FROM $table')
              .getSingle())
          .read<int>('c');

  /// Runs sync until a run sends Google no mutation, so later assertions
  /// see only the mutations a test's own action caused.
  Future<void> settle() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final before = _mutationCount();
      final report = await sync();
      if (report.outcome != SyncRunOutcome.succeeded) {
        throw StateError('Seed sync failed: ${report.failure?.code}');
      }
      if (_mutationCount() == before) return;
    }
    throw StateError('Seed sync did not settle.');
  }

  int _mutationCount() {
    final fake = ledger;
    if (fake == null) throw StateError('No synthetic ledger to settle.');
    return fake.calls
        .where(
          (call) => !const <FakeGoogleTasksMethod>{
            FakeGoogleTasksMethod.listTaskLists,
            FakeGoogleTasksMethod.getTaskList,
            FakeGoogleTasksMethod.listTasks,
          }.contains(call.operation),
        )
        .length;
  }

  /// Publishes the synced sources described on [DuplicationFixture].
  Future<SyncedSources> seedSyncedSources() async {
    final list = await createList('Duplicate list');
    final parent = await createTask(
      list,
      'Groceries',
      notes: 'Parent notes',
      due: TaskDate(2026, 11, 20),
    );
    final child = await createTask(
      list,
      'Milk',
      parentTaskId: parent,
      notes: 'Child notes',
      due: TaskDate(2026, 11, 18),
    );
    final completedChild = await createTask(
      list,
      'Bread',
      parentTaskId: parent,
    );
    final leaf = await createTask(
      list,
      'Call plumber',
      notes: 'Leaf notes',
      due: TaskDate(2026, 11, 16),
    );
    final first = await sync();
    if (first.outcome != SyncRunOutcome.succeeded) {
      throw StateError('Seed publication failed: ${first.failure?.code}');
    }
    await complete(completedChild);
    await complete(leaf);
    await settle();
    return SyncedSources(
      list: list,
      parent: parent,
      child: child,
      completedChild: completedChild,
      leaf: leaf,
    );
  }
}

final class SyncedSources {
  const SyncedSources({
    required this.list,
    required this.parent,
    required this.child,
    required this.completedChild,
    required this.leaf,
  });

  final TaskListId list;
  final TaskId parent;
  final TaskId child;
  final TaskId completedChild;
  final TaskId leaf;
}

/// Every live task Google holds in [list], following pagination.
Future<List<RemoteLiveTask>> remoteTasks(
  GoogleTasksService google,
  RemoteTaskListId list,
) async {
  final tasks = <RemoteLiveTask>[];
  PageToken? token;
  do {
    final page = switch (await google.listTasks(list, pageToken: token)) {
      Success<RemotePage<RemoteTask>>(:final value) => value,
      Failed<RemotePage<RemoteTask>>(:final failure) => throw StateError(
        failure.code,
      ),
    };
    tasks.addAll(page.items.whereType<RemoteLiveTask>());
    token = page.nextPageToken;
  } while (token != null);
  return tasks;
}

T _value<T>(Outcome<T> outcome) => switch (outcome) {
  Success<T>(:final value) => value,
  Failed<T>(:final failure) => throw StateError(failure.code),
};
