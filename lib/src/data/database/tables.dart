// Drift check expressions intentionally refer to the column getter being
// declared; the analyzer's recursive-getter lint does not understand this DSL.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get googleSubject =>
      text().unique().check(googleSubject.length.isBiggerThanValue(0))();
}

class TaskListCacheRows extends Table {
  @override
  String get tableName => 'task_lists';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  TextColumn get remoteId => text().nullable().check(
    remoteId.isNull() | remoteId.length.isBiggerThanValue(0),
  )();

  TextColumn get title => text()();

  TextColumn get projection => text().check(
    projection.isIn(const <String>['supported', 'deleted', 'unsupported']),
  )();

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
  ];

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, id},
    {accountId, remoteId},
  ];
}

class TaskCacheRows extends Table {
  @override
  String get tableName => 'tasks';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get taskListId => integer()();

  IntColumn get parentTaskId => integer().nullable()();

  TextColumn get remoteId => text().nullable().check(
    remoteId.isNull() | remoteId.length.isBiggerThanValue(0),
  )();

  TextColumn get title => text()();

  TextColumn get notes => text().nullable()();

  TextColumn get status =>
      text().check(status.isIn(const <String>['needs_action', 'completed']))();

  IntColumn get dueEpochDay => integer().nullable()();

  TextColumn get position =>
      text().check(position.length.isBiggerThanValue(0))();

  TextColumn get projection => text().check(
    projection.isIn(const <String>['supported', 'deleted', 'unsupported']),
  )();

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_list_id, parent_task_id) '
        'REFERENCES tasks(account_id, task_list_id, id) ON DELETE CASCADE',
  ];

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, id},
    {accountId, remoteId},
    {accountId, taskListId, id},
  ];
}

class TaskListRemoteBases extends Table {
  IntColumn get accountId => integer()();

  IntColumn get taskListId => integer()();

  TextColumn get remoteId =>
      text().check(remoteId.length.isBiggerThanValue(0))();

  TextColumn get title => text()();

  TextColumn get etag => text().nullable().check(
    etag.isNull() | etag.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get remoteUpdatedAt => dateTime().nullable()();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  TextColumn get observedPublicationId =>
      text().check(observedPublicationId.length.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId, taskListId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id) ON DELETE CASCADE',
    'UNIQUE (account_id, remote_id)',
  ];
}

class TaskRemoteBases extends Table {
  IntColumn get accountId => integer()();

  IntColumn get taskId => integer()();

  IntColumn get taskListId => integer()();

  IntColumn get parentTaskId => integer().nullable()();

  TextColumn get remoteId =>
      text().check(remoteId.length.isBiggerThanValue(0))();

  TextColumn get title => text().nullable()();

  TextColumn get notes => text().nullable()();

  TextColumn get status => text().nullable().check(
    status.isNull() | status.isIn(const <String>['needs_action', 'completed']),
  )();

  IntColumn get dueEpochDay => integer().nullable()();

  TextColumn get position => text().nullable().check(
    position.isNull() | position.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get completedAt => dateTime().nullable()();

  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  TextColumn get etag => text().nullable().check(
    etag.isNull() | etag.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get remoteUpdatedAt => dateTime().nullable()();

  TextColumn get selfLink => text().nullable()();

  TextColumn get linksJson => text().withDefault(const Constant('[]'))();

  TextColumn get webViewLink => text().nullable()();

  TextColumn get observedPublicationId =>
      text().check(observedPublicationId.length.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId, taskId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id)',
    'FOREIGN KEY (account_id, parent_task_id) '
        'REFERENCES tasks(account_id, id)',
    'UNIQUE (account_id, remote_id)',
    'CHECK (deleted = 1 OR (title IS NOT NULL AND status IS NOT NULL '
        'AND position IS NOT NULL))',
  ];
}

class ScopeCompletenessRows extends Table {
  @override
  String get tableName => 'scope_completeness';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  TextColumn get scopeKind =>
      text().check(scopeKind.isIn(const <String>['task_lists', 'tasks']))();

