// #296 — the shell's half of "Needs attention": the entry EXISTS only while
// there is something to repair, it carries the count, and selecting it lands on
// the repair pane instead of a task list.
//
// The quiet rule is what these protect. A sync problem must not raise a banner,
// a dialog or a permanent nag — a clean session shows no entry at all, so the
// badge appearing IS the announcement, and it disappears by itself when the
// last item clears.

import 'dart:async';
import 'dart:io';

import 'package:axiotask/src/app/app.dart';
import 'package:axiotask/src/app/prefs.dart';
import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/attention.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/attention_view.dart';
import 'package:axiotask/src/ui/new_task_fab.dart';
import 'package:axiotask/src/ui/views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _list = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Work', etag: 'e', updated: 'u'),
  syncState: SyncState.clean,
  localUpdated: 'u',
);

final _held = StoredTask(
  task: const Task(
    id: 't1',
    position: '1',
    title: 'Send the invoice',
    status: TaskStatus.needsAction,
    updated: 'u',
  ),
  listId: 'L1',
  syncState: SyncState.dirty,
  localUpdated: 'u',
);

SyncStatusView _status({List<QuarantinedRow> quarantined = const []}) =>
    SyncStatusView(
      lastSynced: null,
      lastPulled: 0,
      lastPushed: 0,
      lastConflicts: 0,
      lastDeleted: 0,
      totalSyncs: 0,
      lastError: null,
      needsAttention: false,
      needsReauth: false,
      quarantined: quarantined,
    );

void main() {
  late Directory tmp;
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('axiotask_attention_test'),
  );
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<PrefsStore> pumpApp(
    WidgetTester tester, {
    required SyncStatusView status,
    Size size = const Size(1400, 1000),
  }) async {
    final store = PrefsStore(File(p.join(tmp.path, 'prefs.json')))
      ..save(const Prefs(onboardingSeen: true, view: 'all'));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(store.load()),
          prefsStoreProvider.overrideWithValue(store),
          allTasksProvider.overrideWith((ref) => Stream.value([_held])),
          listsProvider.overrideWith((ref) => Stream.value(const [_list])),
          syncStatusStreamProvider.overrideWith((ref) => Stream.value(status)),
        ],
        child: const AxiotaskApp(),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a clean sync layer puts no entry in the sidebar at all', (
    tester,
  ) async {
    await pumpApp(tester, status: _status());

    expect(find.text(kAttentionViewLabel), findsNothing);
    expect(find.byKey(const Key('sidebar-attention')), findsNothing);
  });

  testWidgets('a held row raises the entry, its badge, and its pane', (
    tester,
  ) async {
    await pumpApp(
      tester,
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
    );

    final entry = find.byKey(const Key('sidebar-attention'));
    expect(entry, findsOneWidget);
    expect(
      find.descendant(of: entry, matching: find.text('1')),
      findsOneWidget,
      reason: 'the count IS the announcement — nothing else says a word',
    );

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(AttentionView), findsOneWidget);
    expect(find.text('Discard local change'), findsOneWidget);
  });

  testWidgets('the repair view is not somewhere the app relaunches into', (
    tester,
  ) async {
    // Its contents are session-scoped and it is hidden when empty, so a
    // relaunch into it would land on an empty pane with no sidebar entry.
    // Every other view still persists.
    final store = await pumpApp(
      tester,
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('sidebar-attention')));
    await tester.pumpAndSettle();

    expect(store.load().view, 'all');
  });

  testWidgets('the touch FAB is absent in the repair view (non-happy path)', (
    tester,
  ) async {
    // A phone's one creation affordance is the FAB, and this view creates
    // nothing: a task made here would land in a list the pane cannot show.
    await pumpApp(
      tester,
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
      size: const Size(400, 900),
    );

    expect(
      find.byType(NewTaskFab),
      findsOneWidget,
      reason: 'the list view a phone starts on does have one',
    );

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-attention')));
    await tester.pumpAndSettle();

    expect(find.byType(AttentionView), findsOneWidget);
    expect(find.byType(NewTaskFab), findsNothing);
  });
}
