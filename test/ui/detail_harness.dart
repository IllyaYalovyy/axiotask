// Shared harness for the TaskDetail suites (TaskDetail, DetailWorkflow,
// SubtaskReorder). A lightweight in-memory [Commands] double that ACTUALLY
// mutates its task set and re-emits it on the stream the panel watches — so the
// tests assert the USER-VISIBLE result (what renders, what order, what the fake
// holds), never merely that a method fired. It stays off drift's real event
// queue, which the testWidgets fake zone cannot drain (see the
// widget-test-drift-async memory).

import 'dart:async';

import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/haptics.dart';
import 'package:axiotask/src/ui/task_detail.dart';
import 'package:axiotask/src/ui/url_opener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_commands.dart';
import 'toast_harness.dart' show wrapWithToast;

export '../support/fake_commands.dart' show FakeCommands;

StoredTask row(
  String id,
  String title, {
  String? parent,
  bool done = false,
  String? notes,
  String? due,
  String position = '1',
  String listId = 'L1',
  String? webViewLink,
}) => StoredTask(
  task: Task(
    id: id,
    parent: parent,
    position: position,
    title: title,
    notes: notes,
    due: due,
    status: done ? TaskStatus.completed : TaskStatus.needsAction,
    webViewLink: webViewLink,
    updated: 't',
  ),
  listId: listId,
  syncState: SyncState.clean,
  localUpdated: 't',
);

StoredTaskList list(String id, String title) => StoredTaskList(
  list: TaskList(id: id, title: title, updated: 't'),
  syncState: SyncState.clean,
  localUpdated: 't',
);

/// Pump the real [TaskDetail] over a [FakeCommands], with the lists and prefs
/// providers live so the List dropdown and the Hide-completed toggle work.
Future<FakeCommands> pumpDetail(
  WidgetTester tester, {
  required String taskId,
  required List<StoredTask> initial,
  List<StoredTaskList> lists = const [],
  List<String>? closed,
  List<String>? opened,
  String Function()? newId,
  VoidCallback? onPrev,
  VoidCallback? onNext,
  UrlOpener? urlOpener,
  ThemeData? theme,
  Size size = const Size(1000, 2400),
  double textScale = 1.0,
  Haptics? hapticsDevice,
}) async {
  final fake = FakeCommands(initial, newId: newId);
  addTearDown(fake.dispose);
  // A tall surface so the whole panel lays out and every subtask row is built
  // (a lazy ListView culls children below the fold, hiding them from finders).
  // A caller probing narrow/large-text layout overrides it.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => fake.tasksStream),
        if (lists.isNotEmpty)
          listsProvider.overrideWith((ref) => Stream.value(lists)),
        if (urlOpener != null) urlOpenerProvider.overrideWithValue(urlOpener),
        if (hapticsDevice != null)
          hapticsDeviceProvider.overrideWithValue(hapticsDevice),
      ],
      child: MaterialApp(
        // A caller that cares about COLOUR pins the real app theme (the panel's
        // urgency tones are scheme roles); everyone else keeps the default.
        theme: theme,
        // Mount the F19 toast overlay so the panel's delete/move undo renders.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: wrapWithToast(context, child),
        ),
        home: Scaffold(
          body: TaskDetail(
            taskId: taskId,
            onClose: () => (closed ?? <String>[]).add('close'),
            onOpenTask: (opened ?? <String>[]).add,
            onPrev: onPrev,
            onNext: onNext,
          ),
        ),
      ),
    ),
  );
  await settleDetail(tester);
  return fake;
}

Future<void> settleDetail(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// Open the detail app bar's "⋮" overflow — since #246 EVERY non-navigation
/// action (Duplicate, Make subtask of…/Detach, Open in Google Tasks, Delete)
/// lives there, so a suite reaching one of them goes through here. Bounded
/// pumps rather than pumpAndSettle: the panel may hold a focused field whose
/// cursor never stops blinking (see TESTING.md).
Future<void> openDetailOverflow(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('detail-overflow')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}