  TextColumn get scopeKey =>
      text().check(scopeKey.length.isBiggerThanValue(0))();

  IntColumn get taskListId => integer().nullable()();

  TextColumn get publicationId =>
      text().check(publicationId.length.isBiggerThanValue(0))();

  TextColumn get nextPageToken => text().nullable().check(
    nextPageToken.isNull() | nextPageToken.length.isBiggerThanValue(0),
  )();

  TextColumn get collectionEtag => text().nullable().check(
    collectionEtag.isNull() | collectionEtag.length.isBiggerThanValue(0),
  )();

  BoolColumn get isComplete => boolean().withDefault(const Constant(false))();

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id) ON DELETE CASCADE',
    'UNIQUE (account_id, scope_key)',
    "CHECK ((scope_kind = 'task_lists' AND scope_key = 'task_lists' "
        "AND task_list_id IS NULL) OR (scope_kind = 'tasks' "
        "AND scope_key = 'tasks:' || task_list_id "
        'AND task_list_id IS NOT NULL))',
    'CHECK (is_complete = 0 OR next_page_token IS NULL)',
  ];
}

class AccountPreferenceRows extends Table {
  @override
  String get tableName => 'account_preferences';

  IntColumn get accountId => integer()();

  BoolColumn get syncEnabled => boolean().withDefault(const Constant(true))();

  IntColumn get defaultTaskListId => integer().nullable()();

  IntColumn get nextLocalCausalSequence => integer()
      .withDefault(const Constant(1))
      .check(nextLocalCausalSequence.isBiggerThanValue(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, default_task_list_id) '
        'REFERENCES task_lists(account_id, id)',
  ];
}

class DesiredStateRows extends Table {
  @override
  String get tableName => 'desired_states';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  TextColumn get targetKey =>
      text().check(targetKey.length.isBiggerThanValue(0))();

  TextColumn get resourceType =>
      text().check(resourceType.isIn(const <String>['task_list', 'task']))();

  IntColumn get targetTaskListId => integer().nullable()();

  IntColumn get targetTaskId => integer().nullable()();

  TextColumn get desiredLifecycle => text().check(
    desiredLifecycle.isIn(const <String>['present', 'deleted']),
  )();

  TextColumn get title => text().nullable()();

  TextColumn get notes => text().nullable()();

  TextColumn get status => text().nullable().check(
    status.isNull() | status.isIn(const <String>['needs_action', 'completed']),
  )();

  IntColumn get dueEpochDay => integer().nullable()();

  IntColumn get desiredTaskListId => integer().nullable()();

  IntColumn get desiredParentTaskId => integer().nullable()();

  IntColumn get desiredPreviousTaskId => integer().nullable()();

  BoolColumn get contentDirty => boolean().withDefault(const Constant(false))();

  BoolColumn get structureDirty =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get lifecycleDirty =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get localModifiedAt => dateTime().nullable()();

  DateTimeColumn get notBefore => dateTime().nullable()();

  IntColumn get generation =>
      integer().check(generation.isBiggerThanValue(0))();

  IntColumn get localCausalSequence =>
      integer().check(localCausalSequence.isBiggerThanValue(0))();

  TextColumn get state => text().check(
    state.isIn(const <String>[
      'pending',
      'in_flight',
      'uncertain',
      'failed',
      'confirmed',
      'superseded',
    ]),
  )();

  TextColumn get baseRemoteId => text().nullable().check(
    baseRemoteId.isNull() | baseRemoteId.length.isBiggerThanValue(0),
  )();

