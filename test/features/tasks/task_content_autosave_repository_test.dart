// Inline detail autosave over the real SQLite repository: what the editor
// shows must be what a reopened database holds, including its sync intent.
import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/data/database/app_database.dart';
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/data/database/tasks_repository.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter_test/flutter_test.dart';

const _debounce = TaskContentAutosave.defaultDebounce;

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('axiotask-autosave-');
    file = File('${root.path}/autosave.sqlite');
  });

  tearDown(() => root.delete(recursive: true));

  test(
    'rapid typing, a task switch and Back survive a database reopen',
    () async {
      final session = await _Session.open(file);
      final seeded = await session.seed();
      final autosave = session.model.contentAutosave;

      // Rapid typing in the first task coalesces into one stored title.
      session.model.selectTask(seeded.first);
      autosave.open(session.stored(seeded.first));
      for (var length = 1; length <= 12; length += 1) {
        autosave.edit(
          seeded.first,
          title: 'Typed title!'.substring(0, length),
          notes: 'First notes',
        );
        session.clock.advance(const Duration(milliseconds: 40));
      }
      session.clock.advance(_debounce);
      await session.until(
        () => session.stored(seeded.first).title == 'Typed title!',
      );
      final firstIntent = await session.intent(seeded.first);
      expect(firstIntent?.title, 'Typed title!');
      expect(firstIntent?.generation, 1, reason: 'one write for the burst');
      expect(session.syncWakeUps, 1);

      // Notes typed and left before the debounce: selecting another task
      // stores them for the first task only.
      autosave.edit(
        seeded.first,
        title: 'Typed title!',
        notes: 'Multiline\nnotes ✓',
      );
      session.model.selectTask(seeded.second);
      unawaited(autosave.close(seeded.first));
      await session.until(
        () => session.stored(seeded.first).notes == 'Multiline\nnotes ✓',
      );
      expect(session.stored(seeded.second).notes, isNull);
      expect(session.stored(seeded.second).title, 'Second');

      // Back from the second task stores its edit, as does closing the app.
      autosave.open(session.stored(seeded.second));
      autosave.edit(seeded.second, title: 'Second edited', notes: 'Kept');
      session.model.backFromTaskDetail();
      expect(session.model.state.selectedTaskId, isNull);
      await session.until(
        () => session.stored(seeded.second).title == 'Second edited',
      );
      unawaited(autosave.close(seeded.second));
      await session.close();

      final reopened = await _Session.open(file);
      await reopened.load();
      expect(reopened.stored(seeded.first).title, 'Typed title!');
      expect(reopened.stored(seeded.first).notes, 'Multiline\nnotes ✓');
      expect(reopened.stored(seeded.second).title, 'Second edited');
      expect(reopened.stored(seeded.second).notes, 'Kept');
      for (final id in <TaskId>[seeded.first, seeded.second]) {
        final intent = await reopened.intent(id);
        expect(intent?.state, DesiredStateLifecycle.pending, reason: '$id');
        expect(intent?.status, TaskStatus.needsAction, reason: '$id');
      }
      expect(
        (await reopened.intent(seeded.first))?.due,
        TaskDate(2026, 11, 20),
        reason: 'text saves never change the stored due date',
      );
      await reopened.close();
    },
  );

  test('a failed write keeps the text until a retry stores it', () async {
    final session = await _Session.open(file);
    final seeded = await session.seed();
    final autosave = session.model.contentAutosave;
    session.failWrites = true;

    session.model.selectTask(seeded.first);
    autosave.open(session.stored(seeded.first));
    autosave.edit(seeded.first, title: 'Not yet stored', notes: 'Also new');
    await autosave.flush(seeded.first);

    final failed = autosave.draft(seeded.first)!;
    expect(failed.status, TaskContentSaveStatus.failed);
    expect(failed.failureMessage, 'The task could not be saved safely.');
    expect(failed.title, 'Not yet stored');
    expect(session.stored(seeded.first).title, 'First');
    expect(await session.intent(seeded.first), isNull, reason: 'rolled back');
    expect(session.syncWakeUps, 0);
    expect(
      session.model.state.isTaskCommandPending,
      isFalse,
      reason: 'autosave does not block the other detail actions',
    );

    // Leaving keeps the unsaved draft; returning shows it again.
    session.model.clearTaskSelection();
    await autosave.close(seeded.first);
    session.failWrites = false;
    session.model.selectTask(seeded.first);
    expect(autosave.open(session.stored(seeded.first)).title, 'Not yet stored');
    await autosave.retry(seeded.first);
    await session.until(
      () =>
          session.stored(seeded.first).title == 'Not yet stored' &&
          session.stored(seeded.first).notes == 'Also new',
    );
    expect(autosave.draft(seeded.first)?.status, TaskContentSaveStatus.saved);
    await session.close();

    final reopened = await _Session.open(file);
    await reopened.load();
    expect(reopened.stored(seeded.first).title, 'Not yet stored');
    expect(reopened.stored(seeded.first).notes, 'Also new');
    await reopened.close();
  });

  test('an empty title keeps the stored title while notes save', () async {
    final session = await _Session.open(file);
    final seeded = await session.seed();
    final autosave = session.model.contentAutosave;
    autosave.open(session.stored(seeded.first));
    autosave.edit(seeded.first, title: '', notes: 'Notes without a title');
    session.clock.advance(_debounce);
    await session.until(
      () => session.stored(seeded.first).notes == 'Notes without a title',
    );
    expect(session.stored(seeded.first).title, 'First');
    expect(autosave.draft(seeded.first)?.titleRejected, isTrue);
    await autosave.close(seeded.first);
    await session.close();

    final reopened = await _Session.open(file);
    await reopened.load();
    expect(reopened.stored(seeded.first).title, 'First');
    expect(reopened.stored(seeded.first).notes, 'Notes without a title');
    await reopened.close();
  });

  test('viewing a padded-title task stores and publishes nothing', () async {
    final session = await _Session.open(file);
    final seeded = await session.seed(firstTitle: '  Padded title ');
    final autosave = session.model.contentAutosave;

    session.model.selectTask(seeded.first);
    final draft = autosave.open(session.stored(seeded.first));
    expect(draft.status, TaskContentSaveStatus.saved);
    expect(draft.titleRejected, isFalse);
    autosave.edit(seeded.first, title: '  Padded title ', notes: 'First notes');
    session.clock.advance(_debounce * 2);
    session.model.selectTask(seeded.second);
    await autosave.close(seeded.first);
    session.model.backFromTaskDetail();
    await session.close();

    final reopened = await _Session.open(file);
    await reopened.load();
    expect(reopened.stored(seeded.first).title, '  Padded title ');
    expect(await reopened.intent(seeded.first), isNull);
    expect(session.syncWakeUps, 0);
    await reopened.close();
  });

  test('a completion during a pending text save is not reverted', () async {
    final session = await _Session.open(file);
    final seeded = await session.seed();
    final autosave = session.model.contentAutosave;
    session.model.selectTask(seeded.first);
    autosave.open(session.stored(seeded.first));
    autosave.edit(seeded.first, title: 'Renamed', notes: 'First notes');
    await session.model.setTaskCompletion(seeded.first, TaskStatus.completed);
    session.clock.advance(_debounce);
    await session.until(() => session.stored(seeded.first).title == 'Renamed');
    expect(session.stored(seeded.first).status, TaskStatus.completed);
    expect(session.stored(seeded.first).due, TaskDate(2026, 11, 20));
    await autosave.close(seeded.first);
    await session.close();
  });
}

