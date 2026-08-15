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

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{accountId};

  @override
  List<String> get customConstraints => <String>[
    'FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE',
    'FOREIGN KEY (account_id, default_task_list_id) '
        'REFERENCES task_lists(account_id, id)',
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