  TextColumn get baseEtag => text().nullable().check(
    baseEtag.isNull() | baseEtag.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get baseRemoteUpdatedAt => dateTime().nullable()();

  TextColumn get baseObservedPublicationId => text().nullable().check(
    baseObservedPublicationId.isNull() |
        baseObservedPublicationId.length.isBiggerThanValue(0),
  )();

  TextColumn get baseTitle => text().nullable()();

  TextColumn get baseNotes => text().nullable()();

  TextColumn get baseStatus => text().nullable().check(
    baseStatus.isNull() |
        baseStatus.isIn(const <String>['needs_action', 'completed']),
  )();

  IntColumn get baseDueEpochDay => integer().nullable()();

  IntColumn get baseTaskListId => integer().nullable()();

  IntColumn get baseParentTaskId => integer().nullable()();

  IntColumn get basePreviousTaskId => integer().nullable()();

  TextColumn get basePosition => text().nullable().check(
    basePosition.isNull() | basePosition.length.isBiggerThanValue(0),
  )();

  TextColumn get baseSiblingOrder => text().nullable().check(
    baseSiblingOrder.isNull() | baseSiblingOrder.length.isBiggerThanValue(0),
  )();

  TextColumn get failureCode => text().nullable().check(
    failureCode.isNull() | failureCode.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get lastTransitionAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, id},
    <Column<Object>>{accountId, targetKey},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, target_task_list_id) '
        'REFERENCES task_lists(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, target_task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, desired_task_list_id) '
        'REFERENCES task_lists(account_id, id)',
    'FOREIGN KEY (account_id, desired_parent_task_id) '
        'REFERENCES tasks(account_id, id)',
    'FOREIGN KEY (account_id, desired_previous_task_id) '
        'REFERENCES tasks(account_id, id)',
    'FOREIGN KEY (account_id, base_task_list_id) '
        'REFERENCES task_lists(account_id, id)',
    'FOREIGN KEY (account_id, base_parent_task_id) '
        'REFERENCES tasks(account_id, id)',
    'FOREIGN KEY (account_id, base_previous_task_id) '
        'REFERENCES tasks(account_id, id)',
    "CHECK ((resource_type = 'task_list' "
        "AND target_key = 'task_list:' || target_task_list_id "
        'AND target_task_list_id IS NOT NULL AND target_task_id IS NULL) OR '
        "(resource_type = 'task' AND target_key = 'task:' || target_task_id "
        'AND target_task_list_id IS NULL AND target_task_id IS NOT NULL))',
    "CHECK (desired_lifecycle = 'deleted' OR title IS NOT NULL)",
    'CHECK (content_dirty = 1 OR structure_dirty = 1 OR lifecycle_dirty = 1)',
  ];
}

class TaskDeleteGroupRows extends Table {
  @override
  String get tableName => 'task_delete_groups';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get selectedCount =>
      integer().check(selectedCount.isBiggerThanValue(0))();

  IntColumn get rootCount => integer().check(rootCount.isBiggerThanValue(0))();

  IntColumn get snapshotCount =>
      integer().check(snapshotCount.isBiggerThanValue(0))();

  DateTimeColumn get notBefore => dateTime()();

  BoolColumn get snapshotAvailable => boolean()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, id},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'CHECK (root_count <= selected_count)',
    'CHECK (root_count <= snapshot_count)',
  ];
}

class TaskDeleteTombstoneRows extends Table {
  @override
  String get tableName => 'task_delete_tombstones';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get rootTaskId => integer()();

  IntColumn get groupId => integer().nullable()();

  IntColumn get desiredStateId => integer()();

  IntColumn get deleteGeneration => integer()();

  DateTimeColumn get notBefore => dateTime()();

  BoolColumn get snapshotAvailable => boolean()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, id},
    <Column<Object>>{accountId, rootTaskId},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, root_task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, group_id) '
        'REFERENCES task_delete_groups(account_id, id)',
    'FOREIGN KEY (account_id, desired_state_id) '
        'REFERENCES desired_states(account_id, id) ON DELETE CASCADE',
  ];
}

class TaskDeleteSnapshotRows extends Table {
  @override
  String get tableName => 'task_delete_snapshots';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get tombstoneId => integer()();

  IntColumn get taskId => integer()();

  IntColumn get taskListId => integer()();

  IntColumn get parentTaskId => integer().nullable()();

  TextColumn get remoteId => text().nullable()();

  TextColumn get title => text()();

  TextColumn get notes => text().nullable()();

  TextColumn get status =>
      text().check(status.isIn(const <String>['needs_action', 'completed']))();

  IntColumn get dueEpochDay => integer().nullable()();