final class _Seeded {
  const _Seeded(this.first, this.second);

  final TaskId first;
  final TaskId second;
}

final class _Session {
  _Session._(this.database, this.clock);

  final AppDatabase database;
  final ManualClock clock;
  late final TasksViewModel model;
  late AccountId account;
  var failWrites = false;
  var syncWakeUps = 0;

  static Future<_Session> open(File file) async {
    final session = _Session._(
      await AppDatabase.openFile(file),
      ManualClock(DateTime.utc(2026, 11, 17, 12)),
    );
    session.model = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: DatabaseTasksRepository(
        session.database,
        clock: session.clock,
        transactionControl: (boundary) {
          if (session.failWrites &&
              boundary == DesiredStateTransactionBoundary.beforeLocalCommit) {
            throw const DesiredStatePersistenceException('synthetic_failure');
          }
        },
      ),
      syncHealthRepository: const _Health(),
      clock: session.clock,
      localEditCommitted: () async => session.syncWakeUps += 1,
    );
    session.account = const AccountId(1);
    return session;
  }

  Future<_Seeded> seed({String firstTitle = 'First'}) async {
    account = AccountId(await database.createAccount('synthetic-autosave'));
    expect(account, const AccountId(1));
    final cache = CacheDao(database);
    final list = await cache.putTaskList(
      accountId: account,
      remoteId: const TaskListRemoteId('autosave-list'),
      title: 'Autosave list',
    );
    final first = await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('autosave-first'),
      title: firstTitle,
      notes: 'First notes',
      position: '1',
      due: TaskDate(2026, 11, 20),
    );
    final second = await cache.putTask(
      accountId: account,
      taskListId: list,
      remoteId: const TaskRemoteId('autosave-second'),
      title: 'Second',
      position: '2',
    );
    await load();
    return _Seeded(first, second);
  }

  Future<void> load() async {
    model.start();
    await until(() => !model.state.isLoading && model.state.tasks.isNotEmpty);
  }

  CachedTask stored(TaskId id) =>
      model.state.tasks.singleWhere((task) => task.id == id);

  Future<TaskDesiredStateRecord?> intent(TaskId id) =>
      DesiredStateDao(database).readTask(account, id);

  Future<void> until(bool Function() condition) async {
    for (var attempt = 0; attempt < 500; attempt += 1) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('condition not reached');
  }

  Future<void> close() async {
    await model.flushPendingEdits();
    model.dispose();
    await database.close();
  }
}

final class _Health implements SyncHealthRepository {
  const _Health();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.pending,
      pendingReason: SyncPendingReason.verifying,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: null,
      evaluatedAt: DateTime.utc(2026, 11, 17, 12),
    ),
  );
}
