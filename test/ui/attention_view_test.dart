// #296 — the "Needs attention" view, from the user's side: what it renders,
// what a repair leaves on screen, and the fact that it does not exist at all
// while the sync layer is clean.
//
// The entries are driven by the SAME two inputs production uses — the sanitized
// sync status (held rows + recorded forks) and the live task rows — over the
// in-memory [FakeCommands], which actually performs each repair against its own
// set and re-emits it. So every assertion here is about what a user would see
// after acting: the card is gone, the undo toast is up, taking Undo brings the
// card back. Nothing asserts that a method fired.

import 'dart:async';

import 'package:axiotask/src/app/providers.dart';
import 'package:axiotask/src/app/sync_status.dart';
import 'package:axiotask/src/model/attention.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:axiotask/src/ui/attention_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_commands.dart';
import 'toast_harness.dart' show wrapWithToast;

const _list = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Work', etag: 'e', updated: 'u'),
  syncState: SyncState.clean,
  localUpdated: 'u',
);

StoredTask _row(
  String id,
  String title, {
  String? notes,
  String? due,
  SyncState syncState = SyncState.dirty,
}) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: title,
    notes: notes,
    status: TaskStatus.needsAction,
    due: due,
    updated: 'u',
  ),
  listId: 'L1',
  syncState: syncState,
  localUpdated: 'u',
);

SyncStatusView _status({
  List<QuarantinedRow> quarantined = const [],
  List<ConflictLink> conflicts = const [],
  bool needsReauth = false,
  bool needsAttention = false,
  String? lastError,
}) => SyncStatusView(
  lastSynced: null,
  lastPulled: 0,
  lastPushed: 0,
  lastConflicts: 0,
  lastDeleted: 0,
  totalSyncs: 0,
  lastError: lastError,
  needsAttention: needsAttention,
  needsReauth: needsReauth,
  quarantined: quarantined,
  conflicts: conflicts,
);

/// Three frames, no clock: the fake's task stream and the status stream each
/// deliver on an event-loop turn of their own, and the rebuild they cause needs
/// a frame after that. A bounded pump, never `pumpAndSettle` — an action toast
/// schedules frames for its whole life and would never idle (TESTING.md).
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// Pump the real [AttentionView] over a fake command set and a status stream a
/// test can push new values into (which is what a sync RUN does in production).
Future<(FakeCommands, void Function(SyncStatusView), List<String>)>
_pumpAttention(
  WidgetTester tester, {
  required List<StoredTask> tasks,
  required SyncStatusView status,
  Future<void> Function(String id)? onRetry,
  Size size = const Size(1000, 900),
}) async {
  final fake = FakeCommands(tasks);
  addTearDown(fake.dispose);
  final statuses = StreamController<SyncStatusView>.broadcast();
  addTearDown(statuses.close);
  final opened = <String>[];
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandsProvider.overrideWithValue(fake),
        allTasksProvider.overrideWith((ref) => fake.tasksStream),
        listsProvider.overrideWith((ref) => Stream.value(const [_list])),
        syncStatusStreamProvider.overrideWith((ref) async* {
          yield status;
          yield* statuses.stream;
        }),
        if (onRetry != null)
          retryQuarantinedActionProvider.overrideWithValue(onRetry),
      ],
      child: MaterialApp(
        builder: (context, child) => wrapWithToast(context, child),
        home: Scaffold(body: AttentionView(onOpenTask: opened.add)),
      ),
    ),
  );
  await settle(tester);
  // Publishing a status is what a sync RUN does in production; the controller
  // itself stays inside the harness (and is closed with the test).
  return (fake, statuses.add, opened);
}