  TextColumn get position => text()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, tombstoneId, taskId},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, tombstone_id) '
        'REFERENCES task_delete_tombstones(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id)',
    'FOREIGN KEY (account_id, parent_task_id) '
        'REFERENCES tasks(account_id, id)',
  ];
}

class TaskDueChangeGroupRows extends Table {
  @override
  String get tableName => 'task_due_change_groups';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get editedTaskId => integer()();

  IntColumn get snapshotCount =>
      integer().check(snapshotCount.isBiggerThanValue(1))();

  BoolColumn get cascadedParent => boolean()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, id},
    <Column<Object>>{accountId},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, edited_task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
  ];
}

class TaskDueChangeSnapshotRows extends Table {
  @override
  String get tableName => 'task_due_change_snapshots';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get groupId => integer()();

  IntColumn get taskId => integer()();

  IntColumn get priorDueEpochDay => integer().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, groupId, taskId},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, group_id) '
        'REFERENCES task_due_change_groups(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, task_id) '
        'REFERENCES tasks(account_id, id) ON DELETE CASCADE',
  ];
}

class BulkOperationRows extends Table {
  @override
  String get tableName => 'bulk_operations';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  TextColumn get kind => text().check(
    kind.isIn(const <String>[
      'complete',
      'reschedule',
      'move',
      'delete',
      'clearCompleted',
    ]),
  )();

  IntColumn get selectedCount =>
      integer().check(selectedCount.isBiggerThanValue(0))();

  IntColumn get affectedCount =>
      integer().check(affectedCount.isBiggerOrEqualValue(0))();

  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId},
    <Column<Object>>{accountId, id},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'CHECK (affected_count <= selected_count OR kind = \'reschedule\')',
  ];
}

class BulkOperationMemberRows extends Table {
  @override
  String get tableName => 'bulk_operation_members';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get operationId => integer()();

  IntColumn get taskId => integer()();

  IntColumn get desiredStateId => integer()();

  IntColumn get generation =>
      integer().check(generation.isBiggerThanValue(0))();

  TextColumn get outcome => text().check(
    outcome.isIn(const <String>['confirmed', 'pending', 'failed']),
  )();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, operationId, taskId},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, operation_id) '
        'REFERENCES bulk_operations(account_id, id) ON DELETE CASCADE',
  ];
}

class DesiredStateDependencyRows extends Table {
  @override
  String get tableName => 'desired_state_dependencies';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get desiredStateId => integer()();

  TextColumn get dependencyKind => text().check(
    dependencyKind.isIn(const <String>[
      'task_list',
      'parent_task',
      'previous_task',
    ]),
  )();

  IntColumn get dependsOnTaskListId => integer().nullable()();

  IntColumn get dependsOnTaskId => integer().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, desiredStateId, dependencyKind},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, desired_state_id) '
        'REFERENCES desired_states(account_id, id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, depends_on_task_list_id) '
        'REFERENCES task_lists(account_id, id)',
    'FOREIGN KEY (account_id, depends_on_task_id) '
        'REFERENCES tasks(account_id, id)',
    "CHECK ((dependency_kind = 'task_list' "
        'AND depends_on_task_list_id IS NOT NULL '
        'AND depends_on_task_id IS NULL) OR '
        "(dependency_kind IN ('parent_task', 'previous_task') "
        'AND depends_on_task_list_id IS NULL '
        'AND depends_on_task_id IS NOT NULL))',
  ];
}

class DesiredStateAttemptRows extends Table {
  @override
  String get tableName => 'desired_state_attempts';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  IntColumn get desiredStateId => integer()();

  IntColumn get generation =>
      integer().check(generation.isBiggerThanValue(0))();

  TextColumn get desiredLifecycle => text().check(
    desiredLifecycle.isIn(const <String>['present', 'deleted']),
  )();

  TextColumn get title => text().nullable()();

  TextColumn get notes => text().nullable()();

  TextColumn get status => text().nullable().check(
    status.isNull() | status.isIn(const <String>['needs_action', 'completed']),
  )();

  IntColumn get dueEpochDay => integer().nullable()();

