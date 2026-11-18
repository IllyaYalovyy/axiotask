import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiotask/src/app/adaptive_shell.dart';
import 'package:axiotask/src/app/visual_tokens.dart';
import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/commands/task_commands.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:axiotask/src/domain/repository/tasks_repository.dart';
import 'package:axiotask/src/features/tasks/tasks_view_model.dart';
import 'package:axiotask/src/sync/health/sync_health.dart';
import 'package:axiotask/src/sync/health/sync_health_repository.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/touch_targets.dart';

/// Host contract for the phone home screen restored from v1.5.3 (tracked
/// Android audit findings `bottom-navigation` and `task-row-metadata`): the
/// bottom smart-view bar and readable task-row metadata. The native contract
/// is `integration_test/android_regression/home_navigation_test.dart`.
void main() {
  setUpAll(() async {
    await loadAndroidTextFont();
    await _loadMaterialIcons();
  });

  group('phone smart-view bar', () {
    testWidgets('offers the five reference views with their counts', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);

      expect(_bar, findsOneWidget);
      for (final view in SmartView.values) {
        expect(
          find.descendant(
            of: _destination(view),
            matching: find.text(view.title),
          ),
          findsOneWidget,
          reason: '${view.title} is a bottom destination',
        );
      }
      // The app opens on the first list, which is no bottom destination.
      expect(_title, 'Inbox');
      _expectActive(tester, null);
      for (final view in SmartView.values) {
        final count = _expectedRows[view]!.length;
        expect(fixture.viewModel.state.viewCount(SmartTaskView(view)), count);
        expect(
          tester.getSemantics(_destination(view)),
          isSemantics(
            label: '${view.title}, $count ${count == 1 ? 'task' : 'tasks'}',
            isButton: true,
            hasTapAction: true,
            isSelected: false,
          ),
        );
      }
    });

    testWidgets('a touch on each destination filters to exactly its rows', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);

      for (final view in <SmartView>[
        SmartView.upcoming,
        SmartView.missed,
        SmartView.unscheduled,
        SmartView.all,
        SmartView.focus,
      ]) {
        await tester.tap(_destination(view));
        await tester.pumpAndSettle();
        expect(fixture.viewModel.state.selectedSmartView, view);
        expect(_title, view.title);
        expect(_visibleRowTitles(fixture), _expectedRows[view]);
        _expectActive(tester, view);
      }
    });

    testWidgets('a drawer list deselects every destination; a tap returns', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);

      await tester.tap(find.byTooltip('Open navigation'));
      await tester.pumpAndSettle();
      expect(_bar, findsNothing, reason: 'The drawer has its own navigation');
      // The drawer keeps its counts beside every view and list.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Missed'),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Errands'),
          matching: find.text('3 tasks'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Errands'));
      await tester.pumpAndSettle();

      expect(fixture.viewModel.state.selectedTaskListId, _errands);
      expect(_title, 'Errands');
      expect(_visibleRowTitles(fixture), <String>[
        'Buy milk',
        'Read book',
        'Renew passport',
      ]);
      _expectActive(tester, null);

      await tester.tap(_destination(SmartView.missed));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskListId, isNull);
      expect(_visibleRowTitles(fixture), _expectedRows[SmartView.missed]);
      _expectActive(tester, SmartView.missed);
    });

    testWidgets('returning from details keeps the active view', (tester) async {
      final fixture = await _pump(tester, _portrait);

      await tester.tap(_destination(SmartView.upcoming));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Renew passport'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, const TaskId(7));
      expect(_bar, findsNothing, reason: 'Details are a full-screen route');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedTaskId, isNull);
      expect(fixture.viewModel.state.selectedSmartView, SmartView.upcoming);
      expect(_title, 'Upcoming');
      expect(_visibleRowTitles(fixture), _expectedRows[SmartView.upcoming]);
      _expectActive(tester, SmartView.upcoming);
    });

    testWidgets('selection, the composer and the keyboard hide the bar', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);

      await tester.longPress(find.text('Pay rent'));
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.isBulkSelectionActive, isTrue);
      expect(_bar, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_bar, findsOneWidget);

      await tester.tap(find.byKey(const Key('phone-add-task')));
      await tester.pumpAndSettle();
      expect(_bar, findsNothing, reason: 'The composer is being used');
      // Android zeroes the bottom system padding under a raised keyboard.
      tester.view
        ..viewInsets = const FakeViewPadding(bottom: 300)
        ..padding = const FakeViewPadding(top: 24);
      await tester.pumpAndSettle();
      expect(_bar, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      tester.view
        ..resetViewInsets()
        ..padding = const FakeViewPadding(top: 24, bottom: 48);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.viewModel.state.selectedSmartView, isNull);
      expect(_bar, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final viewport in selectionViewports) {
      // The bar yields where it would leave the collection less than three
      // touch rows (scaled with text): short landscape phones at large text,
      // and the 320 landscape phone. Their drawer keeps the smart views.
      final barExpected =
          viewport.orientation == PhoneOrientation.portrait ||
          (viewport.textScale == 1 && viewport.shortSide >= 360);
      testWidgets(
        '${barExpected ? 'fits above the safe area beside the add '
                  'button' : 'yields to the drawer'} at $viewport',
        (tester) async {
          final fixture = await _pump(tester, viewport);
          if (!barExpected) {
            expect(_bar, findsNothing);
            await tester.tap(find.byTooltip('Open navigation'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.widgetWithText(ListTile, 'Missed'));
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(ListTile, 'Missed'));
            await tester.pumpAndSettle();
            expect(fixture.viewModel.state.selectedSmartView, SmartView.missed);
            expect(_visibleRowTitles(fixture), _expectedRows[SmartView.missed]);
            expect(tester.takeException(), isNull, reason: '$viewport layout');
            return;
          }
          final screen = Offset.zero & viewport.logicalSize;
          final bar = tester.getRect(_bar);
          expect(bar.bottom, screen.bottom, reason: 'The bar meets the edge');
          final addButton = tester.getRect(
            find.byKey(const Key('phone-add-task')),
          );
          expect(
            addButton.overlaps(bar),
            isFalse,
            reason: 'Add button $addButton stays clear of the bar $bar',
          );
          // Floating over the rows, the button leaves a whole first row
          // above it, however tall the row's wrapping metadata makes it.
          final docked = find.descendant(
            of: find.byKey(const Key('collection-header')),
            matching: find.byKey(const Key('phone-add-task')),
          );
          if (docked.evaluate().isEmpty) {
            final firstRow = tester.getRect(
              find.byKey(const Key('desktop-task-row-1')),
            );
            expect(
              addButton.overlaps(firstRow),
              isFalse,
              reason: 'Add button $addButton clear of first row $firstRow',
            );
          }
          final usable = Rect.fromLTRB(
            screen.left,
            screen.top,
            screen.right,
            screen.bottom - _bottomInset,
          );
          Rect? previous;
          for (final view in SmartView.values) {
            final region = expectTouchTarget(
              tester,
              _destination(view),
              label: view.title,
            );
            expect(
              region.top >= usable.top - 0.5 &&
                  region.bottom <= usable.bottom + 0.5 &&
                  region.left >= usable.left - 0.5 &&
                  region.right <= usable.right + 0.5,
              isTrue,
              reason: '${view.title} $region is above the gesture area $usable',
            );
            if (previous != null) {
              expect(
                region
                    .deflate(hitRegionTolerance)
                    .overlaps(previous.deflate(hitRegionTolerance)),
                isFalse,
                reason: '${view.title} $region never reaches its neighbour',
              );
            }
            previous = region;
            final label = find.descendant(
              of: _destination(view),
              matching: find.text(view.title),
            );
            final labelRect = tester.getRect(label);
            expect(
              labelRect.left >= region.left - 0.5 &&
                  labelRect.right <= region.right + 0.5,
              isTrue,
              reason: '${view.title} label $labelRect stays in its cell',
            );
          }
          // Every destination still works at this size.
          await tester.tap(_destination(SmartView.all));
          await tester.pumpAndSettle();
          expect(_visibleRowTitles(fixture), _expectedRows[SmartView.all]);
          expect(tester.takeException(), isNull, reason: '$viewport layout');
        },
      );
    }

    testWidgets('a docked add button joins the commands where they fit', (
      tester,
    ) async {
      // A 360 landscape phone at 1x text: the bar leaves no room for a
      // floating button, but the header is wide enough for title, commands
      // and button on one row, so no command is pushed under its scroll edge.
      await _pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.landscape, 1),
      );
      final header = find.byKey(const Key('collection-header'));
      final add = find.descendant(
        of: header,
        matching: find.byKey(const Key('phone-add-task')),
      );
      expect(add, findsOneWidget, reason: 'The add button docks');
      expect(_bar, findsOneWidget);
      final addRect = tester.getRect(add);
      final title = tester.getRect(
        find.descendant(of: header, matching: find.text('Inbox')),
      );
      final scroll = tester.getRect(
        find.byKey(const Key('collection-header-scroll')),
      );
      {
        final control = find.byTooltip('Collection actions');
        final rect = tester.getRect(
          find.descendant(of: header, matching: control),
        );
        expect(
          rect.top >= addRect.top - 0.5 && rect.bottom <= addRect.bottom + 0.5,
          isTrue,
          reason: '$control $rect shares the add button row $addRect',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(scroll.bottom + 0.5),
          reason: '$control is not cut off by the header edge $scroll',
        );
        expect(rect.left, greaterThanOrEqualTo(title.right));
        expect(rect.right, lessThanOrEqualTo(addRect.left));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a docked add button never squeezes the title or commands', (
      tester,
    ) async {
      // A short split-screen window at 1x text: the rows leave no room for a
      // floating button, so it docks in the header.
      final fixture = await _pump(
        tester,
        const PhoneViewport(320, PhoneOrientation.portrait, 1),
      );
      tester.view.physicalSize = const Size(320, 420);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '320 x 420 layout');
      final header = find.byKey(const Key('collection-header'));
      final add = find.descendant(
        of: header,
        matching: find.byKey(const Key('phone-add-task')),
      );
      expect(add, findsOneWidget, reason: 'The add button docks');
      final titleRect = tester.getRect(
        find.descendant(of: header, matching: find.text('Inbox')),
      );
      final addRect = tester.getRect(add);
      final actions = tester.getRect(
        find.descendant(
          of: header,
          matching: find.byTooltip('Collection actions'),
        ),
      );
      final headerRect = tester.getRect(header);
      expect(titleRect.width, greaterThan(40), reason: 'The title is legible');
      for (final (name, rect) in <(String, Rect)>[
        ('title', titleRect),
        ('collection actions', actions),
      ]) {
        expect(
          rect.overlaps(addRect),
          isFalse,
          reason: '$name $rect clear of the add button $addRect',
        );
        expect(
          rect.left >= headerRect.left - 0.5 &&
              rect.right <= headerRect.right + 0.5,
          isTrue,
          reason: '$name $rect inside the header $headerRect',
        );
      }
      expect(titleRect.overlaps(actions), isFalse);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-surface')), findsOneWidget);
      expect(fixture.viewModel.state.tasks, hasLength(_tasks.length));
    });

    for (final (platform, width) in <(TargetPlatform, double)>[
      (TargetPlatform.linux, 412),
      (TargetPlatform.linux, 1280),
      (TargetPlatform.android, 1280),
    ]) {
      testWidgets('${platform.name} at $width keeps desktop navigation', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: axiotaskTheme(
              Brightness.light,
              DensityPreference.standard,
              platform: platform,
            ),
            home: AdaptiveShell(viewModel: fixture.viewModel),
          ),
        );
        await tester.pumpAndSettle();
        fixture.viewModel.selectSmartView(SmartView.all);
        await tester.pumpAndSettle();
        expect(_bar, findsNothing);
        expect(find.byKey(const Key('task-row-metadata')), findsNothing);
        // The desktop rows keep their established subtitle.
        expect(find.text('Due 2026-11-13'), findsOneWidget);
        if (width >= 1024) {
          expect(
            find.byKey(const Key('desktop-navigation-pane')),
            findsOneWidget,
          );
        }
      });
    }
  });

  group('phone task-row metadata', () {
    testWidgets('shows due, notes, subtasks and list from the cached tasks', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);
      fixture.viewModel.selectSmartView(SmartView.all);
      await tester.pumpAndSettle();

      final expected = <int, String>{
        1: 'Has notes, Due 2 days ago, In Inbox',
        2: 'Subtask due tomorrow, 1 of 2 subtasks complete, In Inbox',
        5: 'Due today, In Errands',
        6: 'No due date, In Errands',
        7: 'Has notes, Due in 5 days, In Errands',
        8: 'Due Dec 3, In Inbox',
      };
      for (final MapEntry(key: id, value: label) in expected.entries) {
        final metadata = _metadata(id);
        await tester.ensureVisible(metadata);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(metadata),
          matchesSemantics(label: label),
          reason: 'Task $id metadata is announced as a phrase',
        );
      }

      // What the eye sees: the same facts, compactly.
      expect(_rowText(1, '2d overdue'), findsOneWidget);
      expect(_rowKey(1, 'task-row-notes'), findsOneWidget);
      expect(_rowText(1, 'Inbox'), findsOneWidget);
      expect(_rowText(2, '1/2'), findsOneWidget);
      expect(_rowText(2, 'tomorrow'), findsOneWidget);
      expect(_rowKey(2, 'task-row-notes'), findsNothing);
      expect(_rowText(5, 'today'), findsOneWidget);
      expect(_rowText(6, 'no date'), findsOneWidget);
      expect(_rowText(7, 'in 5d'), findsOneWidget);
      expect(_rowText(8, 'Dec 3'), findsOneWidget);
      // Overdue reads in the error colour, today in the primary colour.
      final scheme = Theme.of(tester.element(_metadata(1))).colorScheme;
      expect(_textColor(tester, _rowText(1, '2d overdue')), scheme.error);
      expect(_textColor(tester, _rowText(5, 'today')), scheme.primary);
      // Subtasks are not rows of the collection.
      expect(find.text('Book train'), findsNothing);
    });

    testWidgets('a list omits the list label and follows cache changes', (
      tester,
    ) async {
      final fixture = await _pump(tester, _portrait);
      fixture.viewModel.selectTaskList(_inbox);
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(_metadata(1)),
        matchesSemantics(label: 'Has notes, Due 2 days ago'),
      );
      expect(_rowKey(1, 'task-row-list'), findsNothing);

      fixture.tasks.emit(<CachedTask>[
        for (final task in _tasks)
          switch (task.id.value) {
            1 => task.copyWith(notes: null, due: TaskDate(2026, 11, 16)),
            4 => task.copyWith(status: TaskStatus.completed),
            _ => task,
          },
      ]);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(_metadata(1)),
        matchesSemantics(label: 'Due tomorrow'),
      );
      expect(
        tester.getSemantics(_metadata(2)),
        matchesSemantics(label: 'No due date, 2 of 2 subtasks complete'),
      );
    });

    for (final viewport in selectionViewports) {
      testWidgets('lays out without overflow at $viewport', (tester) async {
        final fixture = await _pump(tester, viewport);
        fixture.viewModel.selectSmartView(SmartView.all);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$viewport layout');
        final row = find.byKey(const Key('desktop-task-row-2'));
        await tester.scrollUntilVisible(
          row,
          40,
          scrollable: find.descendant(
            of: find.byKey(const Key('desktop-task-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        final rowRect = tester.getRect(row);
        final metadata = tester.getRect(_metadata(2));
        expect(
          metadata.left >= rowRect.left && metadata.right <= rowRect.right,
          isTrue,
          reason: 'Metadata $metadata stays inside its row $rowRect',
        );
        expect(metadata.bottom, lessThanOrEqualTo(rowRect.bottom + 0.5));
        // Every metadata text paints whole or ellipsized, never clipped.
        for (final paragraph in tester.renderObjectList<RenderParagraph>(
          find.descendant(of: _metadata(2), matching: find.byType(RichText)),
        )) {
          expect(paragraph.size.width, lessThanOrEqualTo(metadata.width + 0.5));
        }
      });
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('phone home ${brightness.name} golden', (tester) async {
      final fixture = await _pump(
        tester,
        const PhoneViewport(360, PhoneOrientation.portrait, 1),
        brightness: brightness,
      );
      fixture.viewModel.selectSmartView(SmartView.all);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(AdaptiveShell),
        matchesGoldenFile(
          '../../goldens/linux/phone_home_navigation_${brightness.name}.png',
        ),
      );
    });
  }
}

const _inbox = TaskListId(7);
const _errands = TaskListId(8);
const _bottomInset = 48.0;
const _portrait = PhoneViewport(360, PhoneOrientation.portrait, 1);

/// Top-level open rows of each smart view on 2026-11-15, in display order.
const _expectedRows = <SmartView, List<String>>{
  SmartView.focus: <String>[
    'Pay rent',
    'Plan trip',
    'Buy milk',
    'Renew passport',
  ],
  SmartView.upcoming: <String>['Plan trip', 'Renew passport'],
  SmartView.missed: <String>['Pay rent'],
  SmartView.unscheduled: <String>['Read book'],
  SmartView.all: <String>[
    'Pay rent',
    'Plan trip',
    'Dentist',
    'Buy milk',
    'Read book',
    'Renew passport',
  ],
};

final _bar = find.byKey(const Key('smart-view-bar'));

Finder _destination(SmartView view) =>
    find.byKey(Key('smart-view-destination-${view.name}'));

Finder _metadata(int taskId) => find.descendant(
  of: find.byKey(Key('desktop-task-row-$taskId')),
  matching: find.byKey(const Key('task-row-metadata')),
);

Finder _rowText(int taskId, String text) =>
    find.descendant(of: _metadata(taskId), matching: find.text(text));

Finder _rowKey(int taskId, String key) =>
    find.descendant(of: _metadata(taskId), matching: find.byKey(Key(key)));

Color? _textColor(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style?.color;

String? get _title {
  final header = find.byKey(const Key('collection-header'));
  final texts = find.descendant(of: header, matching: find.byType(Text));
  return (texts.evaluate().first.widget as Text).data;
}

List<String> _visibleRowTitles(_Fixture fixture) =>
    fixture.viewModel.state.visibleTasks.map((task) => task.title).toList();

void _expectActive(WidgetTester tester, SmartView? active) {
  for (final view in SmartView.values) {
    expect(
      tester.getSemantics(_destination(view)),
      isSemantics(isSelected: view == active),
      reason: '${view.title} ${view == active ? 'is' : 'is not'} active',
    );
  }
}

Future<_Fixture> _pump(
  WidgetTester tester,
  PhoneViewport viewport, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view
    ..physicalSize = viewport.logicalSize
    ..devicePixelRatio = 1
    ..padding = const FakeViewPadding(top: 24, bottom: _bottomInset)
    ..viewPadding = const FakeViewPadding(top: 24, bottom: _bottomInset);
  tester.platformDispatcher.textScaleFactorTestValue = viewport.textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final fixture = _Fixture();
  addTearDown(fixture.dispose);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: axiotaskTheme(
        brightness,
        DensityPreference.standard,
        fontFamily: androidTextFontFamily,
        platform: TargetPlatform.android,
      ),
      home: AdaptiveShell(viewModel: fixture.viewModel),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '$viewport layout');
  return fixture;
}

final _lists = <CachedTaskList>[
  const CachedTaskList(
    id: _inbox,
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('inbox'),
    title: 'Inbox',
  ),
  const CachedTaskList(
    id: _errands,
    accountId: AccountId(1),
    remoteId: TaskListRemoteId('errands'),
    title: 'Errands',
  ),
];

final _tasks = <CachedTask>[
  _task(1, 'Pay rent', due: TaskDate(2026, 11, 13), notes: 'Bank transfer'),
  _task(2, 'Plan trip'),
  _task(3, 'Book hotel', parent: 2, status: TaskStatus.completed),
  _task(4, 'Book train', parent: 2, due: TaskDate(2026, 11, 16)),
  _task(8, 'Dentist', due: TaskDate(2026, 12, 3)),
  _task(5, 'Buy milk', list: _errands, due: TaskDate(2026, 11, 15)),
  _task(6, 'Read book', list: _errands),
  _task(
    7,
    'Renew passport',
    list: _errands,
    due: TaskDate(2026, 11, 20),
    notes: 'Photos',
  ),
];

CachedTask _task(
  int id,
  String title, {
  TaskListId list = _inbox,
  int? parent,
  TaskDate? due,
  String? notes,
  TaskStatus status = TaskStatus.needsAction,
}) => CachedTask(
  id: TaskId(id),
  accountId: const AccountId(1),
  taskListId: list,
  parentTaskId: parent == null ? null : TaskId(parent),
  remoteId: TaskRemoteId('remote-$id'),
  title: title,
  notes: notes,
  status: status,
  due: due,
);

final class _Fixture {
  _Fixture() : tasks = _TasksRepository(_tasks) {
    viewModel = TasksViewModel(
      accountId: const AccountId(1),
      tasksRepository: tasks,
      syncHealthRepository: const _HealthRepository(),
      clock: ManualClock(DateTime.utc(2026, 11, 15, 12)),
    );
  }

  final _TasksRepository tasks;
  late final TasksViewModel viewModel;

  void dispose() => viewModel.dispose();
}

/// Serves the cached account; navigation and metadata never write tasks.
final class _TasksRepository implements TasksRepository {
  _TasksRepository(List<CachedTask> tasks) : _current = _snapshot(tasks);

  CachedTasksSnapshot _current;
  final _changes = StreamController<CachedTasksSnapshot>.broadcast();

  static CachedTasksSnapshot _snapshot(List<CachedTask> tasks) =>
      CachedTasksSnapshot(
        accountId: const AccountId(1),
        taskLists: _lists,
        tasks: tasks,
        completeness: CacheCompleteness.complete,
      );

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

  Never _write() => throw StateError('navigation must not write tasks');

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

/// Registers the locked Flutter SDK's Material Icons so the goldens show
/// the icons a phone shows, rather than placeholder boxes.
Future<void> _loadMaterialIcons() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final document =
      jsonDecode(await packageConfig.readAsString()) as Map<String, Object?>;
  final flutter = (document['packages']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((value) => value['name'] == 'flutter');
  final flutterPackage = Directory.fromUri(
    packageConfig.absolute.uri.resolve(flutter['rootUri']! as String),
  );
  final font = File(
    '${flutterPackage.parent.parent.path}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!font.existsSync()) {
    throw StateError('The locked Flutter SDK Material Icons are unavailable.');
  }
  final bytes = await font.readAsBytes();
  await (FontLoader('MaterialIcons')..addFont(
        Future<ByteData>.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      ))
      .load();
}
