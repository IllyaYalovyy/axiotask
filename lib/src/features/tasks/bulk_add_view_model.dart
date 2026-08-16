import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outcome.dart';
import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/bulk_capture.dart';
import '../../domain/repository/tasks_repository.dart';

final class BulkAddState {
  const BulkAddState({
    required this.input,
    required this.mode,
    required this.preview,
    required this.targetId,
    required this.targetName,
    required this.isSubmitting,
    required this.failureMessage,
    required this.successMessage,
    required this.acceptedEntries,
  });

  final String input;
  final BulkCaptureMode mode;
  final BulkCapturePreview preview;
  final TaskListId? targetId;
  final String? targetName;
  final bool isSubmitting;
  final String? failureMessage;
  final String? successMessage;
  final List<BulkCaptureEntry> acceptedEntries;
}

final class BulkAddViewModel extends ChangeNotifier {
  BulkAddViewModel({
    required this.accountId,
    required this.repository,
    required this.lists,
    required this.defaultTarget,
    this.localEditCommitted,
  }) {
    _replaceState();
  }

  final AccountId accountId;
  final BulkTasksRepository repository;
  final List<CachedTaskList> Function() lists;
  final TaskListId? Function() defaultTarget;
  final Future<void> Function()? localEditCommitted;

  String _input = '';
  BulkCaptureMode _mode = BulkCaptureMode.lines;
  TaskListId? _selectedTarget;
  bool _isSubmitting = false;
  String? _failureMessage;
  String? _successMessage;
  List<BulkCaptureEntry> _acceptedEntries = const <BulkCaptureEntry>[];
  Future<void>? _submission;
  late BulkAddState _state;

  BulkAddState get state => _state;

  void refreshContext() => _replaceState();

  void setInput(String value) {
    _input = value;
    _failureMessage = null;
    _successMessage = null;
    _acceptedEntries = const <BulkCaptureEntry>[];
    _replaceState();
  }

  void setMode(BulkCaptureMode value) {
    _mode = value;
    _failureMessage = null;
    _successMessage = null;
    _acceptedEntries = const <BulkCaptureEntry>[];
    _replaceState();
  }

  void selectTarget(TaskListId value) {
    if (!lists().any((list) => list.id == value)) return;
    _selectedTarget = value;
    _failureMessage = null;
    _replaceState();
  }

  Future<void> submit() {
    final existing = _submission;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _submit().whenComplete(() {
      if (identical(_submission, operation)) _submission = null;
    });
    _submission = operation;
    return operation;
  }

  Future<void> _submit() async {
    final target = _resolvedTarget(lists());
    if (target == null) {
      _failureMessage = 'Choose an available Google task list.';
      _replaceState();
      return;
    }
    final preview = parseBulkCapture(_input, mode: _mode);
    if (!preview.isValid) {
      _failureMessage = _messageFor(preview.failure!);
      _replaceState();
      return;
    }
    _isSubmitting = true;
    _failureMessage = null;
    _successMessage = null;
    _replaceState();
    try {
      final result = await repository.createTasks(
        BulkCreateTasksCommand(
          accountId: accountId,
          taskListId: target.id,
          entries: preview.entries,
        ),
      );
      switch (result) {
        case Success<List<TaskId>>(:final value):
          await localEditCommitted?.call();
          _acceptedEntries = preview.entries;
          _input = '';
          _successMessage =
              '${value.length} ${value.length == 1 ? 'task' : 'tasks'} saved locally and waiting for Google.';
        case Failed<List<TaskId>>():
          _failureMessage =
              'No tasks were saved. Review the input and try again.';
      }
    } finally {
      _isSubmitting = false;
      _replaceState();
    }
  }

  CachedTaskList? _resolvedTarget(List<CachedTaskList> availableLists) {
    final wanted = _selectedTarget ?? defaultTarget();
    for (final list in availableLists) {
      if (list.id == wanted) return list;
    }
    return null;
  }

  void _replaceState() {
    final target = _resolvedTarget(lists());
    _state = BulkAddState(
      input: _input,
      mode: _mode,
      preview: parseBulkCapture(_input, mode: _mode),
      targetId: target?.id,
      targetName: target?.title,
      isSubmitting: _isSubmitting,
      failureMessage: _failureMessage,
      successMessage: _successMessage,
      acceptedEntries: _acceptedEntries,
    );
    notifyListeners();
  }
}

String _messageFor(BulkCaptureFailure failure) => switch (failure.code) {
  'bulk_capture.empty' => 'Paste at least one task.',
  'bulk_capture.too_many_tasks' =>
    'Paste at most $maxBulkCaptureTasks tasks at once.',
  'bulk_capture.input_too_large' => 'The pasted text is too large.',
  'bulk_capture.title_too_long' =>
    'Task ${failure.entryNumber} has a title longer than $maxBulkCaptureTitleCharacters characters.',
  'bulk_capture.notes_too_long' =>
    'Task ${failure.entryNumber} has notes longer than $maxBulkCaptureNotesCharacters characters.',
  'bulk_capture.malformed_text' =>
    'Task ${failure.entryNumber} contains unsupported control characters.',
  _ => 'The pasted text is invalid.',
};
