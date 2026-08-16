import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../domain/model/preferences.dart';
import '../../domain/model/tasks.dart';
import '../database/app_database.dart';

abstract interface class RelationalPreferences {
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  );

  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  );

  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  );

  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  );
}

final class DriftRelationalPreferences implements RelationalPreferences {
  const DriftRelationalPreferences(this._database);

  final AppDatabase _database;

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) {
    return _database
        .customSelect(
          '''
          SELECT p.sidebar_order, COALESCE(p.excluded_from_smart_views, 0)
            AS excluded_from_smart_views
          FROM task_lists l
          LEFT JOIN task_list_preferences p
            ON p.account_id = l.account_id AND p.task_list_id = l.id
          WHERE l.account_id = ?1 AND l.id = ?2
          ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<int>(taskListId.value),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.taskListCacheRows,
            _database.taskListPreferenceRows,
          },
        )
        .watchSingle()
        .map(
          (row) => ListPreferences(
            sidebarOrder: row.readNullable<int>('sidebar_order'),
            excludedFromSmartViews: row.read<bool>('excluded_from_smart_views'),
          ),
        );
  }

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async {
    if (preferences.sidebarOrder case final order? when order < 0) {
      return const Outcome<void>.failure(_invalidSidebarOrderFailure);
    }
    try {
      final found =
          await (_database.select(_database.taskListCacheRows)..where(
                (row) =>
                    row.accountId.equals(accountId.value) &
                    row.id.equals(taskListId.value),
              ))
              .getSingleOrNull();
      if (found == null) {
        return const Outcome<void>.failure(_listNotFoundFailure);
      }
      await _database
          .into(_database.taskListPreferenceRows)
          .insertOnConflictUpdate(
            TaskListPreferenceRowsCompanion.insert(
              accountId: accountId.value,
              taskListId: taskListId.value,
              sidebarOrder: Value<int?>(preferences.sidebarOrder),
              excludedFromSmartViews: Value<bool>(
                preferences.excludedFromSmartViews,
              ),
            ),
          );
      return const Outcome<void>.success(null);
    } on SqliteException {
      return const Outcome<void>.failure(_relationalWriteFailure);
    }
  }

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) {
    return _database
        .customSelect(
          '''
          SELECT COALESCE(p.sort_mode, 'manual') AS sort_mode,
            COALESCE(p.show_completed, 0) AS show_completed
          FROM accounts a
          LEFT JOIN view_preferences p
            ON p.account_id = a.id AND p.view_key = ?2
          WHERE a.id = ?1
          ''',
          variables: <Variable<Object>>[
            Variable<int>(accountId.value),
            Variable<String>(viewKey.value),
          ],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            _database.accounts,
            _database.viewPreferenceRows,
          },
        )
        .watchSingle()
        .map(
          (row) => ViewPreferences(
            sort: _viewSortFromStorage(row.read<String>('sort_mode')),
            showCompleted: row.read<bool>('show_completed'),
          ),
        );
  }

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async {
    if (viewKey.value.isEmpty) {
      return const Outcome<void>.failure(_invalidViewKeyFailure);
    }
    try {
      final account = await (_database.select(
        _database.accounts,
      )..where((row) => row.id.equals(accountId.value))).getSingleOrNull();
      if (account == null) {
        return const Outcome<void>.failure(_accountNotFoundFailure);
      }
      await _database
          .into(_database.viewPreferenceRows)
          .insertOnConflictUpdate(
            ViewPreferenceRowsCompanion.insert(
              accountId: accountId.value,
              viewKey: viewKey.value,
              sortMode: _viewSortToStorage(preferences.sort),
              showCompleted: Value<bool>(preferences.showCompleted),
            ),
          );
      return const Outcome<void>.success(null);
    } on SqliteException {
      return const Outcome<void>.failure(_relationalWriteFailure);
    }
  }
}

ViewSort _viewSortFromStorage(String value) => switch (value) {
  'manual' => ViewSort.manual,
  'effective_due' => ViewSort.effectiveDue,
  'title' => ViewSort.title,
  'created' => ViewSort.created,
  _ => throw StateError('Unsupported view preference row.'),
};

String _viewSortToStorage(ViewSort value) => switch (value) {
  ViewSort.manual => 'manual',
  ViewSort.effectiveDue => 'effective_due',
  ViewSort.title => 'title',
  ViewSort.created => 'created',
};

const Failure _invalidSidebarOrderFailure = Failure(
  code: 'preferences.invalid_sidebar_order',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The list preference was not saved.',
  safeSummary: 'The requested sidebar order is invalid.',
);

const Failure _listNotFoundFailure = Failure(
  code: 'preferences.list_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The list preference was not saved.',
  safeSummary: 'The selected list is not in the account partition.',
);

const Failure _invalidViewKeyFailure = Failure(
  code: 'preferences.invalid_view_key',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The view preference was not saved.',
  safeSummary: 'The selected view key is invalid.',
);

const Failure _accountNotFoundFailure = Failure(
  code: 'preferences.account_not_found',
  category: FailureCategory.internal,
  operation: FailureOperation.write,
  retry: RetryClassification.permanent,
  impact: 'The view preference was not saved.',
  safeSummary: 'The selected account partition does not exist.',
);

const Failure _relationalWriteFailure = Failure(
  code: 'preferences.relational_write_failed',
  category: FailureCategory.persistence,
  operation: FailureOperation.write,
  retry: RetryClassification.unknown,
  impact: 'The application preference was not saved.',
  safeSummary: 'The relational preference write did not commit.',
);
