import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/clock.dart';
import '../../core/failure.dart';
import '../../core/outcome.dart';
import '../../domain/model/tasks.dart';

/// One field write requested by [TaskContentAutosave].
///
/// Title and notes are written by separate field commands, so each write
/// keeps the task's other stored values (status, due date, notes or title)
/// exactly as the repository holds them inside its own transaction.
sealed class TaskContentChange {
  const TaskContentChange(this.taskId);

  final TaskId taskId;
}

final class TaskTitleChange extends TaskContentChange {
  const TaskTitleChange(super.taskId, this.title);

  final String title;
}

final class TaskNotesChange extends TaskContentChange {
  const TaskNotesChange(super.taskId, this.notes);

  final String? notes;
}

typedef TaskContentWriter = Future<Outcome<void>> Function(
  TaskContentChange change,
);

enum TaskContentSaveStatus {
  /// Everything the editor shows is stored.
  saved,

  /// The editor holds text that is not stored yet; a save is scheduled or
  /// waits for the keyboard composition to finish.
  pending,

  /// A write is running.
  saving,

  /// The latest write failed; the editor keeps the unsaved text.
  failed,
}

/// Snapshot of the text an inline task editor shows and how much of it is
/// stored.
@immutable
final class TaskContentDraft {
  const TaskContentDraft({
    required this.taskId,
    required this.title,
    required this.notes,
    required this.status,
    required this.failureMessage,
    required this.titleRejected,
  });

  final TaskId taskId;
  final String title;
  final String notes;
  final TaskContentSaveStatus status;

  /// Why the latest write failed, phrased for the user.
  final String? failureMessage;

  /// The title is empty, so it is never written; the stored title stays.
  final bool titleRejected;

  bool get hasUnsavedChanges => status != TaskContentSaveStatus.saved;
}

/// Saves inline title and notes edits for task details.
///
/// The policy lives here rather than in widgets so every detail surface
/// shares it and it outlives any one editor:
///
/// * every keystroke replaces the task's draft; a save runs once typing
///   pauses for [debounce], immediately on [flush] (focus change,
///   navigation, app backgrounding) and on [close] (editor disposal);
/// * while a keyboard composition is active the debounce does not save the
///   intermediate composing text, but an explicit flush saves what is shown;
/// * writes for one task run strictly one after another and each writes the
///   newest draft when it starts, so an older write can never land after,
///   and overwrite, a newer one; drafts are keyed by task, so text is never
///   applied to another task;
/// * a field is written only when it differs from the value this service
///   last knows to be stored, and an empty title is never written: notes
///   still save and the stored title stays;
/// * a failed write keeps the draft (also after the editor closes) until a
///   retry stores it, so returning to the task shows the unsaved text.
final class TaskContentAutosave extends ChangeNotifier {
  TaskContentAutosave({
    required this._write,
    required this._storedTask,
    required this._scheduler,
    required this._describeFailure,
    this.debounce = defaultDebounce,
  });

  static const defaultDebounce = Duration(milliseconds: 750);

  static const taskUnavailableMessage =
      'This task is no longer available, so the edits were not saved.';

  final TaskContentWriter _write;
  final CachedTask? Function(TaskId taskId) _storedTask;
  final MonotonicScheduler _scheduler;
  final String Function(Failure failure) _describeFailure;
  final Duration debounce;
  final _entries = <TaskId, _Entry>{};
  var _disposed = false;

  /// The draft for [taskId], or null when no editor holds unsaved text.
  TaskContentDraft? draft(TaskId taskId) => _entries[taskId]?.snapshot();

  /// Whether any task still has text that is not stored.
  bool get hasUnsavedChanges => _entries.values.any(
    (entry) => entry.status != TaskContentSaveStatus.saved,
  );

  /// Attaches an editor to [task] and returns the text it should show: the
  /// retained draft when an earlier edit was not stored, else [task]'s
  /// stored text.
  TaskContentDraft open(CachedTask task) {
    final entry = _entries.putIfAbsent(task.id, () => _Entry.from(task));
    if (entry.editors == 0 &&
        entry.isIdle &&
        entry.status == TaskContentSaveStatus.saved) {
      // A clean, idle draft from an earlier visit follows the store.
      entry.adoptStored(task, title: true, notes: true);
    }
    entry.editors += 1;
    return entry.snapshot();
  }