  IntColumn get desiredTaskListId => integer().nullable()();

  IntColumn get desiredParentTaskId => integer().nullable()();

  IntColumn get desiredPreviousTaskId => integer().nullable()();

  TextColumn get baseRemoteId => text().nullable()();

  TextColumn get baseEtag => text().nullable()();

  DateTimeColumn get baseRemoteUpdatedAt => dateTime().nullable()();

  TextColumn get baseObservedPublicationId => text().nullable()();

  TextColumn get baseTitle => text().nullable()();

  IntColumn get baseTaskListId => integer().nullable()();

  IntColumn get baseParentTaskId => integer().nullable()();

  IntColumn get basePreviousTaskId => integer().nullable()();

  TextColumn get basePosition => text().nullable()();

  TextColumn get baseSiblingOrder => text().nullable()();

  DateTimeColumn get notBefore => dateTime().nullable()();

  TextColumn get state => text().check(
    state.isIn(const <String>[
      'pending',
      'in_flight',
      'uncertain',
      'failed',
      'confirmed',
      'superseded',
    ]),
  )();

  TextColumn get failureCode => text().nullable().check(
    failureCode.isNull() | failureCode.length.isBiggerThanValue(0),
  )();

  DateTimeColumn get claimedAt => dateTime()();

  DateTimeColumn get lastTransitionAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, id},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, desired_state_id) '
        'REFERENCES desired_states(account_id, id) ON DELETE CASCADE',
    "CHECK (desired_lifecycle = 'deleted' OR title IS NOT NULL)",
    "CHECK ((state IN ('failed', 'uncertain') "
        'AND length(failure_code) > 0) OR '
        "(state NOT IN ('failed', 'uncertain') AND failure_code IS NULL))",
  ];
}

class SyncRunRows extends Table {
  @override
  String get tableName => 'sync_runs';

  IntColumn get accountId => integer()();

  TextColumn get runId => text().check(runId.length.isBiggerThanValue(0))();

  TextColumn get triggersJson => text()();

  TextColumn get state => text().check(
    state.isIn(const <String>[
      'in_progress',
      'interrupted',
      'succeeded',
      'failed',
    ]),
  )();

  DateTimeColumn get startedAt => dateTime()();

  DateTimeColumn get finishedAt => dateTime().nullable()();

  TextColumn get failureCode => text().nullable().check(
    failureCode.isNull() | failureCode.length.isBiggerThanValue(0),
  )();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId, runId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    "CHECK ((state = 'in_progress' AND finished_at IS NULL "
        'AND failure_code IS NULL) OR '
        "(state IN ('interrupted', 'succeeded') AND finished_at IS NOT NULL "
        'AND failure_code IS NULL) OR '
        "(state = 'failed' AND finished_at IS NOT NULL "
        'AND length(failure_code) > 0))',
  ];
}

class SyncFactRows extends Table {
  @override
  String get tableName => 'sync_facts';

  IntColumn get accountId => integer()();

  DateTimeColumn get lastSuccessfulSyncAt => dateTime().nullable()();

  TextColumn get latestFailureReason => text().nullable().check(
    latestFailureReason.isNull() |
        latestFailureReason.isIn(const <String>[
          'no_connection',
          'remote_failure',
          'application_failure',
          'stale',
        ]),
  )();

  DateTimeColumn get latestFailureAt => dateTime().nullable()();

  TextColumn get latestFailureDiagnosticCode => text().nullable()();

  TextColumn get latestFailureAction => text().nullable().check(
    latestFailureAction.isNull() |
        latestFailureAction.isIn(const <String>['none', 'retry']),
  )();

  IntColumn get pendingCount => integer()
      .withDefault(const Constant(0))
      .check(pendingCount.isBiggerOrEqualValue(0))();

  IntColumn get inFlightCount => integer()
      .withDefault(const Constant(0))
      .check(inFlightCount.isBiggerOrEqualValue(0))();

  IntColumn get uncertainCount => integer()
      .withDefault(const Constant(0))
      .check(uncertainCount.isBiggerOrEqualValue(0))();

