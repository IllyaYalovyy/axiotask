// Home-navigation subset of the Android behavior manifest (manifest.json).
//
// The 2026-11-15 native audit's screenshots of v1.5.3 and v1.5.6 showed two
// findings beyond its 36 cases (tracked as `bottom-navigation` and
// `task-row-metadata`, not as audit failures): v1.5.6 phones lost v1.5.3's
// bottom smart-view navigation (Focus, Upcoming, Missed, Unscheduled, All)
// and its readable task-row metadata (relative due dates, a notes mark,
// subtask progress and, in a smart view, the task's list).
//
// These contracts drive the real shell by touch over the isolated
// file-backed SQLite fixture. Each destination must filter the collection to
// exactly the view's stored tasks and show itself active; a list opened from
// the drawer must leave every destination inactive; Back from details must
// return to the view it left; and the bar must keep measured 48 dp hit
// regions clear of the add button and the system gesture area. Rows must
// announce, and show, metadata derived from the seeded rows. Navigation
// never changes a stored task or creates a publication intent. Light and
// dark captures are taken for comparison with the v1.5.3 screenshot.
// Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/domain/policy/smart_views.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../test/support/touch_targets.dart';
import 'support/regression_harness.dart';

void main() {
  ensureRegressionBinding();

  regressionCase('bottom-navigation', phoneOnHost: true, (t, f) async {
    final upcoming = await _seedUpcoming(t, f);
    final seeded = await f.tasks();
    final expected = <SmartView, Set<String>>{
      SmartView.focus: <String>{'Audit parent', 'Audit upcoming'},
      SmartView.upcoming: <String>{'Audit upcoming'},
      SmartView.missed: <String>{'Audit parent'},
      SmartView.unscheduled: <String>{
        'Audit second task',
        'Audit destination task',
      },
      SmartView.all: <String>{
        'Audit parent',
        'Audit second task',
        'Audit destination task',
        'Audit upcoming',
      },
    };

    // The fixture opens its list, which is no bottom destination.
    expect(_bar, findsOneWidget, reason: 'v1.5.3 phones navigate from a bar');
    _expectActive(t, null);
    for (final view in SmartView.values) {
      final count = expected[view]!.length;
      expect(
        t.getSemantics(_destination(view)),
        isSemantics(
          label: '${view.title}, $count ${count == 1 ? 'task' : 'tasks'}',
          isButton: true,
          hasTapAction: true,
          isSelected: false,
        ),
      );
    }
    await f.capture(t, 'list_no_active');

    // Each destination, by touch, filters to exactly its stored rows.
    for (final view in SmartView.values) {
      await t.tap(_destination(view));
      await t.pumpAndSettle();
      expect(f.model.state.selectedSmartView, view);
      expect(_headerTitle(t), view.title);
      expect(_rowTitles(f).toSet(), expected[view], reason: view.title);
      for (final title in expected[view]!) {
        expect(find.text(title), findsOneWidget, reason: '$title row shown');
      }
      _expectActive(t, view);
      await f.capture(t, 'view_${view.name}');
    }

    // A list from the drawer deselects every destination; a tap returns.
    await t.tap(find.byTooltip('Open navigation'));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit destination').hitTestable());
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskListId, f.destination);
    expect(_rowTitles(f).toSet(), <String>{
      'Audit destination task',
      'Audit upcoming',
    });
    _expectActive(t, null);
    await t.tap(_destination(SmartView.missed));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskListId, isNull);
    _expectActive(t, SmartView.missed);

    // Returning from details keeps the active view.
    await t.tap(_destination(SmartView.upcoming));
    await t.pumpAndSettle();
    await t.tap(find.text('Audit upcoming'));
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, upcoming);
    expect(_bar, findsNothing, reason: 'Details are a full-screen route');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedTaskId, isNull);
    expect(f.model.state.selectedSmartView, SmartView.upcoming);
    expect(_rowTitles(f).toSet(), expected[SmartView.upcoming]);
    _expectActive(t, SmartView.upcoming);
    await f.capture(t, 'back_from_details');

    // Reachable touch targets at every phone size; on a short landscape
    // phone at large text the bar yields and the drawer keeps the views.
    for (final viewport in <PhoneViewport>[
      const PhoneViewport(320, PhoneOrientation.portrait, 2),
      const PhoneViewport(360, PhoneOrientation.portrait, 1),
      const PhoneViewport(443, PhoneOrientation.portrait, 2),
      const PhoneViewport(360, PhoneOrientation.landscape, 1),
      const PhoneViewport(443, PhoneOrientation.landscape, 2),
    ]) {
      await usePhoneViewport(t, viewport);
      expect(t.takeException(), isNull, reason: '$viewport layout');
      if (_bar.evaluate().isEmpty) {
        expect(viewport.orientation, PhoneOrientation.landscape);
        await t.tap(find.byTooltip('Open navigation'));
        await t.pumpAndSettle();
        final missed = find.widgetWithText(ListTile, 'Missed');
        await t.ensureVisible(missed);
        await t.pumpAndSettle();
        await t.tap(missed);
        await t.pumpAndSettle();
        expect(f.model.state.selectedSmartView, SmartView.missed);
        await f.capture(t, 'drawer_${viewport.name}');
        continue;
      }
      await t.tap(_destination(SmartView.all));
      await t.pumpAndSettle();
      expect(_rowTitles(f).toSet(), expected[SmartView.all]);
      _expectReachableBar(t, viewport);
      await f.capture(t, 'bar_${viewport.name}');
    }

    // Navigating stored nothing.
    final after = await f.tasks();
    expect(after.map(_stored).toList(), seeded.map(_stored).toList());
    final desired = DesiredStateDao(f.database);
    for (final task in after) {
      expect(
        await desired.readTask(f.account, task.id),
        isNull,
        reason: '${task.title} gained a publication intent',
      );
    }
  });

  regressionCase('task-row-metadata', phoneOnHost: true, (t, f) async {
    await f.preferences.setTheme(ThemePreference.light);
    await _seedUpcoming(t, f);
    // A list row: its own date, notes and subtask progress, no list label.
    expect(
      t.getSemantics(_metadata(f.parent)),
      matchesSemantics(
        label:
            'Has notes, Due today, Subtask due yesterday, '
            '0 of 1 subtask complete',
      ),
    );
    expect(_rowText(f.parent, 'today'), findsOneWidget);
    expect(_rowText(f.parent, 'yesterday'), findsOneWidget);
    expect(_rowText(f.parent, '0/1'), findsOneWidget);
    expect(_rowKey(f.parent, 'task-row-notes'), findsOneWidget);
    expect(_rowKey(f.parent, 'task-row-list'), findsNothing);
    expect(
      t.getSemantics(_metadata(f.second)),
      matchesSemantics(label: 'No due date'),
    );
    expect(_rowText(f.second, 'no date'), findsOneWidget);
    // The raw ISO date of v1.5.6 is gone from phone rows.
    expect(
      find.descendant(
        of: find.byKey(const Key('desktop-task-scroll')),
        matching: find.textContaining('2026-11-'),
      ),
      findsNothing,
    );
    await f.capture(t, 'list_rows');

    // A smart view names each row's list.
    await t.tap(_destination(SmartView.all));
    await t.pumpAndSettle();
    final upcoming = f.model.state.tasks.singleWhere(
      (task) => task.title == 'Audit upcoming',
    );
    expect(
      t.getSemantics(_metadata(upcoming.id)),
      matchesSemantics(label: 'Has notes, Due in 3 days, In Audit destination'),
    );
    expect(_rowText(upcoming.id, 'in 3d'), findsOneWidget);
    expect(_rowText(f.parent, 'Audit tasks'), findsOneWidget);
    final overdue = _rowText(f.parent, 'yesterday');
    final scheme = Theme.of(t.element(overdue)).colorScheme;
    expect(t.widget<Text>(overdue).style?.color, scheme.error);
    expect(
      t.widget<Text>(_rowText(f.parent, 'today')).style?.color,
      scheme.primary,
    );
    await f.capture(t, 'all_light');

    // Completing the child by touch in its details updates the parent row
    // from what SQLite stored.
    await f.openParent(t);
    final childCompletion = find.byTooltip('Complete Audit child');
    await t.ensureVisible(childCompletion);
    await t.pumpAndSettle();
    await t.tap(childCompletion);
    await settleUntil(
      t,
      () async => (await f.task(f.child)).status == TaskStatus.completed,
      description: 'the child completion to persist',
    );
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(f.model.state.selectedSmartView, SmartView.all);
    expect(
      t.getSemantics(_metadata(f.parent)),
      matchesSemantics(
        label: 'Has notes, Due today, 1 of 1 subtask complete, In Audit tasks',
      ),
    );
    expect(_rowText(f.parent, '1/1'), findsOneWidget);

    // Every phone size and 2x text lays the metadata out without overflow.
    for (final viewport in selectionViewports) {
      await usePhoneViewport(t, viewport);
      expect(t.takeException(), isNull, reason: '$viewport layout');
      final row = find.byKey(Key('desktop-task-row-${f.parent.value}'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      final rowRect = t.getRect(row);
      final metadata = t.getRect(_metadata(f.parent));
      expect(
        metadata.left >= rowRect.left - 0.5 &&
            metadata.right <= rowRect.right + 0.5 &&
            metadata.bottom <= rowRect.bottom + 0.5,
        isTrue,
        reason: '$viewport metadata $metadata inside its row $rowRect',
      );
      for (final paragraph in t.renderObjectList<RenderParagraph>(
        find.descendant(
          of: _metadata(f.parent),
          matching: find.byType(RichText),
        ),
      )) {
        expect(paragraph.size.width, lessThanOrEqualTo(metadata.width + 0.5));
      }
    }
    await usePhoneViewport(
      t,
      const PhoneViewport(443, PhoneOrientation.portrait, 1),
    );

    // The dark theme, for comparison with v1.5.3's dark screenshot.
    await f.preferences.setTheme(ThemePreference.dark);
    await settleUntil(
      t,
      () =>
          Theme.of(t.element(find.byType(Scaffold).first)).brightness ==
          Brightness.dark,
      description: 'the dark theme',
    );
    final darkScheme = Theme.of(t.element(_bar)).colorScheme;
    expect(
      t.widget<Text>(_rowText(f.parent, 'today')).style?.color,
      darkScheme.primary,
    );
    await f.capture(t, 'all_dark');
  });
}

/// Adds an undated-list, upcoming, annotated task to the destination list
/// and waits for the view model to read it from SQLite.
Future<TaskId> _seedUpcoming(WidgetTester t, RegressionFixture f) async {
  final id = await CacheDao(f.database).putTask(
    accountId: f.account,
    taskListId: f.destination,
    remoteId: const TaskRemoteId('audit-upcoming'),
    title: 'Audit upcoming',
    notes: 'Bring the receipt',
    position: '2',
    due: TaskDate(2026, 11, 18),
  );
  await settleUntil(
    t,
    () => f.model.state.tasks.any((task) => task.id == id),
    description: 'the upcoming task to reach the view model',
  );
  return id;
}

final _bar = find.byKey(const Key('smart-view-bar'));

Finder _destination(SmartView view) =>
    find.byKey(Key('smart-view-destination-${view.name}'));

Finder _metadata(TaskId id) => find.descendant(
  of: find.byKey(Key('desktop-task-row-${id.value}')),
  matching: find.byKey(const Key('task-row-metadata')),
);

Finder _rowText(TaskId id, String text) =>
    find.descendant(of: _metadata(id), matching: find.text(text));

Finder _rowKey(TaskId id, String key) =>
    find.descendant(of: _metadata(id), matching: find.byKey(Key(key)));

List<String> _rowTitles(RegressionFixture f) =>
    f.model.state.visibleTasks.map((task) => task.title).toList();

String? _headerTitle(WidgetTester t) {
  return t.widget<Text>(find.byKey(const Key('phone-collection-title'))).data;
}

void _expectActive(WidgetTester t, SmartView? active) {
  for (final view in SmartView.values) {
    expect(
      t.getSemantics(_destination(view)),
      isSemantics(isSelected: view == active),
      reason: '${view.title} ${view == active ? 'is' : 'is not'} active',
    );
  }
}

/// Every destination is a 48 dp touch target inside the screen, above the
/// system gesture area, apart from its neighbours and the add button.
void _expectReachableBar(WidgetTester t, PhoneViewport viewport) {
  final screen = Offset.zero & t.view.physicalSize / t.view.devicePixelRatio;
  final bottomInset = t.view.padding.bottom / t.view.devicePixelRatio;
  final bar = t.getRect(_bar);
  expect(bar.bottom, closeTo(screen.bottom, 0.5), reason: '$viewport bar');
  final add = find.byKey(const Key('phone-add-task'));
  if (add.evaluate().isNotEmpty) {
    expect(
      t.getRect(add).overlaps(bar),
      isFalse,
      reason: '$viewport add button clear of the bar',
    );
    // Floating over the rows, the button leaves the whole first row above
    // it, however tall its wrapping title and metadata make it.
    final docked = find.descendant(
      of: find.byKey(const Key('collection-header')),
      matching: add,
    );
    if (docked.evaluate().isEmpty) {
      final firstRow = find.descendant(
        of: find.byKey(const Key('desktop-task-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'desktop-task-row-',
              ),
        ),
      );
      final rowRect = t.getRect(firstRow.first);
      expect(
        t.getRect(add).overlaps(rowRect),
        isFalse,
        reason: '$viewport add button clear of the first row $rowRect',
      );
    } else if (viewport.textScale == 1) {
      // Docked at normal text, the add button never pushes the collection
      // commands under the header's scroll edge or over each other.
      final header = t.getRect(
        find.byKey(const Key('collection-header-scroll')),
      );
      final addRect = t.getRect(add);
      for (final control in <Finder>[
        find.byTooltip('Sort tasks'),
        find.byTooltip('Collection actions'),
      ]) {
        final rect = t.getRect(control);
        expect(
          rect.top >= header.top - 0.5 && rect.bottom <= header.bottom + 0.5,
          isTrue,
          reason: '$viewport $control $rect whole inside the header $header',
        );
        expect(
          rect.overlaps(addRect),
          isFalse,
          reason: '$viewport $control clear of the docked add button',
        );
      }
    }
  }
  Rect? previous;
  for (final view in SmartView.values) {
    final region = expectTouchTarget(t, _destination(view), label: view.title);
    expect(
      region.left >= screen.left - 0.5 &&
          region.right <= screen.right + 0.5 &&
          region.bottom <= screen.bottom - bottomInset + 0.5,
      isTrue,
      reason: '$viewport ${view.title} $region above the gesture area',
    );
    if (previous != null) {
      expect(
        region
            .deflate(hitRegionTolerance)
            .overlaps(previous.deflate(hitRegionTolerance)),
        isFalse,
        reason: '$viewport ${view.title} apart from its neighbour',
      );
    }
    previous = region;
  }
}

String _stored(CachedTask task) =>
    '${task.id}|${task.taskListId}|${task.parentTaskId}|${task.title}|'
    '${task.notes}|${task.status}|${task.due}';
