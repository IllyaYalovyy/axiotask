import 'dart:async';

import 'package:axiotask/src/core/clock.dart';
import 'package:axiotask/src/core/failure.dart';
import 'package:axiotask/src/core/outcome.dart';
import 'package:axiotask/src/domain/model/tasks.dart';
import 'package:axiotask/src/features/tasks/task_content_autosave.dart';
import 'package:flutter_test/flutter_test.dart';

const _account = AccountId(1);
const _list = TaskListId(1);
const _taskA = TaskId(11);
const _taskB = TaskId(12);
const _debounce = TaskContentAutosave.defaultDebounce;

void main() {
  late ManualClock clock;
  late _Store store;
  late TaskContentAutosave autosave;

  setUp(() {
    clock = ManualClock(DateTime.utc(2026, 11, 17, 12));
    store = _Store(<CachedTask>[
      _task(_taskA, 'Alpha', notes: 'Alpha notes'),
      _task(_taskB, 'Beta'),
    ]);
    autosave = TaskContentAutosave(
      write: store.write,
      storedTask: store.task,
      scheduler: clock,
      describeFailure: (failure) => 'Storage refused ${failure.code}.',
    );
  });

  tearDown(() => autosave.dispose());

  test('rapid typing saves once, after typing pauses', () async {
    autosave.open(store.task(_taskA)!);
    for (final title in <String>['A', 'Al', 'Alp', 'Alph', 'Alpha 2']) {
      autosave.edit(_taskA, title: title, notes: 'Alpha notes');
      clock.advance(_debounce ~/ 2);
    }
    await pumpEventQueue();
    expect(store.writes, isEmpty, reason: 'each keystroke restarts the wait');
    expect(autosave.draft(_taskA)?.status, TaskContentSaveStatus.pending);

    clock.advance(_debounce);
    await pumpEventQueue();
    expect(store.writes, <String>['11 title Alpha 2']);
    expect(store.task(_taskA)!.title, 'Alpha 2');
    expect(
      store.task(_taskA)!.notes,
      'Alpha notes',
      reason: 'an unchanged field is not written',
    );
    expect(autosave.draft(_taskA)?.status, TaskContentSaveStatus.saved);
  });

  test('a slow write never lands after, or overwrites, newer text', () async {
    autosave.open(store.task(_taskA)!);
    store.hold();
    autosave.edit(_taskA, title: 'First', notes: 'Alpha notes');
    unawaited(autosave.flush(_taskA));
    await pumpEventQueue();
    expect(store.pending, 1);
    expect(autosave.draft(_taskA)?.status, TaskContentSaveStatus.saving);

    // The user keeps typing (and returns to the original title) while the
    // first write is still running.
    autosave.edit(_taskA, title: 'Alpha', notes: 'Newer notes');
    final second = autosave.flush(_taskA);
    await pumpEventQueue();
    expect(store.pending, 1, reason: 'writes for one task never overlap');

    store.release();
    await pumpEventQueue();
    store.release();
    await pumpEventQueue();
    store.releaseAll();
    await second;

    expect(store.writes, <String>[
      '11 title First',
      '11 title Alpha',
      '11 notes Newer notes',
    ]);
    expect(store.task(_taskA)!.title, 'Alpha');
    expect(store.task(_taskA)!.notes, 'Newer notes');
    expect(autosave.draft(_taskA)?.status, TaskContentSaveStatus.saved);
  });

  test('a stale store snapshot is not adopted over written text', () async {
    final original = store.task(_taskA)!;
    autosave.open(original);
    autosave.edit(_taskA, title: 'Written', notes: 'Alpha notes');
    await autosave.flush(_taskA);
    expect(store.task(_taskA)!.title, 'Written');

    // The view model may still deliver a snapshot taken before the write.
    expect(autosave.reconcile(original), isNull);
    expect(autosave.draft(_taskA)?.title, 'Written');

    // An unedited field follows a genuinely newer stored value.
    final synced = original.copyWith(title: 'Written', notes: 'From sync');
    expect(autosave.reconcile(synced)?.notes, 'From sync');
    expect(store.writes, <String>['11 title Written']);
  });

  test('switching tasks keeps each draft with its own task', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Alpha edited', notes: 'Alpha notes');
    store.hold();
    // Opening B closes A's editor while its save is still pending.
    final closingA = autosave.close(_taskA);
    autosave.open(store.task(_taskB)!);
    autosave.edit(_taskB, title: 'Beta edited', notes: 'Beta notes');
    clock.advance(_debounce);
    await pumpEventQueue();
    store.releaseAll();
    await closingA;
    await autosave.flush(_taskB);
    store.releaseAll();
    await pumpEventQueue();

    expect(store.task(_taskA)!.title, 'Alpha edited');
    expect(store.task(_taskA)!.notes, 'Alpha notes');
    expect(store.task(_taskB)!.title, 'Beta edited');
    expect(store.task(_taskB)!.notes, 'Beta notes');
    expect(
      store.writes,
      unorderedEquals(<String>[
        '11 title Alpha edited',
        '12 title Beta edited',
        '12 notes Beta notes',
      ]),
    );
    expect(autosave.draft(_taskA), isNull, reason: 'a stored draft is freed');
  });

  test('a failed write keeps the text, explains it and retries', () async {
    autosave.open(store.task(_taskA)!);
    // Both fields fail on the first save and again when leaving the task.
    store.failNext = 4;
    autosave.edit(_taskA, title: 'Unsaved title', notes: 'Unsaved notes');
    await autosave.flush(_taskA);

    var draft = autosave.draft(_taskA)!;
    expect(draft.status, TaskContentSaveStatus.failed);
    expect(draft.failureMessage, 'Storage refused task.persistence_failed.');
    expect(store.task(_taskA)!.title, 'Alpha');

    // Leaving the task keeps the unsaved text for the next visit.
    await autosave.close(_taskA);
    draft = autosave.open(store.task(_taskA)!);
    expect(draft.title, 'Unsaved title');
    expect(draft.notes, 'Unsaved notes');
    expect(draft.status, TaskContentSaveStatus.failed);

    await autosave.retry(_taskA);
    expect(autosave.draft(_taskA)?.status, TaskContentSaveStatus.saved);
    expect(store.task(_taskA)!.title, 'Unsaved title');
    expect(store.task(_taskA)!.notes, 'Unsaved notes');
  });

  test('a throwing writer reports a failure instead of escaping', () async {
    autosave.open(store.task(_taskA)!);
    store.throwNext = true;
    autosave.edit(_taskA, title: 'Alpha', notes: 'Changed');
    await autosave.flush(_taskA);
    expect(
      autosave.draft(_taskA)?.failureMessage,
      'The task could not be saved safely.',
    );
  });

  test('an empty title is rejected while the notes still save', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: '   ', notes: 'Notes kept');
    expect(autosave.draft(_taskA)?.titleRejected, isTrue);
    clock.advance(_debounce);
    await pumpEventQueue();

    expect(store.writes, <String>['11 notes Notes kept']);
    expect(store.task(_taskA)!.title, 'Alpha');
    expect(store.task(_taskA)!.notes, 'Notes kept');

    // Leaving with the empty title keeps the stored title and frees the
    // draft, so the next visit shows the stored title.
    await autosave.close(_taskA);
    expect(autosave.draft(_taskA), isNull);
    expect(autosave.open(store.task(_taskA)!).title, 'Alpha');
    expect(store.writes, hasLength(1));
  });

  test('titles are trimmed and cleared notes are cleared', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: '  Spaced  ', notes: '');
    await autosave.flush(_taskA);
    expect(store.task(_taskA)!.title, 'Spaced');
    expect(store.task(_taskA)!.notes, isNull);

    // An intentionally empty stored note stays empty, not cleared.
    store.replace(_task(_taskB, 'Beta', notes: ''));
    autosave.open(store.task(_taskB)!);
    autosave.edit(_taskB, title: 'Beta', notes: '');
    await autosave.flush(_taskB);
    expect(store.writes, <String>['11 title Spaced', '11 notes null']);
  });

  test('keyboard composition defers the debounce but not a flush', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(
      _taskA,
      title: 'Alpha かな',
      notes: 'Alpha notes',
      composing: true,
    );
    clock.advance(_debounce * 4);
    await pumpEventQueue();
    expect(store.writes, isEmpty, reason: 'composing text is not saved early');

    // Composition ends with the committed text: the debounce saves it.
    autosave.edit(_taskA, title: 'Alpha 仮名', notes: 'Alpha notes');
    clock.advance(_debounce);
    await pumpEventQueue();
    expect(store.writes, <String>['11 title Alpha 仮名']);

    // Leaving while composing still stores what the field shows.
    autosave.edit(
      _taskA,
      title: 'Alpha 仮名 x',
      notes: 'Alpha notes',
      composing: true,
    );
    await autosave.close(_taskA);
    expect(store.task(_taskA)!.title, 'Alpha 仮名 x');
  });

  test('disposal cancels the debounce and starts no write', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Never written', notes: 'Alpha notes');
    autosave.dispose();
    clock.advance(_debounce * 2);
    await pumpEventQueue();
    expect(store.writes, isEmpty);
    // tearDown disposes again; replace with a fresh instance.
    autosave = TaskContentAutosave(
      write: store.write,
      storedTask: store.task,
      scheduler: clock,
      describeFailure: (failure) => failure.code,
    );
  });

  test('a deleted task reports that the edit could not be saved', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Orphan', notes: 'Alpha notes');
    store.remove(_taskA);
    await autosave.flush(_taskA);
    expect(
      autosave.draft(_taskA)?.failureMessage,
      TaskContentAutosave.taskUnavailableMessage,
    );
    expect(store.writes, isEmpty);
  });

  test(
    'an untouched padded or blank stored title is never rewritten',
    () async {
      for (final stored in <String>['Alpha ', ' Alpha', '', '   ']) {
        store.replace(_task(_taskA, stored, notes: 'Alpha notes'));
        var draft = autosave.open(store.task(_taskA)!);
        expect(draft.title, stored);
        expect(draft.status, TaskContentSaveStatus.saved, reason: '"$stored"');
        expect(draft.titleRejected, isFalse, reason: '"$stored"');
        // The editor reports its unchanged text, as on every rebuild.
        autosave.edit(_taskA, title: stored, notes: 'Alpha notes');
        clock.advance(_debounce * 2);
        await autosave.flush(_taskA);
        await autosave.flushAll();
        draft = autosave.draft(_taskA)!;
        expect(draft.status, TaskContentSaveStatus.saved, reason: '"$stored"');
        expect(draft.titleRejected, isFalse, reason: '"$stored"');
        await autosave.close(_taskA);
        expect(autosave.draft(_taskA), isNull, reason: '"$stored"');
      }
      expect(store.writes, isEmpty, reason: 'viewing a task changes nothing');
    },
  );

  test('a padded title is written trimmed only after a real edit', () async {
    store.replace(_task(_taskA, ' Alpha ', notes: 'Alpha notes'));
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Alpha', notes: 'Alpha notes');
    await autosave.flush(_taskA);
    expect(
      store.writes,
      isEmpty,
      reason: 'an edit of surrounding whitespace only is not a change',
    );
    autosave.edit(_taskA, title: ' Alpha 2 ', notes: 'Alpha notes');
    await autosave.close(_taskA);
    expect(store.writes, <String>['11 title Alpha 2']);
  });

  test('an untouched blank stored title is not an error', () async {
    store.replace(_task(_taskA, '', notes: 'Alpha notes'));
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: '', notes: 'Notes only');
    expect(autosave.draft(_taskA)?.titleRejected, isFalse);
    await autosave.flush(_taskA);
    expect(store.writes, <String>['11 notes Notes only']);
    autosave.edit(_taskA, title: 'Named at last', notes: 'Notes only');
    await autosave.flush(_taskA);
    expect(store.writes.last, '11 title Named at last');
  });

  test('a padded dialog title leaves the draft saved', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Typed', notes: 'Alpha notes');
    autosave.adoptSaved(_taskA, title: '  Dialog title ', notes: 'Alpha notes');
    clock.advance(_debounce * 2);
    await autosave.flush(_taskA);
    await autosave.close(_taskA);
    expect(store.writes, isEmpty);
    expect(autosave.draft(_taskA), isNull, reason: 'clean and released');
  });

  test('an explicit dialog save supersedes the inline draft', () async {
    autosave.open(store.task(_taskA)!);
    autosave.edit(_taskA, title: 'Typed', notes: 'Alpha notes');
    autosave.adoptSaved(_taskA, title: 'From dialog', notes: null);
    clock.advance(_debounce * 2);
    await pumpEventQueue();
    expect(store.writes, isEmpty, reason: 'the pending inline save is gone');
    final draft = autosave.draft(_taskA)!;
    expect(draft.title, 'From dialog');
    expect(draft.notes, '');
    expect(draft.status, TaskContentSaveStatus.saved);
  });
}

