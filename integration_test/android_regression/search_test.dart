// Search subset of the Android behavior manifest (manifest.json).
//
// Case 17 failed the 2026-11-15 native audit of v1.5.6: tapping a search
// result that matched a subtask opened its parent (task 1) instead of the
// matched subtask (task 3), unlike v1.5.3. This contract drives the real
// shell by touch over the isolated file-backed SQLite fixture. A subtask hit
// must open that subtask, showing its own title, with Android Back returning
// to the parent's details and then to the collection. A parent and its child
// with identical titles each open their own task, and a hit in another list
// opens in that list with the same Back route. Searching and opening never
// change a stored task or create a publication intent.
// Run through tool/android_regression/runner.dart.
import 'package:axiotask/src/data/database/cache_dao.dart';
import 'package:axiotask/src/data/database/desired_state_dao.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/regression_harness.dart';

void main() {
  ensureRegressionBinding();

  regressionCase(
    '17_search_open_result',
    phoneOnHost: true,
    // A child whose title is identical to its parent's.
    seed: const RegressionSeed(openChildTitles: <String>['Audit parent']),
    (t, f) async {
      final desired = DesiredStateDao(f.database);
      final twin = f.openChildren.single;
      final before = await f.tasks();
      // A parent with a matching child in the other list.
      final remoteParent = before.singleWhere(
        (task) => task.title == 'Audit destination task',
      );
      final remoteChild = await CacheDao(f.database).putTask(
        accountId: f.account,
        taskListId: f.destination,
        remoteId: const TaskRemoteId('audit-destination-child'),
        title: 'Audit remote needle',
        position: '2',
        parentTaskId: remoteParent.id,
      );
      await settleUntil(
        t,
        () => f.model.state.tasks.any((task) => task.id == remoteChild),
        description: 'the other list\'s child to reach the view model',
      );
      final seeded = await f.tasks();

      // The audit's flow: search for the child's title and tap the result.
      await _search(t, 'Audit child');
      await f.capture(t, 'child_results');
      await t.tap(find.byKey(const Key('search-result-0')));
      await t.pumpAndSettle();
      expect(
        f.model.state.selectedTaskId,
        f.child,
        reason:
            'Searching for a subtask should open that matching subtask, '
            'as in v1.5.3',
      );
      _expectOpen(t, 'Audit child');
      expect(find.byTooltip('Back to parent task'), findsOneWidget);
      expect(find.byKey(const Key('search-input')), findsNothing);
      await f.capture(t, 'child_opened');
      await _expectBackToParentThenCollection(t, f, parent: f.parent);
      expect(f.model.state.selectedTaskListId, f.list);

      // Identical titles: the subtask hit opens the subtask, the parent hit
      // the parent.
      await _search(t, 'Audit parent');
      expect(find.byType(ListTile), findsNWidgets(2));
      await f.capture(t, 'identical_titles');
      await t.tap(_hit('Matched subtask: Audit parent'));
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, twin);
      _expectOpen(t, 'Audit parent');
      expect(find.byTooltip('Back to parent task'), findsOneWidget);
      await _expectBackToParentThenCollection(t, f, parent: f.parent);
      await _search(t, 'Audit parent');
      await t.tap(_hit('Matched title'));
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, f.parent);
      _expectOpen(t, 'Audit parent');
      expect(find.byTooltip('Back to task collection'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, isNull);

      // A hit in the other list opens there, with the same Back route.
      await _search(t, 'remote needle');
      await t.tap(_hit('Matched subtask: Audit remote needle'));
      await t.pumpAndSettle();
      expect(f.model.state.selectedTaskId, remoteChild);
      expect(f.model.state.selectedTaskListId, f.destination);
      _expectOpen(t, 'Audit remote needle');
      await f.capture(t, 'other_list_child');
      await _expectBackToParentThenCollection(t, f, parent: remoteParent.id);
      expect(f.model.state.selectedTaskListId, f.destination);
      expect(find.text('Audit destination task'), findsOneWidget);
      expect(find.text('Audit second task'), findsNothing);

      // No results opens nothing.
      await _search(t, 'Nothing matches this');
      expect(find.textContaining('No supported tasks match'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const Key('search-input')), findsNothing);
      expect(f.model.state.selectedTaskId, isNull);

      // Searching and opening stored nothing.
      final after = await f.tasks();
      expect(
        after.map(_stored).toList(),
        seeded.map(_stored).toList(),
        reason: 'navigation never changes a task',
      );
      for (final task in after) {
        expect(
          await desired.readTask(f.account, task.id),
          isNull,
          reason: '${task.title} gained a publication intent',
        );
      }
    },
  );
}

Future<void> _search(WidgetTester t, String query) async {
  await t.tap(find.byTooltip('Search tasks'));
  await t.pumpAndSettle();
  await t.enterText(find.byKey(const Key('search-input')), query);
  await settleUntil(
    t,
    () =>
        find.byKey(const Key('search-result-0')).evaluate().isNotEmpty ||
        find.textContaining('No supported tasks match').evaluate().isNotEmpty,
    description: 'search results for "$query"',
  );
}

/// The search result row whose subtitle contains [match].
Finder _hit(String match) => find.ancestor(
  of: find.textContaining(match),
  matching: find.byType(ListTile),
);

/// The details show [title] in their own title field.
void _expectOpen(WidgetTester t, String title) {
  final field = find.byKey(const Key('task-detail-title'));
  expect(t.widget<TextField>(field).controller?.text, title);
}

/// Android Back from an open subtask shows [parent]'s details, and the next
/// Back the collection.
Future<void> _expectBackToParentThenCollection(
  WidgetTester t,
  RegressionFixture f, {
  required TaskId parent,
}) async {
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  expect(f.model.state.selectedTaskId, parent, reason: 'Back to the parent');
  expect(find.byTooltip('Back to task collection'), findsOneWidget);
  await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  expect(f.model.state.selectedTaskId, isNull, reason: 'Back to the list');
}

String _stored(CachedTask task) =>
    '${task.id}|${task.taskListId}|${task.parentTaskId}|${task.title}|'
    '${task.notes}|${task.status}|${task.due}';
