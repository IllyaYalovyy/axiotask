// The pure half of the "Needs attention" view (#296): which rows the sync layer
// has left for the user to repair.
//
// Protects the rule the conflicted-copy half of the view is built on: a fork is
// a PAIR only while both of its rows are still there and the copy still carries
// the marker. The two rows are linked by what the engine RECORDED when it forked
// them, never by their text — the copy holds the local edit and the original
// holds Google's, so after a real 412 the two titles normally differ and a
// title-matching rule would pair nothing at all (or, worse, pair a row the
// conflict never touched).
//
// An entry that no longer resolves is dropped rather than shown: none of Keep
// mine / Keep theirs / Keep both could act on it, and a view whose promise is
// that it EMPTIES cannot carry a row that nothing can clear.

import 'package:axiotask/src/model/attention.dart';
import 'package:axiotask/src/model/task.dart';
import 'package:axiotask/src/model/task_list.dart';
import 'package:axiotask/src/store/stored.dart';
import 'package:flutter_test/flutter_test.dart';

StoredTask row(
  String id,
  String title, {
  String listId = 'L1',
  SyncState syncState = SyncState.clean,
}) => StoredTask(
  task: Task(
    id: id,
    position: '1',
    title: title,
    status: TaskStatus.needsAction,
    updated: 'u',
  ),
  listId: listId,
  syncState: syncState,
  localUpdated: 'u',
);

const _link = ConflictLink(originalId: 't1', copyId: 't2');

const _inbox = StoredTaskList(
  list: TaskList(id: 'L1', title: 'Inbox', etag: 'e', updated: 'u'),
  syncState: SyncState.clean,
  localUpdated: 'u',
);

AttentionItems items({
  List<StoredTask> tasks = const [],
  List<QuarantinedRow> quarantined = const [],
  List<ConflictLink> links = const [],
  bool needsReauth = false,
  bool needsAttention = false,
  String? syncMessage,
}) => attentionItems(
  tasks: tasks,
  lists: const [_inbox],
  quarantined: quarantined,
  links: links,
  needsReauth: needsReauth,
  needsAttention: needsAttention,
  syncMessage: syncMessage,
);

void main() {
  test('a recorded fork pairs the two rows even when their text diverged', () {
    final pairs = conflictedPairs(
      [
        row('t1', 'their-version'),
        row('t2', 'local-edit (conflicted copy)', syncState: SyncState.dirty),
        row('t3', 'Unrelated'),
      ],
      const [_link],
    );

    expect(pairs, hasLength(1));
    expect(pairs.single.original.task.id, 't1');
    expect(pairs.single.copy.task.id, 't2');
    expect(
      pairs.single.title,
      'their-version',
      reason: 'the pair is named by the row Google holds',
    );
  });

  test('a fork whose copy is gone is no longer a conflict', () {
    final pairs = conflictedPairs([row('t1', 'their-version')], const [_link]);

    expect(
      pairs,
      isEmpty,
      reason: 'Keep theirs deleted the copy — there is nothing left to decide',
    );
  });

  test('a fork whose original was deleted is no longer a conflict', () {
    final pairs = conflictedPairs(
      [
        row('t1', 'their-version', syncState: SyncState.deleted),
        row('t2', 'local-edit (conflicted copy)', syncState: SyncState.dirty),
      ],
      const [_link],
    );

    expect(pairs, isEmpty, reason: 'a tombstone is not a row');
  });

  test('a copy that no longer carries the marker is an ordinary task', () {
    final pairs = conflictedPairs(
      [
        row('t1', 'their-version'),
        row('t2', 'local-edit', syncState: SyncState.dirty),
      ],
      const [_link],
    );

    expect(
      pairs,
      isEmpty,
      reason:
          'Keep both (or a rename) took the marker off — the user has already '
          'said these are two tasks',
    );
  });

  test('an unrecorded "(conflicted copy)" row is not paired by its title', () {
    final pairs = conflictedPairs([
      row('t1', 'Buy milk'),
      row('t2', 'Buy milk (conflicted copy)', syncState: SyncState.dirty),
    ], const []);

    expect(
      pairs,
      isEmpty,
      reason:
          'without the recorded fork there is no way to know WHICH row this '
          'copy came from — pairing on a matching title would guess',
    );
  });

  test('the same fork recorded twice yields one pair', () {
    final pairs = conflictedPairs(
      [
        row('t1', 'their-version'),
        row('t2', 'local-edit (conflicted copy)', syncState: SyncState.dirty),
      ],
      const [_link, _link],
    );

    expect(pairs, hasLength(1));
  });

  group('what the view holds', () {
    test('nothing needs attention when the sync layer is clean', () {
      final view = items(tasks: [row('t1', 'Buy milk')]);

      expect(view.isEmpty, isTrue);
      expect(view.count, 0, reason: 'no badge, and no entry in the sidebar');
    });

    test('a held row is listed with the list it lives in', () {
      final view = items(
        tasks: [row('t1', 'Buy milk', syncState: SyncState.dirty)],
        quarantined: const [QuarantinedRow(id: 't1', title: 'Buy milk')],
      );

      expect(view.count, 1);
      final held = view.held.single;
      expect(held.title, 'Buy milk');
      expect(held.listTitle, 'Inbox');
      expect(held.task!.task.id, 't1');
    });

    test('a held row whose change is already gone is dropped', () {
      // Discard (or a later successful push) leaves the row CLEAN. Nothing is
      // held any more, and the entry must not survive until the next run
      // republishes the status — offline, that run may never come.
      final view = items(
        tasks: [row('t1', 'Buy milk')],
        quarantined: const [QuarantinedRow(id: 't1', title: 'Buy milk')],
      );

      expect(view.isEmpty, isTrue);
    });

    test('a held row that no longer exists is dropped', () {
      final view = items(
        quarantined: const [QuarantinedRow(id: 't1', title: 'Buy milk')],
      );

      expect(view.isEmpty, isTrue);
    });

    test('a held LIST is listed too, with no task behind it', () {
      // The cap holds list pushes as well as task pushes (#270). Such an entry
      // has no task to open or revert, so it says so rather than vanishing —
      // the status line names it either way.
      final view = items(
        quarantined: const [QuarantinedRow(id: 'L1', title: 'Inbox')],
      );

      expect(view.count, 1);
      expect(view.held.single.task, isNull);
      expect(view.held.single.listTitle, isEmpty);
    });

    test('a dead session is one entry — the header card', () {
      final view = items(needsReauth: true);

      expect(view.count, 1);
      expect(view.hasHeader, isTrue);
      expect(view.held, isEmpty);
    });

    test('the header counts once, however many rows are also held', () {
      final view = items(
        tasks: [
          row('t1', 'their-version'),
          row('t2', 'local-edit (conflicted copy)', syncState: SyncState.dirty),
          row('t9', 'Buy milk', syncState: SyncState.dirty),
        ],
        quarantined: const [QuarantinedRow(id: 't9', title: 'Buy milk')],
        links: const [_link],
        needsAttention: true,
        syncMessage: 'Sync hit a local database problem.',
      );

      expect(view.count, 3, reason: '1 held + 1 conflict + 1 header card');
      expect(view.conflicts, hasLength(1));
      expect(view.syncMessage, 'Sync hit a local database problem.');
    });
  });

  test('stripping the marker gives the title a resolution keeps', () {
    expect(strippedCopyTitle('Buy milk (conflicted copy)'), 'Buy milk');
    expect(
      strippedCopyTitle('Buy milk'),
      'Buy milk',
      reason: 'a title without the marker is returned untouched',
    );
  });
}