CachedTask _task(TaskId id, String title, {String? notes}) => CachedTask(
  id: id,
  accountId: _account,
  taskListId: _list,
  parentTaskId: null,
  remoteId: null,
  title: title,
  notes: notes,
  status: TaskStatus.needsAction,
  due: null,
);

/// In-memory store with controllable write latency and failures.
final class _Store {
  _Store(List<CachedTask> tasks) : _tasks = {for (final t in tasks) t.id: t};

  final Map<TaskId, CachedTask> _tasks;
  final writes = <String>[];
  final _held = <Completer<void>>[];
  var _holding = false;
  var failNext = 0;
  var throwNext = false;

  int get pending => _held.length;

  CachedTask? task(TaskId id) => _tasks[id];

  void replace(CachedTask task) => _tasks[task.id] = task;

  void remove(TaskId id) => _tasks.remove(id);

  void hold() => _holding = true;

  void release() {
    if (_held.isNotEmpty) _held.removeAt(0).complete();
  }

  void releaseAll() {
    _holding = false;
    while (_held.isNotEmpty) {
      _held.removeAt(0).complete();
    }
  }

  Future<Outcome<void>> write(TaskContentChange change) async {
    if (_holding) {
      final gate = Completer<void>();
      _held.add(gate);
      await gate.future;
    }
    if (throwNext) {
      throwNext = false;
      throw StateError('synthetic writer crash');
    }
    if (failNext > 0) {
      failNext -= 1;
      return const Outcome<void>.failure(
        Failure(
          code: 'task.persistence_failed',
          category: FailureCategory.internal,
          operation: FailureOperation.write,
          retry: RetryClassification.transient,
          impact: 'The task was not saved.',
          safeSummary: 'Synthetic persistence failure.',
        ),
      );
    }
    final current = _tasks[change.taskId]!;
    switch (change) {
      case TaskTitleChange(:final title):
        writes.add('${change.taskId.value} title $title');
        _tasks[change.taskId] = current.copyWith(title: title);
      case TaskNotesChange(:final notes):
        writes.add('${change.taskId.value} notes $notes');
        _tasks[change.taskId] = current.copyWith(notes: notes);
    }
    return const Outcome<void>.success(null);
  }
}