  /// Records the editor's current text for [taskId].
  ///
  /// [composing] reports an active keyboard composition: the save waits
  /// until it ends, or until an explicit [flush].
  void edit(
    TaskId taskId, {
    required String title,
    required String notes,
    bool composing = false,
  }) {
    final entry = _entries[taskId];
    if (entry == null || _disposed) return;
    final changed = entry.title != title || entry.notes != notes;
    if (!changed && entry.composing == composing) return;
    entry
      ..title = title
      ..notes = notes
      ..composing = composing;
    entry.timer?.cancel();
    entry.timer = null;
    if (entry.hasUnsavedText && !composing) {
      entry.timer = _scheduler.schedule(debounce, () {
        entry.timer = null;
        unawaited(_enqueue(entry));
      });
    }
    _notify();
  }

  /// Saves [taskId]'s draft now, including text still being composed, and
  /// completes once every write queued for it so far has finished.
  Future<void> flush(TaskId taskId) {
    final entry = _entries[taskId];
    if (entry == null) return Future<void>.value();
    return _enqueue(entry);
  }

  /// Saves every task's draft now.
  Future<void> flushAll() => Future.wait<void>(<Future<void>>[
    for (final entry in _entries.values.toList()) _enqueue(entry),
  ]);

  /// Saves again after a failure.
  Future<void> retry(TaskId taskId) => flush(taskId);

  /// Detaches an editor from [taskId] and saves what it showed.
  ///
  /// A rejected empty title is dropped, so the stored title stays; a draft
  /// whose write failed is kept for the next visit.
  Future<void> close(TaskId taskId) async {
    final entry = _entries[taskId];
    if (entry == null) return;
    entry.editors -= 1;
    if (entry.editors == 0 && entry.titleRejected) {
      entry.title = entry.storedTitle;
    }
    await _enqueue(entry);
    _releaseIfClean(entry);
  }

  /// Follows a newer stored version of an open task for fields the user
  /// has not edited in this session.
  ///
  /// A field that this service has written, or that holds unsaved text,
  /// keeps the editor's text: a snapshot of the store may still predate the
  /// latest write, and adopting it would show (and later save) stale text.
  /// Returns the draft when it changed.
  TaskContentDraft? reconcile(
    CachedTask task, {
    bool title = true,
    bool notes = true,
  }) {
    final entry = _entries[task.id];
    if (entry == null || !entry.isIdle) return null;
    final changed = entry.adoptStored(
      task,
      title: title && !entry.titleWritten && !entry.titleDirty,
      notes: notes && !entry.notesWritten && !entry.notesDirty,
    );
    // No notification: editors call this while rebuilding and apply the
    // returned draft themselves.
    return changed ? entry.snapshot() : null;
  }

  /// Records that [title] and [notes] were stored for [taskId] by another
  /// command (the explicit edit dialog), superseding the inline draft.
  void adoptSaved(TaskId taskId, {required String title, String? notes}) {
    final entry = _entries[taskId];
    if (entry == null) return;
    entry.timer?.cancel();
    entry
      ..timer = null
      ..storedTitle = title
      ..storedNotes = notes
      ..title = title
      ..notes = notes ?? ''
      ..failureMessage = null
      ..titleWritten = true
      ..notesWritten = true;
    _releaseIfClean(entry);
    _notify();
  }

  Future<void> _enqueue(_Entry entry) {
    entry.timer?.cancel();
    entry.timer = null;
    final next = entry.queue.then((_) => _writeLatest(entry));
    entry.queue = next;
    return next;
  }

