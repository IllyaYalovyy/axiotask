import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../domain/model/tasks.dart';
import '../task_content_autosave.dart';
import '../task_detail_view_model.dart';

/// The inline title and notes fields of one task's details.
final class TaskContentFields {
  const TaskContentFields({required this.title, required this.notes});

  final Widget title;
  final Widget notes;
}

/// Edits [task]'s title and notes in place; the shared
/// [TaskContentAutosave] decides when and what to store.
///
/// The widget only mirrors text into the autosave and reports the moments a
/// save must happen now: a field losing focus, the app leaving the
/// foreground, and the editor's disposal (Back, another task, closing the
/// details). It never writes the task itself. Key it by task id so that a
/// different task gets a new editor rather than this one's text.
final class TaskContentEditor extends StatefulWidget {
  const TaskContentEditor({
    required this.viewModel,
    required this.task,
    required this.builder,
    this.touchLayout = false,
    super.key,
  });

  final TaskDetailViewModel viewModel;
  final CachedTask task;
  final bool touchLayout;
  final Widget Function(BuildContext context, TaskContentFields fields) builder;

  @override
  State<TaskContentEditor> createState() => _TaskContentEditorState();
}

final class _TaskContentEditorState extends State<TaskContentEditor> {
  // Captured once: the detail view model is rebuilt with its pane, while
  // the autosave and the task identity stay fixed for this editor.
  late final TaskContentAutosave _autosave = widget.viewModel.contentAutosave;
  late final TaskId _taskId = widget.task.id;
  late final TextEditingController _title;
  late final TextEditingController _notes;
  final _titleFocus = FocusNode(debugLabel: 'task detail title');
  final _notesFocus = FocusNode(debugLabel: 'task detail notes');
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final draft = _autosave.open(widget.task);
    _title = TextEditingController(text: draft.title)..addListener(_edited);
    _notes = TextEditingController(text: draft.notes)..addListener(_edited);
    _titleFocus.addListener(_titleFocusChanged);
    _notesFocus.addListener(_notesFocusChanged);
    _autosave.addListener(_draftChanged);
    // Backgrounding can end the process without another frame; store the
    // shown text before that can happen.
    _lifecycle = AppLifecycleListener(
      onInactive: _flush,
      onHide: _flush,
      onPause: _flush,
    );
  }

  @override
  void didUpdateWidget(TaskContentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(widget.task.id == _taskId, 'key TaskContentEditor by task id');
    if (identical(widget.task, oldWidget.task)) return;
    // A newer stored version (for example from sync) replaces only fields
    // the user is not typing in and has not edited here.
    final draft = _autosave.reconcile(
      widget.task,
      title: !_titleFocus.hasFocus,
      notes: !_notesFocus.hasFocus,
    );
    if (draft != null) _show(draft);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _autosave.removeListener(_draftChanged);
    _titleFocus.removeListener(_titleFocusChanged);
    _notesFocus.removeListener(_notesFocusChanged);
    _title.removeListener(_edited);
    _notes.removeListener(_edited);
    // The autosave already holds the latest text; closing stores it even
    // though this editor is gone by the time the write completes.
    unawaited(_autosave.close(_taskId));
    _title.dispose();
    _notes.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _edited() => _autosave.edit(
    _taskId,
    title: _title.text,
    notes: _notes.text,
    composing: _isComposing(_title.value) || _isComposing(_notes.value),
  );

  void _titleFocusChanged() {
    if (!_titleFocus.hasFocus) _flush();
  }

  void _notesFocusChanged() {
    if (!_notesFocus.hasFocus) _flush();
  }

  void _flush() => unawaited(_autosave.flush(_taskId));

  /// Shows text the autosave adopted from elsewhere (a newer stored version
  /// or the explicit edit dialog) in fields the user is not typing in.
  void _draftChanged() {
    final draft = _autosave.draft(_taskId);
    if (draft != null) _show(draft);
  }

  void _show(TaskContentDraft draft) {
    if (!_titleFocus.hasFocus && _title.text != draft.title) {
      _title.text = draft.title;
    }
    if (!_notesFocus.hasFocus && _notes.text != draft.notes) {
      _notes.text = draft.notes;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    TaskContentFields(title: _titleField(context), notes: _notesField(context)),
  );

  Widget _titleField(BuildContext context) => ListenableBuilder(
    listenable: _autosave,
    builder: (context, _) {
      final rejected = _autosave.draft(_taskId)?.titleRejected ?? false;
      return Semantics(
        container: true,
        label: 'Task title',
        child: TextField(
          key: const Key('task-detail-title'),
          controller: _title,
          focusNode: _titleFocus,
          maxLength: 1024,
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: <TextInputFormatter>[
            // Task titles are one line; pasted line breaks become spaces.
            FilteringTextInputFormatter.deny(
              RegExp(r'[\r\n]+'),
              replacementString: ' ',
            ),
          ],
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700),
          decoration: InputDecoration(
            hintText: 'Task title',
            border: widget.touchLayout ? InputBorder.none : null,
            contentPadding: widget.touchLayout
                ? const EdgeInsets.symmetric(vertical: 12)
                : null,
            isDense: true,
            counterText: '',
            errorText: rejected
                ? 'Enter a title. The saved title stays until you do.'
                : null,
            errorMaxLines: 3,
          ),
        ),
      );
    },
  );

  Widget _notesField(BuildContext context) => ListenableBuilder(
    listenable: _autosave,
    builder: (context, _) {
      final draft = _autosave.draft(_taskId);
      final failure = draft?.status == TaskContentSaveStatus.failed
          ? draft?.failureMessage
          : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            container: true,
            label: 'Task notes',
            child: TextField(
              key: const Key('task-detail-notes'),
              controller: _notes,
              focusNode: _notesFocus,
              maxLength: 8192,
              minLines: widget.touchLayout ? 1 : 3,
              maxLines: widget.touchLayout ? null : 12,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Add notes',
                border: widget.touchLayout
                    ? InputBorder.none
                    : const OutlineInputBorder(),
                contentPadding: widget.touchLayout
                    ? const EdgeInsets.symmetric(vertical: 12)
                    : null,
                counterText: '',
                // Desktop keeps its guidance line. Phone details stay quiet
                // when saved, but still identify pending/failed local edits.
                helperText:
                    widget.touchLayout &&
                        (draft == null ||
                            draft.status == TaskContentSaveStatus.saved)
                    ? null
                    : _statusLabel(draft?.status),
                helperMaxLines: 2,
              ),
            ),
          ),
          if (failure != null)
            Semantics(
              liveRegion: true,
              container: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: <Widget>[
                    Text(
                      'Not saved: $failure Your text is kept here.',
                      key: const Key('task-content-save-failure'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('task-content-save-retry'),
                      onPressed: () => unawaited(_autosave.retry(_taskId)),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry save'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

bool _isComposing(TextEditingValue value) =>
    value.composing.isValid && !value.composing.isCollapsed;

String _statusLabel(TaskContentSaveStatus? status) => switch (status) {
  TaskContentSaveStatus.pending => 'Unsaved changes',
  TaskContentSaveStatus.saving => 'Saving…',
  TaskContentSaveStatus.failed => 'Changes not saved',
  TaskContentSaveStatus.saved || null => 'Changes save automatically',
};
