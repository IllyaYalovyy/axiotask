// The composer belongs to the APP, not to the pane that happens to be on
// screen (#274).
//
// Before this, every mounted [TaskListView] owned its own quick-add controller,
// its own draft, its own snapshot of the list set — and its own listener on
// `newTaskRequestProvider`. A view switch mounts TWO panes at once (the
// [ViewSwitch] cross-fade keeps the outgoing one alive for the length of the
// transition), and both of them answered the same FAB tap: two bottom-sheet
// composers stacked on one another, the lower one aimed at the view the user
// had just LEFT. And an open sheet rendered from a `lists` value captured when
// its route was built, so a list arriving while the composer was up (a sync
// pull, or simply the lists stream resolving a frame late) was invisible to the
// destination picker.
//
// What these tests protect:
//   • ONE composer surface, however many panes are mounted;
//   • an open composer's destination picker follows the LIVE list set;
//   • a half-typed title survives a view switch (the composer outlives the
//     pane, so the draft is not thrown away by a tap on the bottom bar).

import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/window_title_controller.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/shell_nav_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeTitle implements WindowTitleController {
  @override
  Future<void> setTitle(String title) async {}
}

const _phone = Size(400, 900);

StoredTask _task(String id, String title, {String listId = 'L1'}) => StoredTask(
  task: Task(
    id: id,
    position: id,
    title: title,
    status: TaskStatus.needsAction,
    updated: 't',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: 't',
);

StoredTaskList _list(String id, String title) => StoredTaskList(
  list: TaskList(id: id, title: title, etag: 'e', updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

void main() {
  late Directory tmp;
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    tmp = Directory.systemTemp.createTempSync('axiotask_composer_scope');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The real app on a phone, opened on [view].
  Future<void> pumpApp(
    WidgetTester tester, {
    String view = 'focus',
    Stream<List<StoredTaskList>>? lists,
  }) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(Prefs(view: view, onboardingSeen: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          windowTitleControllerProvider.overrideWithValue(_FakeTitle()),
          allTasksProvider.overrideWith(
            (ref) => Stream.value([_task('T1', 'alpha')]),
          ),
          listsProvider.overrideWith(
            (ref) => lists ?? Stream.value([_list('L1', 'Work')]),
          ),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapDestination(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(ShellNavBar), matching: find.text(label)),
    );
  }

  testWidgets('a FAB tap DURING a view switch opens exactly one composer', (
    tester,
  ) async {
    await pumpApp(tester);

    // Step to the next destination and stop one frame in: the outgoing pane
    // is still mounted beside the arriving one — the state that used to
    // answer a single FAB tap twice.
    await tapDestination(tester, 'Upcoming');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('view-focus')),
      findsOneWidget,
      reason: 'the transition really is mid-flight (both panes mounted)',
    );
    expect(find.byKey(const ValueKey('view-upcoming')), findsOneWidget);

    await tester.tap(find.byTooltip('New task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const Key('quick-add-bar')),
      findsOneWidget,
      reason: 'one FAB tap is one composer, however many panes are mounted',
    );
  });

  testWidgets('an open composer follows the live list set', (tester) async {
    final lists = StreamController<List<StoredTaskList>>();
    addTearDown(lists.close);
    await pumpApp(tester, lists: lists.stream);
    lists.add([_list('L1', 'Work')]);
    await tester.pump();

    await tester.tap(find.byTooltip('New task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('quick-add-bar')), findsOneWidget);
    // One list is no choice at all, so the composer spends no width on a
    // destination picker.
    expect(find.byKey(const Key('quick-add-list-picker')), findsNothing);

    // A second list lands WHILE the composer is up (a sync pull).
    lists.add([_list('L1', 'Work'), _list('L2', 'Home')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const Key('quick-add-list-picker')),
      findsOneWidget,
      reason: 'the open composer can aim at the list that just arrived',
    );
  });

  testWidgets('a half-typed title survives a view switch', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('New task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).first, 'half a thought');
    await tester.pump();

    // Dismiss the composer and step to another view — the pane the draft used
    // to live in is torn down by that step.
    Navigator.of(tester.element(find.byKey(const Key('quick-add-bar')))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tapDestination(tester, 'Upcoming');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('New task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('half a thought'),
      findsOneWidget,
      reason: 'the composer outlives the pane, so the draft does too',
    );
  });
}
