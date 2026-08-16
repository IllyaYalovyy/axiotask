import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/model/tasks.dart';
import '../quick_add_view_model.dart';

final class QuickAddBar extends StatefulWidget {
  const QuickAddBar({
    required this.viewModel,
    required this.lists,
    required this.focusNode,
    super.key,
  });

  final QuickAddViewModel viewModel;
  final List<CachedTaskList> lists;
  final FocusNode focusNode;

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

final class _QuickAddBarState extends State<QuickAddBar> {
  late final TextEditingController _controller = TextEditingController();

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
      if (_controller.text != state.input) {
        _controller.value = TextEditingValue(
          text: state.input,
          selection: TextSelection.collapsed(offset: state.input.length),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('quick-add-input'),
                  controller: _controller,
                  focusNode: widget.focusNode,
                  maxLength: 1024,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Quick add task',
                    hintText: 'Task title, optionally ending in tomorrow…',
                    counterText: '',
                    prefixIcon: Icon(Icons.bolt_outlined),
                  ),
                  onChanged: widget.viewModel.setInput,
                  onSubmitted: state.isSubmitting
                      ? null
                      : (_) => unawaited(widget.viewModel.submit()),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 190,
                child: Semantics(
                  key: const Key('quick-add-target'),
                  label: 'Quick add Google list target',
                  child: DropdownButtonFormField<TaskListId>(
                    key: ValueKey<Object>(
                      Object.hash(
                        state.targetId,
                        Object.hashAll(widget.lists.map((list) => list.id)),
                      ),
                    ),
                    initialValue: state.targetId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Google list'),
                    items: <DropdownMenuItem<TaskListId>>[
                      for (final list in widget.lists)
                        DropdownMenuItem<TaskListId>(
                          value: list.id,
                          child: Text(
                            list.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: state.isSubmitting
                        ? null
                        : (value) {
                            if (value != null) {
                              widget.viewModel.selectTarget(value);
                            }
                          },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('quick-add-submit'),
                onPressed:
                    state.isSubmitting ||
                        state.input.trim().isEmpty ||
                        state.targetId == null
                    ? null
                    : () => unawaited(widget.viewModel.submit()),
                icon: state.isSubmitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
          if (state.input.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              label: 'Quick add preview',
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: <Widget>[
                  Text('Create “${state.previewTitle}”'),
                  Chip(
                    avatar: const Icon(Icons.list_alt_outlined, size: 18),
                    label: Text(state.targetName ?? 'No available Google list'),
                  ),
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
        ],
      );
    },
  );
}
