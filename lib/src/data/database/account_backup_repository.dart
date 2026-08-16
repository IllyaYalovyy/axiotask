import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/clock.dart';
import '../../domain/backup/account_backup.dart';
import '../../domain/model/tasks.dart';
import '../../domain/repository/account_backup_repository.dart';
import '../preferences/relational_preferences.dart';
import 'app_database.dart';
import 'cache_dao.dart';
import 'desired_state_dao.dart';
import 'tasks_repository.dart';

enum AccountBackupImportTransactionBoundary {
  afterListProjection,
  afterTaskProjection,
  beforeManifest,
  beforeCommit,
}

typedef AccountBackupImportTransactionControl =
    Future<void> Function(AccountBackupImportTransactionBoundary boundary);

final class DatabaseAccountBackupRepository
    implements AccountBackupRepository, AccountBackupRestoreRepository {
  DatabaseAccountBackupRepository(
    this._database, {
    Clock? clock,
    this.transactionControl,
  }) : clock = clock ?? SystemClock(),
       _cache = CacheDao(_database),
       _desired = DesiredStateDao(_database);

  final AppDatabase _database;
  final Clock clock;
  final AccountBackupImportTransactionControl? transactionControl;
  final CacheDao _cache;
  final DesiredStateDao _desired;

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

  @override
  Future<AccountBackupImportPreview> previewImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) => _database.transaction(() async {
    final digest = const AccountBackupCodec().fingerprint(document);
    final manifest = await _manifest(accountId, digest);
    if (manifest != null) {
      return _previewFromManifest(document, manifest);
    }
    await _requireFresh(
      accountId,
      readiness: readiness,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt,
    );
    final plan = await _plan(accountId, document);
    return _preview(document, digest, plan);
  });

  @override
  Future<AccountBackupImportResult> restoreImport({
    required AccountId accountId,
    required AccountBackupDocument document,
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async {
    try {
      return await _database.transaction(() async {
        final codec = const AccountBackupCodec();
        final digest = codec.fingerprint(document);
        final prior = await _manifest(accountId, digest);
        if (prior != null) return _resultFromManifest(prior, true);
        await _requireFresh(
          accountId,
          readiness: readiness,
          lastSuccessfulSyncAt: lastSuccessfulSyncAt,
        );
        final plan = await _plan(accountId, document);
        final modifiedAt = clock.now().toUtc();
        final listIds = <String, TaskListId>{...plan.existingLists};
        for (final list in plan.listsToCreate) {
          final id = await _cache.putTaskList(
            accountId: accountId,
            remoteId: null,
            title: list.title,
          );
          listIds[list.key] = id;
          await _desired.writeTaskListPresent(
            accountId: accountId,
            taskListId: id,
            title: list.title,
            modifiedAt: modifiedAt,
            recomputeCounts: false,
          );
        }
        await _reach(
          AccountBackupImportTransactionBoundary.afterListProjection,
        );

        final taskIds = <String, TaskId>{...plan.existingTasks};
        final targetTasks = await _targetTasks(accountId);
        final documentTasks = <String, AccountBackupTask>{
          for (final task in document.tasks) task.key: task,
        };
        final ordered = <AccountBackupTask>[
          ...plan.tasksToCreate.where((task) => task.parentKey == null),
          ...plan.tasksToCreate.where((task) => task.parentKey != null),
        ];
        for (final task in ordered) {
          final parentId = task.parentKey == null
              ? null
              : taskIds[task.parentKey!];
          if (task.parentKey != null && parentId == null) {
            throw const AccountBackupImportException('parent_not_resolved');
          }
          TaskListId? listId = listIds[task.listKey];
          if (parentId != null) {
            final parent =
                targetTasks[parentId] ?? await _targetTask(accountId, parentId);
            if (parent == null || parent.parentKey != null) {
              throw const AccountBackupImportException('parent_not_supported');
            }
            listId = parent.listKey;
          }
          if (listId == null) {
            throw const AccountBackupImportException('list_not_resolved');
          }
          final previousDocumentTask = document.tasks
              .where(
                (candidate) =>
                    candidate.listKey == task.listKey &&
                    candidate.parentKey == task.parentKey &&
                    candidate.order == task.order - 1,
              )
              .firstOrNull;
          TaskId? previousId = previousDocumentTask == null
              ? null
              : taskIds[previousDocumentTask.key];
          if (previousId != null) {
            final previous =
                targetTasks[previousId] ??
                await _targetTask(accountId, previousId);
            if (previous == null ||
                previous.listKey != listId ||
                previous.parentKey != parentId) {
              previousId = null;
            }
          }
          final id = await _cache.putTask(
            accountId: accountId,
            taskListId: listId,
            parentTaskId: parentId,
            remoteId: null,
            title: task.title,
            notes: task.notes,
            status: task.status,
            due: task.due,
            position: 'local-pending',
          );
          taskIds[task.key] = id;
          targetTasks[id] = AccountBackupTargetTask(
            key: id,
            googleId: null,
            listKey: listId,
            parentKey: parentId,
          );
          await _desired.writeTaskPresent(
            accountId: accountId,
            taskId: id,
            taskListId: listId,
            parentTaskId: parentId,
            previousTaskId: previousId,
            title: task.title,
            notes: task.notes,
            status: task.status,
            due: task.due,
            modifiedAt: modifiedAt,
            recomputeCounts: false,
          );
          // Ensure a malformed ordering cannot silently refer to a missing row.
          if (task.parentKey != null &&
              !documentTasks.containsKey(task.parentKey)) {
            throw const AccountBackupImportException('parent_not_in_document');
          }
        }
        await _reach(
          AccountBackupImportTransactionBoundary.afterTaskProjection,
        );
        await _desired.recomputeCounts(accountId);
        await _reach(AccountBackupImportTransactionBoundary.beforeManifest);
        await _database
            .into(_database.accountBackupImportManifestRows)
            .insert(
              AccountBackupImportManifestRowsCompanion.insert(
                accountId: accountId.value,
                documentDigest: digest,
                sourceGoogleSubject: document.sourceGoogleSubject,
                sourceAccountMatches: plan.sourceAccountMatches,
                exportedAt: document.exportedAt.toUtc(),
                createdListCount: plan.listsToCreate.length,
                existingListCount: plan.existingListCount,
                createdTaskCount: plan.tasksToCreate.length,
                existingTaskCount: plan.existingTaskCount,
                importedAt: modifiedAt,
              ),
            );
        await _reach(AccountBackupImportTransactionBoundary.beforeCommit);
        return AccountBackupImportResult(
          createdListCount: plan.listsToCreate.length,
          existingListCount: plan.existingListCount,
          createdTaskCount: plan.tasksToCreate.length,
          existingTaskCount: plan.existingTaskCount,
          alreadyImported: false,
        );
      });
    } on AccountBackupImportException {
      rethrow;
    } on DesiredStatePersistenceException {
      throw const AccountBackupImportException('persistence_failed');
    } on CacheInvariantException {
      throw const AccountBackupImportException('persistence_failed');
    } on SqliteException {
      throw const AccountBackupImportException('persistence_failed');
    }
  }

  Future<AccountBackupImportPlan> _plan(
    AccountId accountId,
    AccountBackupDocument document,
  ) async {
    final account = await (_database.select(
      _database.accounts,
    )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
    if (account == null) {
      throw const AccountBackupImportException('account_not_found');
    }
    final lists =
        await (_database.select(_database.taskListCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.projection.equals('supported'),
            ))
            .get();
    final tasks = await _targetTasks(accountId);
    return const AccountBackupImportPlanner().plan(
      document: document,
      target: AccountBackupImportTarget(
        googleSubject: account.googleSubject,
        lists: lists
            .map(
              (row) => AccountBackupTargetList(
                key: TaskListId(row.id),
                googleId: row.remoteId,
              ),
            )
            .toList(growable: false),
        tasks: tasks.values.toList(growable: false),
      ),
    );
  }

  Future<Map<TaskId, AccountBackupTargetTask>> _targetTasks(
    AccountId accountId,
  ) async {
    final rows =
        await (_database.select(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.projection.equals('supported'),
            ))
            .get();
    return <TaskId, AccountBackupTargetTask>{
      for (final row in rows)
        TaskId(row.id): AccountBackupTargetTask(
          key: TaskId(row.id),
          googleId: row.remoteId,
          listKey: TaskListId(row.taskListId),
          parentKey: row.parentTaskId == null
              ? null
              : TaskId(row.parentTaskId!),
        ),
    };
  }

  Future<AccountBackupTargetTask?> _targetTask(
    AccountId accountId,
    TaskId taskId,
  ) async {
    final row =
        await (_database.select(_database.taskCacheRows)..where(
              (row) =>
                  row.accountId.equals(accountId.value) &
                  row.id.equals(taskId.value) &
                  row.projection.equals('supported'),
            ))
            .getSingleOrNull();
    return row == null
        ? null
        : AccountBackupTargetTask(
            key: TaskId(row.id),
            googleId: row.remoteId,
            listKey: TaskListId(row.taskListId),
            parentKey: row.parentTaskId == null
                ? null
                : TaskId(row.parentTaskId!),
          );
  }

  Future<void> _requireFresh(
    AccountId accountId, {
    required AccountBackupImportReadiness readiness,
    required DateTime? lastSuccessfulSyncAt,
  }) async {
    if (readiness != AccountBackupImportReadiness.ready) {
      throw AccountBackupImportException('not_fresh_${readiness.name}');
    }
    final preference = await (_database.select(
      _database.accountPreferenceRows,
    )..where((row) => row.accountId.equals(accountId.value))).getSingleOrNull();
    final facts = await (_database.select(
      _database.syncFactRows,
    )..where((row) => row.accountId.equals(accountId.value))).getSingleOrNull();
    final durableSuccess = facts?.lastSuccessfulSyncAt?.toUtc();
    final failureIsCurrent =
        facts?.latestFailureAt != null &&
        (durableSuccess == null ||
            !facts!.latestFailureAt!.toUtc().isBefore(durableSuccess));
    if (preference?.syncEnabled != true ||
        facts == null ||
        lastSuccessfulSyncAt == null ||
        durableSuccess != lastSuccessfulSyncAt.toUtc() ||
        failureIsCurrent ||
        facts.pendingCount != 0 ||
        facts.inFlightCount != 0 ||
        facts.uncertainCount != 0 ||
        facts.failedCount != 0 ||
        facts.requiredScopeIncomplete ||
        facts.followUpRequired ||
        facts.reauthorizationRequired ||
        facts.retryWaiting ||
        facts.automaticRetryExhausted) {
      throw const AccountBackupImportException('freshness_changed');
    }
  }

  Future<AccountBackupImportManifestRow?> _manifest(
    AccountId accountId,
    String digest,
  ) =>
      (_database.select(_database.accountBackupImportManifestRows)..where(
            (row) =>
                row.accountId.equals(accountId.value) &
                row.documentDigest.equals(digest),
          ))
          .getSingleOrNull();

  Future<void> _reach(AccountBackupImportTransactionBoundary boundary) async {
    await transactionControl?.call(boundary);
  }
}

AccountBackupImportPreview _preview(
  AccountBackupDocument document,
  String digest,
  AccountBackupImportPlan plan,
) => AccountBackupImportPreview(
  documentDigest: digest,
  sourceAccountMatches: plan.sourceAccountMatches,
  listCount: document.lists.length,
  taskCount: document.tasks.length,
  listsToCreate: plan.listsToCreate.length,
  tasksToCreate: plan.tasksToCreate.length,
  existingListCount: plan.existingListCount,
  existingTaskCount: plan.existingTaskCount,
  alreadyImported: false,
);

AccountBackupImportPreview _previewFromManifest(
  AccountBackupDocument document,
  AccountBackupImportManifestRow manifest,
) => AccountBackupImportPreview(
  documentDigest: manifest.documentDigest,
  sourceAccountMatches: manifest.sourceAccountMatches,
  listCount: document.lists.length,
  taskCount: document.tasks.length,
  listsToCreate: manifest.createdListCount,
  tasksToCreate: manifest.createdTaskCount,
  existingListCount: manifest.existingListCount,
  existingTaskCount: manifest.existingTaskCount,
  alreadyImported: true,
);

AccountBackupImportResult _resultFromManifest(
  AccountBackupImportManifestRow manifest,
  bool alreadyImported,
) => AccountBackupImportResult(
  createdListCount: manifest.createdListCount,
  existingListCount: manifest.existingListCount,
  createdTaskCount: manifest.createdTaskCount,
  existingTaskCount: manifest.existingTaskCount,
  alreadyImported: alreadyImported,
);

String _key(String prefix, int value) =>
    '$prefix-${value.toString().padLeft(6, '0')}';
