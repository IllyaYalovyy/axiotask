import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/model/tasks.dart';
import '../../../domain/policy/date_workflow.dart';
import '../quick_add_view_model.dart';

final class QuickAddBar extends StatefulWidget {
  const QuickAddBar({
    required this.viewModel,
    required this.lists,
    required this.focusNode,
    this.onPasteMultiple,
    super.key,
  });

  final QuickAddViewModel viewModel;
  final List<CachedTaskList> lists;
  final FocusNode focusNode;
  final VoidCallback? onPasteMultiple;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

final class _QuickAddBarState extends State<QuickAddBar> {
  late final TextEditingController _controller = TextEditingController();
  bool _optionsOpen = false;
  String? _focusRestoredFor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.viewModel,
    builder: (context, _) {
      final state = widget.viewModel.state;
      final completion = state.successMessage ?? state.failureMessage;
      final focusRestoreKey = completion == null
          ? null
          : '$completion:${state.input}';
      if (focusRestoreKey != null && _focusRestoredFor != focusRestoreKey) {
        _focusRestoredFor = focusRestoreKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.focusNode.requestFocus();
        });
      }
      if (_controller.text != state.input) {
        _controller.value = TextEditingValue(
          text: state.input,
          selection: TextSelection.collapsed(offset: state.input.length),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: Semantics(
                      label: 'Task title',
                      textField: true,
                      child: TextField(
                        key: const Key('quick-add-input'),
                        controller: _controller,
                        focusNode: widget.focusNode,
                        maxLength: 1024,
                        maxLines: 1,
                        textInputAction: TextInputAction.done,
                        decoration: const InputDecoration(
                          hintText: 'Add a task',
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          prefixIcon: Icon(Icons.add_task_outlined, size: 20),
                        ),
                        onChanged: widget.viewModel.setInput,
                        onSubmitted: state.isSubmitting
                            ? null
                            : (_) => unawaited(widget.viewModel.submit()),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (state.destinationRequired) ...<Widget>[
                  _DestinationMenu(
                    compact: constraints.maxWidth < 560,
                    state: state,
                    lists: widget.lists,
                    onSelected: widget.viewModel.selectTarget,
                  ),
                  const SizedBox(width: 4),
                ],
                IconButton(
                  key: const Key('quick-add-options'),
                  tooltip: 'Capture options',
                  visualDensity: VisualDensity.compact,
                  onPressed: state.isSubmitting
                      ? null
                      : () => setState(() => _optionsOpen = !_optionsOpen),
                  icon: Icon(_optionsOpen ? Icons.tune : Icons.tune_outlined),
                ),
                const SizedBox(width: 2),
                SizedBox(
                  height: 40,
                  child: FilledButton(
                    key: const Key('quick-add-submit'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(56, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed:
                        state.isSubmitting ||
                            state.input.trim().isEmpty ||
                            state.targetId == null
                        ? null
                        : () => unawaited(widget.viewModel.submit()),
                    child: state.isSubmitting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Add'),
                  ),
                ),
              ],
            ),
          ),
          if (_optionsOpen) ...<Widget>[
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (!state.destinationRequired)
                  _DestinationMenu(
                    compact: false,
                    state: state,
                    lists: widget.lists,
                    onSelected: widget.viewModel.selectTarget,
                  ),
                _DateMenu(
                  state: state,
                  onSelected: widget.viewModel.selectDueShortcut,
                ),
                if (widget.onPasteMultiple case final onPaste?)
                  TextButton.icon(
                    key: const Key('quick-add-paste-multiple'),
                    onPressed: state.isSubmitting ? null : onPaste,
                    icon: const Icon(Icons.content_paste_outlined, size: 18),
                    label: const Text('Paste multiple'),
                  ),
              ],
            ),
          ],
          if (state.input.trim().isNotEmpty &&
              (state.hasParsedDate ||
                  state.hasExplicitDue ||
                  state.previewDue != null)) ...<Widget>[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              label: 'Quick add preview',
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: <Widget>[
                  Text('Create “${state.previewTitle}”'),
                  if (state.previewDue case final due?)
                    InputChip(
                      avatar: const Icon(Icons.event_outlined, size: 18),
                      label: Text('Due $due'),
                      tooltip: state.hasParsedDate
                          ? 'Dismiss interpreted date and keep it in the title'
                          : 'Date selected by the visible smart view',
                      onDeleted: state.hasParsedDate
                          ? widget.viewModel.dismissDatePreview
                          : null,
                      deleteIcon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
          ],
          if (state.failureMessage case final message?) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (state.successMessage case final message?) ...<Widget>[
            const SizedBox(height: 6),
            Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          ],
        ],
      );
    },
  );
}

final class _DestinationMenu extends StatelessWidget {
  const _DestinationMenu({
    required this.compact,
    required this.state,
    required this.lists,
    required this.onSelected,
  });

  final bool compact;
  final QuickAddState state;
  final List<CachedTaskList> lists;
  final ValueChanged<TaskListId> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskListId>(
    key: const Key('quick-add-destination'),
    enabled: !state.isSubmitting && lists.isNotEmpty,
    tooltip: 'Destination: ${state.targetName ?? 'No available Google list'}',
    onSelected: onSelected,
    itemBuilder: (context) => <PopupMenuEntry<TaskListId>>[
      for (final list in lists)
        PopupMenuItem<TaskListId>(
          value: list.id,
          child: Text(list.title, overflow: TextOverflow.ellipsis),
        ),
    ],
    child: compact
        ? const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.list_alt_outlined),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.list_alt_outlined, size: 18),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    state.targetName ?? 'Choose list',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
  );
}

final class _DateMenu extends StatelessWidget {
  const _DateMenu({required this.state, required this.onSelected});

  final QuickAddState state;
  final ValueChanged<DateShortcut> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<DateShortcut>(
    key: const Key('quick-add-date'),
    enabled: !state.isSubmitting,
    tooltip: 'Due date',
    onSelected: onSelected,
    itemBuilder: (context) => const <PopupMenuEntry<DateShortcut>>[
      PopupMenuItem(value: DateShortcut.today, child: Text('Due today')),
      PopupMenuItem(value: DateShortcut.tomorrow, child: Text('Due tomorrow')),
      PopupMenuItem(value: DateShortcut.nextWeek, child: Text('Due next week')),
      PopupMenuItem(
        value: DateShortcut.nextMonth,
        child: Text('Due next month'),
      ),
      PopupMenuDivider(),
      PopupMenuItem(value: DateShortcut.clear, child: Text('No due date')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.event_outlined, size: 18),
          const SizedBox(width: 4),
          Text(state.previewDue == null ? 'Date' : 'Due ${state.previewDue}'),
        ],
      ),
    ),
  );
}