  Future<void> _writeLatest(_Entry entry) async {
    if (_disposed) return;
    final title = entry.titleToWrite;
    final notes = entry.notesToWrite;
    if (title == null && notes == null) {
      if (entry.failureMessage != null) {
        entry.failureMessage = null;
        _notify();
      }
      return;
    }
    if (_storedTask(entry.taskId) == null) {
      entry.failureMessage = taskUnavailableMessage;
      _notify();
      return;
    }
    entry.writing = true;
    _notify();
    String? failure;
    if (title != null) {
      entry.titleWritten = true;
      failure = await _apply(TaskTitleChange(entry.taskId, title));
      if (failure == null) entry.storedTitle = title;
    }
    if (notes case (final String? value,)) {
      entry.notesWritten = true;
      final notesFailure = await _apply(TaskNotesChange(entry.taskId, value));
      if (notesFailure == null) entry.storedNotes = value;
      failure ??= notesFailure;
    }
    entry
      ..writing = false
      ..failureMessage = failure;
    _notify();
  }

  Future<String?> _apply(TaskContentChange change) async {
    try {
      return switch (await _write(change)) {
        Success<void>() => null,
        Failed<void>(:final failure) => _describeFailure(failure),
      };
    } on Object {
      return 'The task could not be saved safely.';
    }
  }

  void _releaseIfClean(_Entry entry) {
    if (entry.editors == 0 &&
        entry.isIdle &&
        entry.status == TaskContentSaveStatus.saved &&
        identical(_entries[entry.taskId], entry)) {
      _entries.remove(entry.taskId);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.timer?.cancel();
      entry.timer = null;
    }
    super.dispose();
  }
}

final class _Entry {
  _Entry.from(CachedTask task)
    : taskId = task.id,
      storedTitle = task.title,
      storedNotes = task.notes,
      title = task.title,
      notes = task.notes ?? '';

  final TaskId taskId;

  /// The values this service last knows to be stored.
  String storedTitle;
  String? storedNotes;

  /// The editor's current text.
  String title;
  String notes;

  bool composing = false;
  bool writing = false;
  bool titleWritten = false;
  bool notesWritten = false;
  int editors = 0;
  String? failureMessage;
  ScheduledTimer? timer;
  Future<void> queue = Future<void>.value();

  /// The user cleared a title that the store holds. A blank title that is
  /// already stored (Google allows one) is not an error.
  bool get titleRejected =>
      title.trim().isEmpty && storedTitle.trim().isNotEmpty;

  bool get isIdle => !writing && timer == null;

  /// Titles are written trimmed, so surrounding whitespace is not a change:
  /// viewing a task whose stored title is padded writes nothing.
  bool get titleDirty => title.trim() != storedTitle.trim();

  bool get notesDirty => _notesValue != storedNotes;

  /// Notes as stored: clearing the field clears the notes, while an
  /// intentionally empty stored note stays empty.
  String? get _notesValue =>
      notes.isEmpty ? (storedNotes == '' ? '' : null) : notes;

  String? get titleToWrite =>
      titleRejected || !titleDirty ? null : title.trim();

  /// A one-element record so that writing null (clearing notes) is
  /// distinguishable from writing nothing.
  (String?,)? get notesToWrite => notesDirty ? (_notesValue,) : null;

  bool get hasUnsavedText => titleToWrite != null || notesToWrite != null;

  TaskContentSaveStatus get status {
    if (failureMessage != null) return TaskContentSaveStatus.failed;
    if (writing) return TaskContentSaveStatus.saving;
    if (hasUnsavedText) return TaskContentSaveStatus.pending;
    return TaskContentSaveStatus.saved;
  }

  bool adoptStored(
    CachedTask task, {
    required bool title,
    required bool notes,
  }) {
    var changed = false;
    if (title && (storedTitle != task.title || this.title != task.title)) {
      storedTitle = task.title;
      this.title = task.title;
      changed = true;
    }
    final storedText = task.notes ?? '';
    if (notes && (storedNotes != task.notes || this.notes != storedText)) {
      storedNotes = task.notes;
      this.notes = storedText;
      changed = true;
    }
    return changed;
  }

  TaskContentDraft snapshot() => TaskContentDraft(
    taskId: taskId,
    title: title,
    notes: notes,
    status: status,
    failureMessage: failureMessage,
    titleRejected: titleRejected,
  );
}
