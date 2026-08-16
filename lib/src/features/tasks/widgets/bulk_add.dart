import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/model/tasks.dart';
import '../../../domain/policy/bulk_capture.dart';
import '../bulk_add_view_model.dart';

final class BulkAddDialog extends StatefulWidget {
  const BulkAddDialog({
    required this.viewModel,
    required this.lists,
    this.onClose,
    super.key,
  });

  final BulkAddViewModel viewModel;
  final List<CachedTaskList> lists;
  final VoidCallback? onClose;

  @override
  State<BulkAddDialog> createState() => _BulkAddDialogState();
}

final class _BulkAddDialogState extends State<BulkAddDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 680),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AnimatedBuilder(
          animation: widget.viewModel,
          builder: (context, _) {
            final state = widget.viewModel.state;
            final displayEntries = state.successMessage == null
                ? state.preview.entries
                : state.acceptedEntries;
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
                    const Icon(Icons.content_paste_outlined),
                    const SizedBox(width: 10),
                    Text(
                      'Add multiple tasks',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close bulk add',
                      onPressed: state.isSubmitting ? null : widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('bulk-add-input'),
                  controller: _controller,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 7,
                  maxLength: maxBulkCaptureInputCharacters,
                  decoration: const InputDecoration(
                    labelText: 'Paste tasks',
                    hintText:
                        'One task per line, or blank-line-separated paragraphs',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: widget.viewModel.setInput,
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    SegmentedButton<BulkCaptureMode>(
                      segments: const <ButtonSegment<BulkCaptureMode>>[
                        ButtonSegment(
                          value: BulkCaptureMode.lines,
                          label: Text('Lines'),
                          icon: Icon(Icons.view_headline),
                        ),
                        ButtonSegment(
                          value: BulkCaptureMode.paragraphs,
                          label: Text('Paragraphs'),
                          icon: Icon(Icons.notes),
                        ),
                      ],
                      selected: <BulkCaptureMode>{state.mode},
                      onSelectionChanged: state.isSubmitting
                          ? null
                          : (selection) =>
                                widget.viewModel.setMode(selection.single),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Semantics(
                        label: 'Bulk add Google list target',
                        child: DropdownButtonFormField<TaskListId>(
                          key: ValueKey<Object>(
                            Object.hash(
                              state.targetId,
                              Object.hashAll(
                                widget.lists.map((list) => list.id),
                              ),
                            ),
                          ),
                          initialValue: state.targetId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Google list',
                          ),
                          items: <DropdownMenuItem<TaskListId>>[
                            for (final list in widget.lists)
                              DropdownMenuItem(
                                value: list.id,
                                child: Text(
                                  list.title,
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
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  state.successMessage != null
                      ? 'Local acknowledgement complete'
                      : state.preview.isValid
                      ? '${state.preview.entries.length} ${state.preview.entries.length == 1 ? 'task' : 'tasks'} ready'
                      : _validationMessage(state.preview.failure!),
                  key: const Key('bulk-add-validation'),
                  style: TextStyle(
                    color: state.preview.isValid || state.successMessage != null
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Maximum 100 tasks. Titles: 1024 characters. Notes: 8192 characters.',
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: displayEntries.isEmpty
                        ? const Center(
                            child: Text('Validated tasks appear here.'),
                          )
                        : ListView.separated(
                            key: const Key('bulk-add-preview'),
                            padding: const EdgeInsets.all(8),
                            itemCount: displayEntries.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = displayEntries[index];
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 14,
                                  child: Text('${index + 1}'),
                                ),
                                title: Text(entry.title),
                                subtitle: entry.notes == null
                                    ? null
                                    : Text(
                                        entry.notes!,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                              );
                            },
                          ),
                  ),
                ),
                if (state.failureMessage case final message?) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (state.successMessage case final message?) ...<Widget>[
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Text(
                      'Target: ${state.targetName ?? 'No available Google list'}',
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: state.isSubmitting ? null : widget.onClose,
                      child: Text(
                        state.successMessage == null ? 'Cancel' : 'Close',
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const Key('bulk-add-submit'),
                      onPressed:
                          state.isSubmitting ||
                              !state.preview.isValid ||
                              state.targetId == null
                          ? null
                          : () => unawaited(widget.viewModel.submit()),
                      icon: state.isSubmitting
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                      label: const Text('Add all'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

String _validationMessage(BulkCaptureFailure failure) => switch (failure.code) {
  'bulk_capture.empty' => 'Paste at least one task.',
  'bulk_capture.too_many_tasks' => 'More than 100 tasks cannot be accepted.',
  'bulk_capture.input_too_large' => 'The pasted text is larger than 1 MiB.',
  'bulk_capture.title_too_long' =>
    'Task ${failure.entryNumber} title is longer than 1024 characters.',
  'bulk_capture.notes_too_long' =>
    'Task ${failure.entryNumber} notes are longer than 8192 characters.',
  'bulk_capture.malformed_text' =>
    'Task ${failure.entryNumber} contains unsupported control characters.',
  _ => 'The pasted text is invalid.',
};
