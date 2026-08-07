// A single top-level task row — the T2.3 basics of the fresh TaskRow contract:
// tap the body to open the detail panel, tap the checkbox to toggle completion
// (never to open/select — the checkbox-toggles-not-selects rule), double-tap
// the title to rename inline. The rich metadata row, quick-date strip, swipe
// actions and completion animation are later tasks (T7.2 / T8.1); this row is
// deliberately minimal but every affordance here does real work.
//
// Subtasks are never rows (invariant #1) — the caller only ever hands this
// widget a top-level task; there is no indent, connector, or expand toggle.

import 'package:flutter/material.dart';

/// One tappable task row. Stateful only to host the inline-rename editor.
class TaskRow extends StatefulWidget {
  const TaskRow({
    required this.title,
    required this.completed,
    required this.onOpen,
    required this.onToggle,
    required this.onRename,
    this.due,
    super.key,
  });

  /// The task's display title (blank titles render as "Untitled").
  final String title;

  /// Whether the task is completed (drives the checkbox + strikethrough).
  final bool completed;

  /// Friendly, pre-formatted due label (empty when the task has no date).
  final String? due;

  /// Open the detail panel for this task (a body tap).
  final VoidCallback onOpen;

  /// Toggle the task's completion (a checkbox tap).
  final VoidCallback onToggle;

  /// Commit an inline rename to [value]; an empty [value] is ignored here (the
  /// empty-⇒-delete path lands with the delete command in T2.4).
  final ValueChanged<String> onRename;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> {
  TextEditingController? _editor;
  FocusNode? _focus;

  bool get _editing => _editor != null;

  void _startEdit() {
    setState(() {
      _editor = TextEditingController(text: widget.title);
      _focus = FocusNode();
    });
    // Focus after the field mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus?.requestFocus());
  }

  void _commit() {
    final value = _editor?.text.trim() ?? '';
    // Only rename when the title actually changed and is non-empty; the caller
    // owns whether an empty title deletes (T2.4).
    if (value.isNotEmpty && value != widget.title) widget.onRename(value);
    _stopEdit();
  }

  void _stopEdit() {
    _editor?.dispose();
    _focus?.dispose();
    setState(() {
      _editor = null;
      _focus = null;
    });
  }

  @override
  void dispose() {
    _editor?.dispose();
    _focus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = widget.due;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 48dp hit target for the checkbox (#167) — tapping it toggles and
          // never bubbles to the body tap (Flutter's gesture arena gives the
          // checkbox its own bounds).
          SizedBox(
            width: 48,
            height: 48,
            child: Checkbox(
              value: widget.completed,
              onChanged: (_) => widget.onToggle(),
            ),
          ),
          Expanded(
            child: _editing
                ? TextField(
                    controller: _editor,
                    focusNode: _focus,
                    autofocus: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _commit(),
                    onTapOutside: (_) => _commit(),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onOpen,
                    onDoubleTap: _startEdit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.title.isEmpty ? 'Untitled' : widget.title,
                              style: TextStyle(
                                decoration: widget.completed
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: widget.completed
                                    ? theme.disabledColor
                                    : null,
                              ),
                            ),
                          ),
                          if (due != null && due.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                due,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