void main() {
  testWidgets('a held row names itself, its list and why it is stuck', (
    tester,
  ) async {
    await _pumpAttention(
      tester,
      tasks: [_row('t1', 'Send the invoice')],
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
    );

    expect(find.text('Send the invoice'), findsOneWidget);
    expect(find.textContaining('In Work'), findsOneWidget);
    expect(find.textContaining(kQuarantineReason), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Discard local change'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('Open hands the held row to the detail', (tester) async {
    final (_, _, opened) = await _pumpAttention(
      tester,
      tasks: [_row('t1', 'Send the invoice')],
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('attention-open-t1')));
    await settle(tester);

    expect(opened, ['t1']);
  });

  testWidgets('Retry re-queues the push, and the entry goes when it lands', (
    tester,
  ) async {
    late void Function(SyncStatusView) publish;
    final retried = <String>[];
    final result = await _pumpAttention(
      tester,
      tasks: [_row('t1', 'Send the invoice')],
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
      ),
      // Stand in for the scheduler: releasing the row and running a sync that
      // succeeds is exactly "the run reports nothing held any more".
      onRetry: (id) async {
        retried.add(id);
        publish(_status());
      },
    );
    publish = result.$2;

    expect(find.byKey(const Key('attention-held-t1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('attention-retry-t1')));
    await settle(tester);

    expect(retried, ['t1']);
    expect(
      find.byKey(const Key('attention-held-t1')),
      findsNothing,
      reason: 'the push landed, so the view has nothing left to show',
    );
    expect(find.byKey(const Key('attention-empty')), findsOneWidget);
  });

  testWidgets('Discard adopts the server copy and offers it back', (
    tester,
  ) async {
    final (fake, _, _) = await _pumpAttention(
      tester,
      tasks: [_row('t1', 'Send the invoise')],
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoise'),
        ],
      ),
    );
    fake.serverTitles['t1'] = 'Send the invoice';

    await tester.tap(find.byKey(const Key('attention-discard-t1')));
    await settle(tester);

    expect(
      fake.tasks.single.task.title,
      'Send the invoice',
      reason: "the row now holds Google's copy",
    );
    expect(fake.tasks.single.syncState, SyncState.clean);
    expect(
      find.byKey(const Key('attention-held-t1')),
      findsNothing,
      reason: 'nothing is held any more — the entry goes at once, offline too',
    );

    // …and the discard is reversible on the ordinary undo surface.
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);

    expect(fake.tasks.single.task.title, 'Send the invoise');
    expect(find.byKey(const Key('attention-held-t1')), findsOneWidget);
  });

  testWidgets('a conflicted pair shows both versions and the three ways out', (
    tester,
  ) async {
    await _pumpAttention(
      tester,
      tasks: [
        _row('t1', 'Book the venue', syncState: SyncState.clean, due: null),
        _row('t2', 'Book the venue hall (conflicted copy)'),
      ],
      status: _status(
        conflicts: const [ConflictLink(originalId: 't1', copyId: 't2')],
      ),
    );

    expect(find.text('On Google'), findsOneWidget);
    expect(find.text('Your version'), findsOneWidget);
    expect(find.textContaining('Book the venue hall'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(find.text('Keep theirs'), findsOneWidget);
    expect(find.text('Keep both'), findsOneWidget);
  });

  testWidgets('Keep theirs drops the copy; Undo brings the pair back', (
    tester,
  ) async {
    final (fake, _, _) = await _pumpAttention(
      tester,
      tasks: [
        _row('t1', 'Book the venue', syncState: SyncState.clean),
        _row('t2', 'Book the venue hall (conflicted copy)'),
      ],
      status: _status(
        conflicts: const [ConflictLink(originalId: 't1', copyId: 't2')],
      ),
    );

    await tester.tap(find.byKey(const Key('attention-keep-theirs-t2')));
    await settle(tester);

    expect(fake.tasks.map((t) => t.task.title), ['Book the venue']);
    expect(find.byKey(const Key('attention-conflict-t2')), findsNothing);

    await tester.tap(find.text('Undo'));
    await settle(tester);

    expect(fake.tasks, hasLength(2));
    expect(find.byKey(const Key('attention-conflict-t2')), findsOneWidget);
  });

  testWidgets(
    'Keep both takes the marker off and stops calling it a conflict',
    (tester) async {
      final (fake, _, _) = await _pumpAttention(
        tester,
        tasks: [
          _row('t1', 'Book the venue', syncState: SyncState.clean),
          _row('t2', 'Book the venue hall (conflicted copy)'),
        ],
        status: _status(
          conflicts: const [ConflictLink(originalId: 't1', copyId: 't2')],
        ),
      );

      await tester.tap(find.byKey(const Key('attention-keep-both-t2')));
      await settle(tester);

      expect(fake.tasks.map((t) => t.task.title), [
        'Book the venue',
        'Book the venue hall',
      ]);
      expect(find.byKey(const Key('attention-conflict-t2')), findsNothing);
      expect(find.byKey(const Key('attention-empty')), findsOneWidget);
    },
  );

  testWidgets('a held LIST offers only what a list can do (non-happy path)', (
    tester,
  ) async {
    // The cap holds list pushes too (#270). There is no task to open and no
    // base snapshot to revert to, so Retry is genuinely all there is — and an
    // inert Discard/Open would be worse than their absence.
    await _pumpAttention(
      tester,
      tasks: const [],
      status: _status(
        quarantined: const [QuarantinedRow(id: 'L1', title: 'Work')],
      ),
    );

    expect(find.byKey(const Key('attention-retry-L1')), findsOneWidget);
    expect(find.text('Discard local change'), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(find.textContaining('List ·'), findsOneWidget);
  });

  testWidgets('a dead session gets the header card and a sign-in', (
    tester,
  ) async {
    await _pumpAttention(
      tester,
      tasks: const [],
      status: _status(
        needsReauth: true,
        lastError: 'Google session expired — sign in again to resume sync',
      ),
    );

    expect(find.byKey(const Key('attention-header')), findsOneWidget);
    expect(find.text('Google session expired'), findsOneWidget);
    expect(find.byKey(const Key('attention-signin')), findsOneWidget);
    expect(
      find.textContaining('sign in again to resume sync'),
      findsOneWidget,
      reason: 'the sanitized cause is shown, never a raw provider string',
    );
  });

  testWidgets('a stuck sync gets the header card with Sync now', (
    tester,
  ) async {
    await _pumpAttention(
      tester,
      tasks: const [],
      status: _status(
        needsAttention: true,
        lastError:
            'Sync hit a local database problem — the details are in the '
            'log.',
      ),
    );

    expect(find.byKey(const Key('attention-sync-now')), findsOneWidget);
    expect(find.byKey(const Key('attention-signin')), findsNothing);
    expect(find.byKey(const Key('attention-properties')), findsOneWidget);
  });

  testWidgets('every repair action is a real touch target on a phone', (
    tester,
  ) async {
    // Touch has no hover and no precision: an action a finger cannot land on
    // is not an action. Asserted at phone width, where the three buttons of a
    // conflict card have the least room to keep their targets.
    await _pumpAttention(
      tester,
      tasks: [
        _row('t1', 'Send the invoice'),
        _row('c1', 'Book the venue', syncState: SyncState.clean),
        _row('c2', 'Book the venue hall (conflicted copy)'),
      ],
      status: _status(
        quarantined: const [
          QuarantinedRow(id: 't1', title: 'Send the invoice'),
        ],
        conflicts: const [ConflictLink(originalId: 'c1', copyId: 'c2')],
      ),
      size: const Size(400, 900),
    );

    for (final key in const [
      'attention-retry-t1',
      'attention-discard-t1',
      'attention-open-t1',
      'attention-keep-mine-c2',
      'attention-keep-theirs-c2',
      'attention-keep-both-c2',
    ]) {
      final box = tester.getSize(find.byKey(Key(key)));
      expect(
        box.height,
        greaterThanOrEqualTo(48),
        reason: '$key must be reachable by a finger',
      );
    }
  });

  testWidgets('a clean sync layer renders nothing to repair', (tester) async {
    await _pumpAttention(
      tester,
      tasks: [_row('t1', 'Send the invoice', syncState: SyncState.clean)],
      status: _status(),
    );

    expect(find.byKey(const Key('attention-list')), findsNothing);
    expect(find.byKey(const Key('attention-empty')), findsOneWidget);
    expect(find.text('Nothing needs attention'), findsOneWidget);
    expect(
      find.text('Add a task'),
      findsNothing,
      reason: 'this view creates nothing — the hint would point at nothing',
    );
  });
}
