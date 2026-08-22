import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/outcome.dart';
import '../../domain/commands/task_commands.dart';
import '../../domain/model/tasks.dart';
import '../../domain/policy/date_workflow.dart';
import '../../domain/policy/quick_capture.dart';
import '../../domain/repository/tasks_repository.dart';

final class QuickAddState {
  const QuickAddState({
    required this.input,
    required this.previewTitle,
    required this.previewDue,
    required this.hasParsedDate,
    required this.targetId,
    required this.targetName,
    required this.destinationRequired,
    required this.isSubmitting,
    required this.failureMessage,
    required this.successMessage,
    required this.hasExplicitDue,
  });

  final String input;
  final String previewTitle;
  final TaskDate? previewDue;
  final bool hasParsedDate;
  final TaskListId? targetId;
  final String? targetName;
  final bool destinationRequired;
  final bool isSubmitting;
  final String? failureMessage;
  final String? successMessage;
  final bool hasExplicitDue;
}

final class QuickAddViewModel extends ChangeNotifier {
  QuickAddViewModel({
    required this.accountId,
    required this.repository,
    required this.today,
    required this.lists,
    required this.defaultTarget,
    this.destinationRequired,
    this.defaultDue,
    this.localEditCommitted,
    this.created,
  }) {
    _replaceState();
  }

  final AccountId accountId;
  final TasksRepository repository;
  final TaskDate Function() today;
  final List<CachedTaskList> Function() lists;
  final TaskListId? Function() defaultTarget;
  final bool Function()? destinationRequired;
  final TaskDate? Function()? defaultDue;
  final Future<void> Function()? localEditCommitted;
  final Future<void> Function(TaskListId target, TaskDate? due)? created;

  String _input = '';
  String? _dismissedInput;
  TaskListId? _selectedTarget;
  TaskDate? _selectedDue;
  bool _hasSelectedDue = false;
  bool _isSubmitting = false;
  String? _failureMessage;
  String? _successMessage;
  Future<void>? _submission;
  late QuickAddState _state;

  QuickAddState get state => _state;

  void refreshContext() => _replaceState();

  void setInput(String value) {
    _input = value;
    if (_dismissedInput != value) _dismissedInput = null;
    _failureMessage = null;
    _successMessage = null;
    _replaceState();
  }

  void selectTarget(TaskListId value) {
    if (!lists().any((list) => list.id == value)) return;
    _selectedTarget = value;
    _failureMessage = null;
    _successMessage = null;
    _replaceState();
  }

  void selectDueShortcut(DateShortcut shortcut) {
    _hasSelectedDue = true;
    _selectedDue = resolveDateShortcut(today(), shortcut);
    _failureMessage = null;
    _successMessage = null;
    _replaceState();
  }

  void dismissDatePreview() {
    final parsed = parseQuickCapture(_input, today: today());
    if (!parsed.hasDatePreview) return;
    _dismissedInput = _input;
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
    final availableLists = lists();
    final target = _resolvedTarget(availableLists);
    if (target == null) {
      _failureMessage = 'Choose an available Google task list.';
      _replaceState();
      return;
    }
    final parsed = parseQuickCapture(_input, today: today());
    final useParsed = parsed.hasDatePreview && _dismissedInput != _input;
    final title = useParsed ? parsed.title : _input.trim();
    final due = _resolvedDue(parsed, useParsed);
    if (title.isEmpty) {
      _failureMessage = 'Enter a task title.';
      _replaceState();
      return;
    }
    _isSubmitting = true;
    _failureMessage = null;
    _successMessage = null;
    _replaceState();
    try {
      final result = await repository.createTask(
        CreateTaskCommand(
          accountId: accountId,
          taskListId: target.id,
          title: title,
          due: due,
        ),
      );
      switch (result) {
        case Success<TaskId>():
          await localEditCommitted?.call();
          await created?.call(target.id, due);
          _input = '';
          _dismissedInput = null;
          _selectedDue = null;
          _hasSelectedDue = false;
          _successMessage = 'Saved locally. Waiting for Google.';
        case Failed<TaskId>():
          _failureMessage = 'The task could not be saved safely.';
      }
    } finally {
      _isSubmitting = false;
      _replaceState();
    }
  }

  CachedTaskList? _resolvedTarget(List<CachedTaskList> availableLists) {
    final selected = _selectedTarget;
    if (selected != null) {
      for (final list in availableLists) {
        if (list.id == selected) return list;
      }
      return null;
    }
    final fallback = defaultTarget();
    for (final list in availableLists) {
      if (list.id == fallback) return list;
    }
    return null;
  }

  TaskDate? _resolvedDue(QuickCaptureParseResult parsed, bool useParsed) {
    if (_hasSelectedDue) return _selectedDue;
    return useParsed ? parsed.due : defaultDue?.call();
  }

  void _replaceState() {
    final parsed = parseQuickCapture(_input, today: today());
    final useParsed = parsed.hasDatePreview && _dismissedInput != _input;
    final availableLists = lists();
    final target = _resolvedTarget(availableLists);
    _state = QuickAddState(
      input: _input,
      previewTitle: useParsed ? parsed.title : _input.trim(),
      previewDue: _resolvedDue(parsed, useParsed),
      hasParsedDate: useParsed,
      targetId: target?.id,
      targetName: target?.title,
      destinationRequired: destinationRequired?.call() ?? false,
      isSubmitting: _isSubmitting,
      failureMessage: _failureMessage,
      successMessage: _successMessage,
      hasExplicitDue: _hasSelectedDue,
    );
    notifyListeners();
  }
}
