import 'dart:async';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/export/view_export.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/preferences_repository.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/domain/repository/view_export_destination.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/export_parsers.dart';

void main() {
  late _TasksRepository tasks;
  late _PreferencesRepository preferences;
  late FakeViewExportDestination destination;
  late TasksViewModel viewModel;

  Future<void> open({
    List<CachedTask>? snapshot,
    Future<void> Function() settle = pumpEventQueue,
  }) async {
    tasks = _TasksRepository(snapshot ?? _tasks);
    preferences = _PreferencesRepository();
    destination = FakeViewExportDestination();
    viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      preferencesRepository: preferences,
      syncHealthRepository: const _HealthRepository(),
      clock: ManualClock(DateTime.utc(2026, 11, 15, 12)),
      viewExportDestination: destination,
    );
    addTearDown(preferences.close);
    viewModel.start();
    await settle();
  }

  List<String> exportedTitles() =>
      parseCsv(destination.documents.last.text)
          .skip(1)
          .map((record) => record.first)
          .toList();

  test('a list exports its displayed rows, sort and subtasks', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(10));

    await viewModel.exportCurrentView(ViewExportFormat.csv);
    final document = destination.documents.single;
    expect(document.title, 'Shopping');
    expect(document.format, ViewExportFormat.csv);
    expect(
      exportedTitles(),
      viewModel.state.visibleTasks
          .expand(
            (task) => <String>[
              task.title,
              for (final child in viewModel.state.tasks)
                if (child.parentTaskId == task.id &&
                    child.status != TaskStatus.completed)
                  child.title,
            ],
          )
          .toList(),
    );
    expect(exportedTitles(), <String>['Bread', 'Apples', 'Open child']);

    await viewModel.setViewSort(ViewSort.title);
    await viewModel.exportCurrentView(ViewExportFormat.markdown);
    final markdown = parseMarkdownExport(destination.documents.last.text);
    expect(markdown.heading, 'Shopping');
    expect(
      markdown.items.map((item) => (item.depth, item.title)),
      <(int, String)>[(0, 'Apples'), (1, 'Open child'), (0, 'Bread')],
    );
  });

  test('the completed filter decides whether completed tasks export', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(10));

    await viewModel.exportCurrentView(ViewExportFormat.csv);
    expect(exportedTitles(), isNot(contains('Done top')));
    expect(exportedTitles(), isNot(contains('Done child')));

    await viewModel.setShowCompleted(true);
    await viewModel.exportCurrentView(ViewExportFormat.csv);
    expect(exportedTitles(), <String>[
      'Bread',
      'Apples',
      'Open child',
      'Done child',
      'Done top',
    ]);
    final rows = parseCsv(destination.documents.last.text);
    final doneTop = rows.singleWhere((row) => row.first == 'Done top');
    expect(doneTop[3], 'completed');
    expect(doneTop[4], '2026-11-14T09:15:00.000Z');
    expect(rows.singleWhere((row) => row.first == 'Done child')[4], '');
  });

  test('a smart view exports across lists without excluded lists', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectSmartView(SmartView.focus);
    await viewModel.toggleListExclusion(const TaskListId(30));

    await viewModel.exportCurrentView(ViewExportFormat.csv);

    final document = destination.documents.single;
    expect(document.title, 'Focus');
    expect(document.fileName, 'axiotask-focus-20261115.csv');
    final records = parseCsv(document.text).skip(1).toList();
    expect(records.map((r) => (r[0], r[1])), <(String, String)>[
      ('Work report', 'Work'),
      ('Bread', 'Shopping'),
    ]);
    expect(document.text, isNot(contains('Excluded list task')));
  });

  test('an empty view exports an explicit empty document', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(40));
    expect(viewModel.state.visibleTasks, isEmpty);

    await viewModel.exportCurrentView(ViewExportFormat.markdown);

    final document = destination.documents.single;
    expect(document.text, '# Empty\n\n_No tasks._\n');
    expect(document.taskCount, 0);
    expect(
      viewModel.state.transientFeedback?.message,
      'Exported 0 tasks as Markdown to saved.md.',
    );
  });

  test('success reports the count, format and destination name', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(10));

    await viewModel.exportCurrentView(ViewExportFormat.csv);

    final feedback = viewModel.state.transientFeedback!;
    expect(feedback.kind, TransientTaskFeedbackKind.exported);
    expect(feedback.message, 'Exported 3 tasks as CSV to saved.md.');
    expect(viewModel.state.isExportPending, isFalse);
    expect(tasks.mutations, 0);
    expect(preferences.mutations, 0);
  });

  test('cancellation writes nothing and changes no task', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(10));
    destination.next = () async => const ViewExportCancelled();
    final before = viewModel.state.tasks;

    await viewModel.exportCurrentView(ViewExportFormat.markdown);

    expect(
      viewModel.state.transientFeedback?.kind,
      TransientTaskFeedbackKind.exportCancelled,
    );
    expect(
      viewModel.state.transientFeedback?.message,
      'Export canceled. No file was written.',
    );
    expect(viewModel.state.tasks, before);
    expect(viewModel.state.isExportPending, isFalse);
    expect(tasks.mutations, 0);
  });

  for (final (failure, message) in <(ViewExportFailure, String)>[
    (
      ViewExportFailure.unavailable,
      'Export is not available on this device. Your tasks are unchanged.',
    ),
    (
      ViewExportFailure.pickerFailed,
      'The save location could not be opened. Nothing was exported; your '
          'tasks are unchanged.',
    ),
    (
      ViewExportFailure.writeFailed,
      'The export could not be written to the chosen location. Your tasks '
          'are unchanged.',
    ),
  ]) {
    test('a ${failure.name} destination error is reported calmly', () async {
      await open();
      addTearDown(viewModel.dispose);
      viewModel.selectTaskList(const TaskListId(10));
      destination.next = () async =>
          throw ViewExportDestinationException(failure, 'platform detail');
      final before = viewModel.state.tasks;

      await viewModel.exportCurrentView(ViewExportFormat.csv);

      final feedback = viewModel.state.transientFeedback!;
      expect(feedback.kind, TransientTaskFeedbackKind.exportFailed);
      expect(feedback.message, message);
      expect(feedback.message, isNot(contains('platform detail')));
      expect(viewModel.state.tasks, before);
      expect(viewModel.state.isExportPending, isFalse);
      expect(tasks.mutations, 0);
    });
  }

  test('an unexpected error is reported as a write failure', () async {
    await open();
    addTearDown(viewModel.dispose);
    destination.next = () async => throw StateError('boom');

    await viewModel.exportCurrentView(ViewExportFormat.csv);

    expect(
      viewModel.state.transientFeedback?.kind,
      TransientTaskFeedbackKind.exportFailed,
    );
  });

  test('a repeated request while one is pending opens one picker', () async {
    await open();
    addTearDown(viewModel.dispose);
    final release = Completer<ViewExportResult>();
    destination.next = () => release.future;

    final first = viewModel.exportCurrentView(ViewExportFormat.csv);
    final second = viewModel.exportCurrentView(ViewExportFormat.markdown);
    await pumpEventQueue();
    expect(viewModel.state.isExportPending, isTrue);
    expect(destination.documents, hasLength(1));

    release.complete(const ViewExportSaved('one.csv'));
    await Future.wait(<Future<void>>[first, second]);
    expect(viewModel.state.isExportPending, isFalse);
    expect(destination.documents, hasLength(1));
  });

  test('the export is the view as displayed when it was requested', () async {
    await open();
    addTearDown(viewModel.dispose);
    viewModel.selectTaskList(const TaskListId(10));
    final release = Completer<ViewExportResult>();
    destination.next = () => release.future;

    final pending = viewModel.exportCurrentView(ViewExportFormat.csv);
    await pumpEventQueue();
    // A sync lands while the picker is open.
    tasks.emit(<CachedTask>[..._tasks, _task(99, 'Arrived later')]);
    await pumpEventQueue();
    expect(
      viewModel.state.visibleTasks.map((task) => task.title),
      contains('Arrived later'),
    );
    release.complete(const ViewExportSaved('x.csv'));
    await pending;

    expect(exportedTitles(), isNot(contains('Arrived later')));
  });

  test('disposal while the picker is open finishes quietly', () async {
    await open();
    final release = Completer<ViewExportResult>();
    destination.next = () => release.future;

    final pending = viewModel.exportCurrentView(ViewExportFormat.csv);
    await pumpEventQueue();
    viewModel.dispose();
    release.complete(const ViewExportSaved('late.csv'));

    await expectLater(pending, completes);
  });

  test('without a destination nothing is offered or attempted', () async {
    tasks = _TasksRepository(_tasks);
    final plain = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      syncHealthRepository: const _HealthRepository(),
    );
    addTearDown(plain.dispose);

    await plain.exportCurrentView(ViewExportFormat.csv);

    expect(plain.viewExportDestination, isNull);
    expect(plain.state.transientFeedback, isNull);
  });
  group('collection actions on a phone', () {
    Future<void> pumpPhone(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(settle: () => tester.pump());
      addTearDown(viewModel.dispose);
      viewModel.selectTaskList(const TaskListId(10));
      await tester.pumpWidget(
        MaterialApp(home: AdaptiveShell(viewModel: viewModel)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(const Key('collection-actions-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('offer both formats and report each outcome', (tester) async {
      await pumpPhone(tester);
      try {
        await tester.tap(find.byKey(const Key('collection-actions-menu')));
        await tester.pumpAndSettle();
        expect(find.text('Export as Markdown…').hitTestable(), findsOneWidget);
        expect(find.text('Export as CSV…').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Export as Markdown…'));
        await tester.pumpAndSettle();

        expect(destination.documents.single.format, ViewExportFormat.markdown);
        expect(
          parseMarkdownExport(destination.documents.single.text).items
              .map((item) => item.title),
          <String>['Bread', 'Apples', 'Open child'],
        );
        expect(
          find.text('Exported 3 tasks as Markdown to saved.md.'),
          findsOneWidget,
        );

        destination.next = () async => const ViewExportCancelled();
        await choose(tester, 'collection-export-csv');
        expect(destination.documents.last.format, ViewExportFormat.csv);
        expect(
          find.text('Export canceled. No file was written.'),
          findsOneWidget,
        );

        destination.next = () async =>
            throw const ViewExportDestinationException(
              ViewExportFailure.writeFailed,
            );
        await choose(tester, 'collection-export-csv');
        expect(
          find.text(
            'The export could not be written to the chosen location. Your '
            'tasks are unchanged.',
          ),
          findsOneWidget,
        );
        expect(find.text('Bread'), findsOneWidget);
        expect(tasks.mutations, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('are disabled while an export is choosing a destination', (
      tester,
    ) async {
      await pumpPhone(tester);
      try {
        final release = Completer<ViewExportResult>();
        destination.next = () => release.future;
        await choose(tester, 'collection-export-markdown');
        expect(viewModel.state.isExportPending, isTrue);

        await tester.tap(find.byKey(const Key('collection-actions-menu')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PopupMenuItem<Object?>>(
                find.byKey(const Key('collection-export-csv')),
              )
              .enabled,
          isFalse,
        );
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        release.complete(const ViewExportCancelled());
        await tester.pumpAndSettle();
        expect(destination.documents, hasLength(1));
        expect(viewModel.state.isExportPending, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

/// Records each document and answers with [next].
final class FakeViewExportDestination implements ViewExportDestination {
  final documents = <ViewExportDocument>[];
  Future<ViewExportResult> Function() next = () async =>
      const ViewExportSaved('saved.md');

  @override
  Future<ViewExportResult> save(ViewExportDocument document) {
    documents.add(document);
    return next();
  }
}

final _tasks = <CachedTask>[
  _task(1, 'Bread', due: TaskDate(2026, 11, 16)),
  _task(2, 'Apples', notes: 'red'),
  _task(3, 'Open child', parent: 2),
  _task(4, 'Done child', parent: 2, status: TaskStatus.completed),
  _task(
    5,
    'Done top',
    status: TaskStatus.completed,
    completedAt: DateTime.utc(2026, 11, 14, 9, 15),
  ),
  _task(6, 'Work report', list: 20, due: TaskDate(2026, 11, 14)),
  _task(7, 'Excluded list task', list: 30, due: TaskDate(2026, 11, 15)),
];

const _lists = <CachedTaskList>[
  CachedTaskList(
    id: TaskListId(10),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-10'),
    title: 'Shopping',
  ),
  CachedTaskList(
    id: TaskListId(20),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-20'),
    title: 'Work',
  ),
  CachedTaskList(
    id: TaskListId(30),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-30'),
    title: 'Excluded',
  ),
  CachedTaskList(
    id: TaskListId(40),
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('synthetic-list-40'),
    title: 'Empty',
  ),
];

CachedTask _task(
  int id,
  String title, {
  int list = 10,
  int? parent,
  String? notes,
  TaskDate? due,
  TaskStatus status = TaskStatus.needsAction,
  DateTime? completedAt,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: TaskListId(list),
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('synthetic-task-$id'),
  title: title,
  notes: notes,
  status: status,
  due: due,
  completedAt: completedAt,
);

CachedTasksSnapshot _snapshot(List<CachedTask> tasks) => CachedTasksSnapshot(
  accountId: const AccountId(1),
  taskLists: _lists,
  tasks: tasks,
  completeness: CacheCompleteness.complete,
);

/// Serves a snapshot and counts every write, which export must never make.
final class _TasksRepository implements TasksRepository {
  _TasksRepository(List<CachedTask> tasks) : _current = _snapshot(tasks);

  CachedTasksSnapshot _current;
  final _changes = StreamController<CachedTasksSnapshot>.broadcast();
  var mutations = 0;

  void emit(List<CachedTask> tasks) {
    _current = _snapshot(tasks);
    _changes.add(_current);
  }

  @override
  Stream<CachedTasksSnapshot> watchTasks(TasksQuery query) async* {
    yield _current;
    yield* _changes.stream;
  }

  @override
  Stream<List<TaskDeleteUndo>> watchUndoableTaskDeletes(AccountId accountId) =>
      Stream.value(const <TaskDeleteUndo>[]);

  @override
  Stream<List<TaskDueChangeUndo>> watchUndoableTaskDueChanges(
    AccountId accountId,
  ) => Stream.value(const <TaskDueChangeUndo>[]);

  Never _write() {
    mutations += 1;
    throw StateError('export must not write tasks');
  }

  @override
  Future<Outcome<void>> apply(ExistingTaskCommand command) async => _write();

  @override
  Future<Outcome<TaskDueChangeReceipt>> setTaskDue(
    SetTaskDueCommand command,
  ) async => _write();

  @override
  Future<Outcome<void>> undoTaskDueChange(
    UndoTaskDueChangeCommand command,
  ) async => _write();

  @override
  Future<Outcome<TaskId>> createTask(CreateTaskCommand command) async =>
      _write();

  @override
  Future<Outcome<TaskDeleteReceipt>> deleteTask(
    DeleteTaskCommand command,
  ) async => _write();

  @override
  Future<Outcome<void>> undoTaskDelete(UndoTaskDeleteCommand command) async =>
      _write();
}

final class _PreferencesRepository implements PreferencesRepository {
  final _listChanges =
      StreamController<Map<TaskListId, ListPreferences>>.broadcast();
  final _viewChanges =
      StreamController<Map<ViewKey, ViewPreferences>>.broadcast();
  final lists = <TaskListId, ListPreferences>{};
  final views = <ViewKey, ViewPreferences>{};

  /// Every preference write, including a test's own setup.
  var mutations = 0;

  Future<void> close() async {
    await _listChanges.close();
    await _viewChanges.close();
  }

  @override
  Stream<Map<TaskListId, ListPreferences>> watchAllListPreferences(
    AccountId accountId,
  ) async* {
    yield Map<TaskListId, ListPreferences>.of(lists);
    yield* _listChanges.stream;
  }

  @override
  Stream<Map<ViewKey, ViewPreferences>> watchAllViewPreferences(
    AccountId accountId,
  ) async* {
    yield Map<ViewKey, ViewPreferences>.of(views);
    yield* _viewChanges.stream;
  }

  @override
  Stream<ListPreferences> watchListPreferences(
    AccountId accountId,
    TaskListId taskListId,
  ) => watchAllListPreferences(accountId)
      .map((values) => values[taskListId] ?? const ListPreferences.defaults());

  @override
  Stream<ViewPreferences> watchViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
  ) =>
      watchAllViewPreferences(accountId)
          .map((values) => values[viewKey] ?? const ViewPreferences.defaults());

  @override
  Future<Outcome<void>> setListPreferences(
    AccountId accountId,
    TaskListId taskListId,
    ListPreferences preferences,
  ) async {
    mutations += 1;
    lists[taskListId] = preferences;
    _listChanges.add(Map<TaskListId, ListPreferences>.of(lists));
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setSidebarOrder(
    AccountId accountId,
    List<TaskListId> orderedTaskListIds,
  ) async {
    mutations += 1;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setViewPreferences(
    AccountId accountId,
    ViewKey viewKey,
    ViewPreferences preferences,
  ) async {
    mutations += 1;
    views[viewKey] = preferences;
    _viewChanges.add(Map<ViewKey, ViewPreferences>.of(views));
    return const Outcome<void>.success(null);
  }

  @override
  Stream<DevicePreferences> watchDevicePreferences() =>
      Stream.value(const DevicePreferences.defaults());

  @override
  Future<Outcome<void>> setDensity(DensityPreference density) async {
    mutations += 1;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setWorkspacePreferences(
    DesktopWorkspacePreferences preferences,
  ) async {
    mutations += 1;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setOnboardingDismissed(bool dismissed) async {
    mutations += 1;
    return const Outcome<void>.success(null);
  }

  @override
  Future<Outcome<void>> setTheme(ThemePreference theme) async {
    mutations += 1;
    return const Outcome<void>.success(null);
  }
}

final class _HealthRepository implements SyncHealthRepository {
  const _HealthRepository();

  @override
  Stream<SyncHealth> watchHealth(AccountId accountId) => Stream.value(
    SyncHealth(
      outcome: SyncHealthOutcome.good,
      counts: const SyncWorkCounts(),
      lastSuccessfulSyncAt: DateTime.utc(2026, 11, 15, 12),
      evaluatedAt: DateTime.utc(2026, 11, 15, 12),
    ),
  );
}