  IntColumn get failedCount => integer()
      .withDefault(const Constant(0))
      .check(failedCount.isBiggerOrEqualValue(0))();

  BoolColumn get reauthorizationRequired =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get retryWaiting => boolean().withDefault(const Constant(false))();

  BoolColumn get automaticRetryExhausted =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get retryEpisodeStartedAt => dateTime().nullable()();

  DateTimeColumn get retryEpisodeDeadlineAt => dateTime().nullable()();

  DateTimeColumn get retryNextAttemptAt => dateTime().nullable()();

  DateTimeColumn get retryServerNotBeforeAt => dateTime().nullable()();

  DateTimeColumn get retryLastObservedAt => dateTime().nullable()();

  IntColumn get retryAttemptCount => integer()
      .withDefault(const Constant(0))
      .check(retryAttemptCount.isBiggerOrEqualValue(0))();

  BoolColumn get requiredScopeIncomplete =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get followUpRequired =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'CHECK ((latest_failure_reason IS NULL '
        'AND latest_failure_at IS NULL '
        'AND latest_failure_diagnostic_code IS NULL '
        'AND latest_failure_action IS NULL) OR '
        '(latest_failure_reason IS NOT NULL '
        'AND latest_failure_at IS NOT NULL '
        'AND length(latest_failure_diagnostic_code) > 0 '
        'AND latest_failure_action IS NOT NULL))',
    'CHECK ((retry_episode_started_at IS NULL '
        'AND retry_episode_deadline_at IS NULL '
        'AND retry_next_attempt_at IS NULL '
        'AND retry_server_not_before_at IS NULL '
        'AND retry_last_observed_at IS NULL '
        'AND retry_attempt_count = 0 '
        'AND automatic_retry_exhausted = 0) OR '
        '(retry_episode_started_at IS NOT NULL '
        'AND retry_episode_deadline_at IS NOT NULL '
        'AND retry_last_observed_at IS NOT NULL '
        'AND retry_episode_deadline_at > retry_episode_started_at))',
  ];
}

class TaskListPreferenceRows extends Table {
  @override
  String get tableName => 'task_list_preferences';

  IntColumn get accountId => integer()();

  IntColumn get taskListId => integer()();

  IntColumn get sidebarOrder => integer().nullable().check(
    sidebarOrder.isNull() | sidebarOrder.isBiggerOrEqualValue(0),
  )();

  BoolColumn get excludedFromSmartViews =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId, taskListId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id, task_list_id) '
        'REFERENCES task_lists(account_id, id) ON DELETE CASCADE',
  ];
}

class ViewPreferenceRows extends Table {
  @override
  String get tableName => 'view_preferences';

  IntColumn get accountId => integer()();

  TextColumn get viewKey => text().check(viewKey.length.isBiggerThanValue(0))();

  TextColumn get sortMode => text().check(
    sortMode.isIn(const <String>[
      'manual',
      'effective_due',
      'title',
      'created',
    ]),
  )();

  BoolColumn get showCompleted =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId, viewKey};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
  ];
}

class AccountBackupImportManifestRows extends Table {
  @override
  String get tableName => 'account_backup_import_manifests';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get accountId => integer()();

  TextColumn get documentDigest =>
      text().check(documentDigest.length.equals(64))();

  TextColumn get sourceGoogleSubject =>
      text().check(sourceGoogleSubject.length.isBiggerThanValue(0))();

  BoolColumn get sourceAccountMatches => boolean()();

  DateTimeColumn get exportedAt => dateTime()();

  IntColumn get createdListCount =>
      integer().check(createdListCount.isBiggerOrEqualValue(0))();

  IntColumn get existingListCount =>
      integer().check(existingListCount.isBiggerOrEqualValue(0))();

  IntColumn get createdTaskCount =>
      integer().check(createdTaskCount.isBiggerOrEqualValue(0))();

  IntColumn get existingTaskCount =>
      integer().check(existingTaskCount.isBiggerOrEqualValue(0))();

  DateTimeColumn get importedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{accountId, documentDigest},
    <Column<Object>>{accountId, id},
  ];

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
  ];
}
